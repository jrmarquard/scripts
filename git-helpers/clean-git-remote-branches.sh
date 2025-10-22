#!/usr/bin/env bash
# Remote branch cleaner with owned-only default, protected list, auto-skip list, and interactive control.
# Bash 5+ required.

set -euo pipefail

##### CONFIG (env-overridable)
MAIN_BRANCH="${MAIN_BRANCH:-main}"                # e.g. main, master
PROTECT_REGEX="${PROTECT_REGEX:-^(main|master|dev|develop|release|staging)$}"
BRANCH_FILTER_REGEX="${BRANCH_FILTER_REGEX:-}"    # e.g. '^copilot/'
DRY_RUN="${DRY_RUN:-false}"

# Ownership detection (default: only branches solely authored by you are considered)
OWNED_ONLY="${OWNED_ONLY:-true}"                  # true|false
OWNERSHIP_SCOPE="${OWNERSHIP_SCOPE:-unique}"      # unique|all
OWNER_EMAIL="${OWNER_EMAIL:-$(git config --get user.email || true)}"
OWNER_NAME="${OWNER_NAME:-$(git config --get user.name || true)}"
# Applied to "Author Name <email>"
OWNER_MATCH="${OWNER_MATCH:-${OWNER_NAME}.*<${OWNER_EMAIL//\//\\/}>}"

# Previews
SHOW_COMMITS="${SHOW_COMMITS:-3}"                 # how many unique commits to preview
SHOW_DIFF_LINES="${SHOW_DIFF_LINES:-20}"          # how many diff lines to show
SHOW_DIFF_MODE="${SHOW_DIFF_MODE:-commit}"        # commit|branch (see notes below)

##### COLORS
if [ -t 1 ]; then
  BOLD="$(tput bold || true)"; DIM="$(tput dim || true)"; RESET="$(tput sgr0 || true)"
  GREEN="$(tput setaf 2 || true)"; YELLOW="$(tput setaf 3 || true)"; RED="$(tput setaf 1 || true)"; BLUE="$(tput setaf 4 || true)"
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; BLUE=""
fi
say() { printf "%b\n" "$*"; }

##### PREP
say "${DIM}Fetching refs and pruning stale remote-tracking branches...${RESET}"
git fetch --all --prune

UPSTREAM="origin/${MAIN_BRANCH}"
if ! git rev-parse -q --verify "$UPSTREAM" >/dev/null 2>&1; then
  say "${RED}Upstream $UPSTREAM not found.${RESET} Set MAIN_BRANCH or fetch the remote."
  exit 1
fi

##### HELPERS

# Robust list of short remote names (no origin/ prefix, drop HEAD/empties)
mapfile -t REMOTE_BRANCHES < <(
  git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin | awk 'NF && $0!="HEAD"'
)

# Optional user filter (e.g. '^copilot/')
if [[ -n "$BRANCH_FILTER_REGEX" ]]; then
  tmp=()
  for b in "${REMOTE_BRANCHES[@]}"; do
    [[ "$b" =~ $BRANCH_FILTER_REGEX ]] && tmp+=("$b")
  done
  REMOTE_BRANCHES=("${tmp[@]}")
fi

is_protected() {
  local short="$1"
  [[ "$short" =~ $PROTECT_REGEX ]]
}

