#!/usr/bin/env bash
#
# gh-evidence.sh — Generate GitHub PR evidence for a performance review / promotion case.
#
# What it does:
#   1. DISCOVERS every repo where you authored (and, by default, reviewed) a PR in a date
#      window — optionally scoped to one or more orgs — so you never maintain a repo list.
#   2. Pulls RICH per-PR data for each repo (title, state, merged date, +/- size, labels).
#   3. Emits structured evidence as JSON (source of truth) + Markdown (human/agent friendly).
#
# The JSON is the machine-readable source — feed it into whatever tool you use to draft
# your review. The Markdown is the same data, grouped for reading.
#
# Requires: gh (authenticated, `gh auth login`), jq.
#
# Usage:
#   ./gh-evidence.sh --from 2025-06-01 --to 2026-06-30
#   ./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --org my-org
#   ./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --org org-a --org org-b
#   ./gh-evidence.sh --from 2025-01-01 --to 2025-12-31 --date-field merged
#   ./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --include-reviews --repo owner/extra-repo
#
# With no --org or --repo, it searches every repo your account can access. Use --org to
# scope it to your work org(s).
#
# Options:
#   --from DATE           Start of window (YYYY-MM-DD). Required.
#   --to DATE             End of window (YYYY-MM-DD). Required.
#   --org NAME            Restrict to this org/user. Repeatable. Default: no restriction.
#   --repo OWNER/NAME     Add a specific repo on top of discovery. Repeatable.
#   --date-field FIELD    created | updated | merged. Default: updated.
#   --login NAME          GitHub login to report on. Default: @me (the authenticated user).
#   --include-reviews     Include PRs you reviewed (default: authored only).
#   --no-lines-changed    Omit the +/− lines-changed metric from summary and table.
#   --aggregate           Include aggregate summary section (default: off).
#   --format LIST         Comma-separated output formats: json,md,pdf. Default: json,md.
#   --limit N             Max results per query. Default: 1000.
#   --out DIR             Output directory. Default: reports-FROM_to_TO.
#   -h, --help            Show this help.

set -euo pipefail

# ----------------------------- defaults -----------------------------
FROM=""
TO=""
ORGS=()
REPOS=()
DATE_FIELD="updated"     # created | updated | merged
LOGIN="@me"
INCLUDE_REVIEWS=0
SHOW_LINES=0
SHOW_AGGREGATE=0
FORMAT="json,md"
LIMIT=1000
OUTDIR=""

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

# ----------------------------- arg parse ----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)            FROM="$2"; shift 2;;
    --to)              TO="$2"; shift 2;;
    --org)             ORGS+=("$2"); shift 2;;
    --repo)            REPOS+=("$2"); shift 2;;
    --date-field)      DATE_FIELD="$2"; shift 2;;
    --login)            LOGIN="$2"; shift 2;;
    --include-reviews)  INCLUDE_REVIEWS=1; shift;;
    --no-lines-changed) SHOW_LINES=0; shift;;
    --lines-changed)    SHOW_LINES=1; shift;;
    --aggregate)        SHOW_AGGREGATE=1; shift;;
    --format)           FORMAT="$2"; shift 2;;
    --limit)            LIMIT="$2"; shift 2;;
    --out)             OUTDIR="$2"; shift 2;;
    -h|--help)         usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; echo "Run with --help for usage." >&2; exit 1;;
  esac
done

# ----------------------------- defaults after parse -----------------
if [[ -z "$FROM" || -z "$TO" ]]; then
  usage
  exit 1
fi

# Validate --format values
for fmt in ${FORMAT//,/ }; do
  case "$fmt" in
    json|md|pdf) ;;
    *) echo "Invalid --format value '$fmt' (allowed: json, md, pdf)" >&2; exit 1;;
  esac
done
WANT_JSON=0; WANT_MD=0; WANT_PDF=0
[[ ",$FORMAT," == *",json,"* ]] && WANT_JSON=1
[[ ",$FORMAT," == *",md,"*   ]] && WANT_MD=1
[[ ",$FORMAT," == *",pdf,"*  ]] && WANT_PDF=1

case "$DATE_FIELD" in
  created) DATE_KEY="createdAt"; DATE_SEARCH_FLAG="created";;
  updated) DATE_KEY="updatedAt"; DATE_SEARCH_FLAG="updated";;
  merged)  DATE_KEY="mergedAt";  DATE_SEARCH_FLAG="merged-at";;  # search uses --merged-at
  *) echo "Invalid --date-field '$DATE_FIELD' (use created|updated|merged)" >&2; exit 1;;
esac

# ----------------------------- preflight ----------------------------
command -v gh >/dev/null 2>&1 || { echo "Error: 'gh' (GitHub CLI) not found." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: not logged in. Run 'gh auth login'." >&2; exit 1; }

# Resolve @me to a real login — the GitHub Search API does not support @me.
if [[ "$LOGIN" == "@me" ]]; then
  LOGIN="$(gh api user --jq .login)" || { echo "Error: failed to resolve @me login." >&2; exit 1; }
fi
LOGIN_DISPLAY="$LOGIN"

if [[ -z "$OUTDIR" ]]; then
  OUTDIR="reports-${FROM}_to_${TO}"
fi
if [[ -d "$OUTDIR" ]]; then
  n=2
  while [[ -d "${OUTDIR}-${n}" ]]; do
    n=$((n+1))
  done
  OUTDIR="${OUTDIR}-${n}"
fi
mkdir -p "$OUTDIR"

RANGE="${FROM}..${TO}"
FROM_TS="${FROM}T00:00:00Z"   # inclusive lower bound for client-side jq filtering
TO_TS="${TO}T23:59:59Z"      # inclusive upper bound

# Build --owner flags only if orgs were given; otherwise search everything accessible.
OWNER_ARGS=()
for o in ${ORGS[@]+"${ORGS[@]}"}; do OWNER_ARGS+=(--owner "$o"); done

if [[ ${#ORGS[@]} -gt 0 ]]; then
  orgs_label="${ORGS[*]}"
else
  orgs_label="(all repos your account can access — narrow with --org)"
fi

echo ">> Window:     ${FROM} -> ${TO}  (by ${DATE_FIELD})"
echo ">> Scope:      ${orgs_label}"
echo ">> Reviews:    $([[ $INCLUDE_REVIEWS -eq 1 ]] && echo included || echo excluded)"
echo ">> Login:      ${LOGIN_DISPLAY}"
echo

# ----------------------------- discovery ----------------------------
# Find every repo (nameWithOwner) that has a PR matching the role + date window.
# NOTE: gh search prs treats a positional argument as free-text keywords, so qualifiers
# must be passed as flags (--author / --reviewed-by / --created|--updated|--merged-at).
discover_repos() {
  local role_flag="$1" login="$2"   # e.g. --author jrmarquard
  gh search prs \
    "$role_flag" "$login" \
    "--${DATE_SEARCH_FLAG}" "$RANGE" \
    ${OWNER_ARGS[@]+"${OWNER_ARGS[@]}"} \
    --limit "$LIMIT" \
    --json repository \
    --jq '.[].repository.nameWithOwner' || true
}

echo ">> Discovering repositories you authored in..."
authored_repos="$(discover_repos --author "$LOGIN")"
explicit_repos="$(printf '%s\n' ${REPOS[@]+"${REPOS[@]}"})"

all_repos="$(printf '%s\n%s\n' "$authored_repos" "$explicit_repos" \
             | sed '/^[[:space:]]*$/d' | sort -u)"

repo_count=0
if [[ -n "$all_repos" ]]; then
  repo_count="$(printf '%s\n' "$all_repos" | wc -l | tr -d ' ')"
fi
echo ">> Found ${repo_count} authored repositories. Fetching PR details..."
echo

# ----------------------------- fetch --------------------------------
# additions/deletions require per-PR diff computation in GraphQL — requesting them for
# large repos at --limit 1000 causes HTTP 502. Only include them when --lines-changed is set.
PR_FIELDS_BASE="number,title,url,headRefName,state,isDraft,createdAt,updatedAt,mergedAt,closedAt,labels,author,reviewDecision"
if [[ $SHOW_LINES -eq 1 ]]; then
  PR_FIELDS="${PR_FIELDS_BASE},additions,deletions"
else
  PR_FIELDS="$PR_FIELDS_BASE"
fi

# Authored: native per-repo list. No --search, so --state all reliably returns ALL states
# (open + merged + closed). Window-filter client-side on the chosen date field.
fetch_authored() {
  local repo="$1"
  gh pr list -R "$repo" --author "$LOGIN" --state all --limit "$LIMIT" \
    --json "$PR_FIELDS" \
    --jq "[ .[]
            | select(.${DATE_KEY} != null and .${DATE_KEY} >= \"$FROM_TS\" and .${DATE_KEY} <= \"$TO_TS\")
            | . + {repo: \"$repo\", role: \"authored\"} ]"
}

# Reviewed: one cross-org search. Search returns all states reliably, but with fewer fields
# than gh pr list, so size/branch/merge-date are not available for reviewed PRs (they're
# someone else's PRs anyway — title, repo, state and date are what matter as review evidence).
fetch_reviewed() {
  gh search prs --reviewed-by "$LOGIN" "--${DATE_SEARCH_FLAG}" "$RANGE" \
    ${OWNER_ARGS[@]+"${OWNER_ARGS[@]}"} --limit "$LIMIT" \
    --json number,title,url,repository,state,isDraft,createdAt,updatedAt,closedAt,labels,author \
    --jq '[ .[] | {
              number, title, url,
              headRefName: null,
              state: (.state // "" | ascii_upcase),
              isDraft, createdAt, updatedAt,
              mergedAt: null, closedAt,
              additions: 0, deletions: 0,
              labels, author, reviewDecision: null,
              repo: .repository.nameWithOwner,
              role: "reviewed"
            } ]'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
shopt -s nullglob
i=0

if [[ -n "$all_repos" ]]; then
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    err_file="$(mktemp)"
    if ! fetch_authored "$repo" > "$tmp/$i.json" 2>"$err_file"; then
      echo "[]" > "$tmp/$i.json"
      err_msg="$(cat "$err_file")"
      echo "   - ${repo}  (warning: could not read PRs: ${err_msg})" >&2
    else
      echo "   - ${repo}"
    fi
    rm -f "$err_file"
    i=$((i+1))
  done <<< "$all_repos"
fi

if [[ $INCLUDE_REVIEWS -eq 1 ]]; then
  echo ">> Fetching reviewed PRs..."
  if ! fetch_reviewed > "$tmp/reviewed.json" 2>/dev/null; then
    echo "[]" > "$tmp/reviewed.json"
  fi
fi

# Ensure jq -s has at least one file to read.
[[ -z "$(echo "$tmp"/*.json)" ]] && echo "[]" > "$tmp/empty.json"

# Merge, de-dupe, sort newest-first by updatedAt.
JSON_OUT="$OUTDIR/github-evidence.json"
jq -s 'add | unique_by([.repo, .number, .role]) | sort_by(.updatedAt) | reverse' \
  "$tmp"/*.json > "$JSON_OUT"

# ----------------------------- summary stats ------------------------
total=$(jq 'length' "$JSON_OUT")
authored=$(jq '[.[]|select(.role=="authored")]|length' "$JSON_OUT")
merged=$(jq '[.[]|select(.role=="authored" and .mergedAt!=null)]|length' "$JSON_OUT")
reviewed=$(jq '[.[]|select(.role=="reviewed")]|length' "$JSON_OUT")
repos_touched=$(jq '[.[].repo]|unique|length' "$JSON_OUT")
adds=$(jq '[.[]|select(.role=="authored")|.additions]|add // 0' "$JSON_OUT")
dels=$(jq '[.[]|select(.role=="authored")|.deletions]|add // 0' "$JSON_OUT")

# ----------------------------- markdown -----------------------------
MD_OUT="$OUTDIR/github-evidence.md"
{
  echo "# GitHub PR evidence — ${LOGIN_DISPLAY}"
  echo
  echo "> **From:** ${FROM}  "
  echo "> **To:** ${TO}  "
  echo "> **Generated:** $(date +%F)"
  echo

  if [[ $SHOW_AGGREGATE -eq 1 ]]; then
    echo "## Summary"
    echo
    echo "- Repositories touched: **${repos_touched}**"
    echo "- PRs authored: **${authored}** (merged: ${merged})"
    if [[ $INCLUDE_REVIEWS -eq 1 ]]; then
      echo "- PRs reviewed: **${reviewed}**"
    fi
    if [[ $SHOW_LINES -eq 1 ]]; then
      echo "- Lines changed in authored PRs: **+${adds} / −${dels}** (raw; includes generated files/lockfiles)"
    fi
    echo
  fi

  if [[ "$repos_touched" -gt 1 ]]; then
    echo "### Repos"
    echo
    jq -r '[.[].repo] | unique | .[] | "- [\(.)](#\(. | ascii_downcase | gsub("[^a-z0-9 -]"; "") | gsub(" "; "-")))"' "$JSON_OUT"
    echo
  fi

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    echo "## ${repo}"
    echo
    if [[ $SHOW_AGGREGATE -eq 1 ]]; then
      repo_total=$(jq --arg repo "$repo" '[.[] | select(.repo == $repo)] | length' "$JSON_OUT")
      repo_authored=$(jq --arg repo "$repo" '[.[] | select(.repo == $repo and .role == "authored")] | length' "$JSON_OUT")
      repo_merged=$(jq --arg repo "$repo" '[.[] | select(.repo == $repo and .role == "authored" and .mergedAt != null)] | length' "$JSON_OUT")
      echo "_${repo_total} PRs — ${repo_authored} authored (${repo_merged} merged)_"
      echo
    fi
    if [[ $SHOW_LINES -eq 1 ]]; then
      echo "| # | Role | Title | Branch | State | Date | +/− |"
      echo "| --: | :-- | :-- | :-- | :-- | :-- | :-- |"
    else
      echo "| # | Role | Title | Branch | State | Date |"
      echo "| --: | :-- | :-- | :-- | :-- | :-- |"
    fi
    jq -r --arg repo "$repo" --argjson showlines "$SHOW_LINES" '
      [ .[] | select(.repo == $repo) ]
      | sort_by(.updatedAt) | reverse
      | .[]
      | "| [\(.number)](\(.url))"
        + " | \(.role)"
        + " | \(.title | gsub("\\|"; "\\|") | gsub("\n"; " "))"
        + " | \(if .headRefName then "`\(.headRefName)`" else "—" end)"
        + " | \(.state | ascii_downcase)\(if .isDraft then " (draft)" else "" end)"
        + " | \(.updatedAt[0:10])"
        + (if $showlines == 1 then " | \(if .role == "authored" then "+\(.additions)/−\(.deletions)" else "—" end)" else "" end)
        + " |"
    ' "$JSON_OUT"
    echo
  done < <(jq -r '[.[].repo] | unique | .[]' "$JSON_OUT")
} > "$MD_OUT"

echo
[[ $WANT_JSON -eq 1 ]] && echo ">> Wrote ${JSON_OUT}"
if [[ $WANT_MD -eq 1 ]]; then
  echo ">> Wrote ${MD_OUT}"
else
  rm -f "$MD_OUT"
fi
echo ">> ${total} PRs across ${repos_touched} repos (${authored} authored, ${reviewed} reviewed)."
if [[ "$total" -eq 0 ]]; then
  echo ">> Nothing matched. Check the date window, --date-field, and that your token can see the org(s)." >&2
fi

# ----------------------------- optional PDF -------------------------
if [[ $WANT_PDF -eq 1 ]]; then
  PDF_SCRIPT="$(dirname "$0")/gh-evidence-pdf.sh"
  if [[ ! -x "$PDF_SCRIPT" ]]; then
    echo ">> Warning: gh-evidence-pdf.sh not found or not executable at ${PDF_SCRIPT}" >&2
  else
    LINES_FLAG=""
    [[ $SHOW_LINES -eq 1 ]] && LINES_FLAG="--lines-changed"
    "$PDF_SCRIPT" "$OUTDIR" $LINES_FLAG
  fi
fi