# Authors for ownership checks; returns two arrays by echoing with separators
# outputs:
#  line 1: matching authors (unique)
#  line 2: non-matching authors (unique)
collect_authors() {
  local rshort="$1" scope="${2:-$OWNERSHIP_SCOPE}"
  local revlist_range
  case "$scope" in
    unique) revlist_range="^${UPSTREAM} origin/${rshort}" ;; # commits on branch not in upstream
    all)    revlist_range="origin/${rshort}" ;;
    *)      revlist_range="^${UPSTREAM} origin/${rshort}" ;;
  esac

  mapfile -t authors < <(
    git rev-list --no-merges $revlist_range 2>/dev/null \
    | xargs -r -n1 -I {} git show -s --format='%an <%ae>' {} \
    | sed '/^$/d' | sort -u
  )

  if ((${#authors[@]}==0)); then
    echo ""
    echo ""
    return 0
  fi

  local matches=() nonmatches=()
  for a in "${authors[@]}"; do
    if [[ "$a" =~ $OWNER_MATCH ]]; then matches+=("$a"); else nonmatches+=("$a"); fi
  done
  printf "%s\n" "$(printf "%s" "${matches[*]}")"
  printf "%s\n" "$(printf "%s" "${nonmatches[*]}")"
}

# Human-readable list with cap + “+N more”
fmt_authors() {
  local list="$1"
  local cap="${2:-5}"
  [[ -z "$list" ]] && { printf "none"; return 0; }
  # split on spaces between items safely by mapping to lines first
  mapfile -t arr < <(printf "%s\n" "$list" | tr '|' '\n' | sed '/^$/d')
  # If not piped in with | separators, split by '  ' fallback
  if ((${#arr[@]}==0)); then
    IFS=$'\n' read -r -d '' -a arr < <(printf "%s\n" "$list" && printf '\0')
  fi
  # if still 1 element with spaces, treat as a single item
  local n="${#arr[@]}"
  if (( n <= cap )); then
    printf "%s" "$(printf "%s, " "${arr[@]}" | sed 's/, $//')"
  else
    local head=("${arr[@]:0:cap}")
    printf "%s +%d more" "$(printf "%s, " "${head[@]}" | sed 's/, $//')" "$((n-cap))"
  fi
}

explain_unique_commits() {
  local rshort="$1"
  local count
  count="$(git cherry "$UPSTREAM" "origin/$rshort" | awk '/^\+/{c++} END{print c+0}')"

  if (( count > 0 )); then
    printf "has %d unique commit(s) vs %s" "$count" "$UPSTREAM"

    mapfile -t uniq_shas < <(git cherry "$UPSTREAM" "origin/$rshort" | awk '/^\+/{print $2}')
    local shown=0
    for sha in "${uniq_shas[@]}"; do
      ((shown++)); ((shown > SHOW_COMMITS)) && break
      local subject; subject="$(git show -s --format='%s' "$sha")"
      printf "\n  %s%s%s %s\n" "$DIM" "$sha" "$RESET" "$subject"

      git show --stat --oneline -n 1 "$sha" \
        | sed -n '2,6p' \
        | sed "s/^/      ${DIM}/; s/$/${RESET}/"

      echo "${DIM}      ─── sample diff ───${RESET}"
      if [[ "$SHOW_DIFF_MODE" == "branch" ]]; then
        git diff --no-color --no-prefix -U2 "${UPSTREAM}...origin/$rshort" \
          | awk '
              /^diff --git a\// { file=$3; sub(/^a\//,"",file); print "      FILE: " file; next }
              /^@@ / { print "      @@ " $0 " @@" ; next }
              /^[ +-]/ { print "      " $0 }
            ' \
          | head -n "$SHOW_DIFF_LINES" \
          | sed "s/^/${DIM}/; s/$/${RESET}/"
      else
        git show --no-color --no-prefix -U2 "$sha" \
          | awk '
              /^diff --git a\// { file=$3; sub(/^a\//,"",file); print "      FILE: " file; next }
              /^@@ / { print "      @@ " $0 " @@" ; next }
              /^[+-]/ { print "      " $0 }
            ' \
          | head -n "$SHOW_DIFF_LINES" \
          | sed "s/^/${DIM}/; s/$/${RESET}/"
      fi
      echo "${DIM}      ────────────────────${RESET}"
    done
  else
    printf "changes not provably integrated (patch-id check inconclusive)"
  fi
}

is_safely_deletable() {
  local rshort="$1"
  if git merge-base --is-ancestor "origin/$rshort" "$UPSTREAM" 2>/dev/null; then
    return 0
  fi
  if ! git cherry "$UPSTREAM" "origin/$rshort" | grep -q '^+'; then
    return 0
  fi
  return 1
}

##### BUCKETS
protected=(); protected_reason=()
deletable=(); deletable_reason=()
autoskip=(); autoskip_reason=()    # auto-skipped (e.g., not solely authored)
remaining=(); remaining_reason=()  # promptable (unique commits, owned)

# Evaluate
for rshort in "${REMOTE_BRANCHES[@]}"; do
  [[ -z "$rshort" || "$rshort" == "HEAD" || "$rshort" == "origin" ]] && continue

  if is_protected "$rshort"; then
    protected+=("$rshort")
    protected_reason+=("protected by PROTECT_REGEX (${PROTECT_REGEX})")
    continue
  fi

  # OWNED_ONLY logic
  if [[ "$OWNED_ONLY" == "true" ]]; then
    # collect authors (matches / nonmatches)
    read -r matches <<<"$(collect_authors "$rshort" "$OWNERSHIP_SCOPE" | sed -n '1p')"
    read -r nonmatches <<<"$(collect_authors "$rshort" "$OWNERSHIP_SCOPE" | sed -n '2p')"

    if [[ -n "$nonmatches" ]]; then
      # Auto-skip and record other authors
      autoskip+=("$rshort")
      # prettify other authors list
      IFS=$'\n' read -r -d '' -a other_auths < <(printf "%s\n" "$nonmatches" | tr ' ' '\n' | sed '/^$/d' && printf '\0')
      # Better summary: keep the raw list but show first few nicely
      # Combine lines to comma-separated string:
      other_csv="$(printf "%s, " $nonmatches 2>/dev/null | sed 's/, $//')"
      autoskip_reason+=("skipped (not solely authored by you; other author(s): ${other_csv})")
      continue
    fi
  fi

  if is_safely_deletable "$rshort"; then
    deletable+=("$rshort")
    deletable_reason+=("already integrated into ${UPSTREAM} (merged or patch-equivalent)")
  else
    remaining+=("$rshort")
    remaining_reason+=("$(explain_unique_commits "$rshort")")
  fi
done

##### OUTPUT (order per your request)

# 1) Protected
say ""
say "${BOLD}${BLUE}Protected remote branches${RESET} (never deleted):"
if ((${#protected[@]}==0)); then
  say "  (none)"
else
  for i in "${!protected[@]}"; do
    say "  ${protected[$i]} ${DIM}- ${protected_reason[$i]}${RESET}"
  done
fi

# 2) Safely deletable (bulk gate via 'delete-all')
say ""
say "${BOLD}${GREEN}Remote branches that appear safely deletable${RESET} (already in ${UPSTREAM}):"
if ((${#deletable[@]}==0)); then
  say "  (none)"
else
  for i in "${!deletable[@]}"; do
    say "  ${deletable[$i]} ${DIM}- ${deletable_reason[$i]}${RESET}"
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    say "\n${BLUE}[DRY RUN]${RESET} Would delete these with:"
    for b in "${deletable[@]}"; do
      say "  git push origin --delete ${b}"
    done
  else
    read -r -p $'\nType \x27delete-all\x27 to delete ALL safe branches above, or press Enter to skip: ' confirm_all
    if [[ "$confirm_all" == "delete-all" ]]; then
      for b in "${deletable[@]}"; do
        say "Deleting remote branch: ${b}"
        git push origin --delete "$b"
      done
      say "${GREEN}Bulk delete complete.${RESET}"
    else
      say "Skipped bulk deletion."
    fi
  fi
fi

# 3) Auto-skipped (NOT considered in interactive step)
say ""
say "${BOLD}${YELLOW}Auto-skipped remote branches${RESET} (not solely authored by you):"
if ((${#autoskip[@]}==0)); then
  say "  (none)"
else
  for i in "${!autoskip[@]}"; do
    say "  ${autoskip[$i]} ${DIM}- ${autoskip_reason[$i]}${RESET}"
  done
fi

# 4) Remaining (promptable, owned, but not safely deletable)
say ""
say "${BOLD}${YELLOW}Remaining remote branches${RESET} (owned; not auto-deleted) ${DIM}- with reasons:${RESET}"
if ((${#remaining[@]}==0)); then
  say "  (none)"
  exit 0
fi

for i in "${!remaining[@]}"; do
  rshort="${remaining[$i]}"; reason="${remaining_reason[$i]}"
  say "  ${rshort} ${DIM}- ${reason}${RESET}"

  if [[ "$DRY_RUN" == "true" ]]; then
    say "    ${BLUE}[DRY RUN]${RESET} Action for '${rshort}': (del)ete / (s)kip [s]: s"
    continue
  fi

  while true; do
    read -r -p "    Action for '${rshort}': (del)ete / (s)kip [s]: " choice
    choice="${choice:-s}"
    case "$choice" in
      del|DEL|Del)
        say "    Deleting remote branch: ${rshort}"
        if git push origin --delete "$rshort"; then
          say "    ${RED}Deleted.${RESET}"
        else
          say "    ${RED}Deletion failed.${RESET}"
        fi
        break
        ;;
      s|S|"")
        say "    Skipped."
        break
        ;;
      *)
        say "    Please type 'del' or 's'."
        ;;
    esac
  done
done
