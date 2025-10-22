#!/usr/bin/env bash
# Clean up local branches with explanations and interactive overrides.
# Bash 5+ required (uses mapfile, associative arrays friendly behavior, etc.)
#
# Behavior:
# - Automatically deletes branches fully integrated into MAIN (classic merge OR patch-equivalent via squash/rebase).
# - For branches NOT safely deletable, prints WHY, then prompts:
#       (d)elete anyway  /  (s)kip [default].
#
# Config via env:
#   MAIN_BRANCH=main
#   PROTECT_REGEX='^(main|master|dev|develop|release|staging)$'
#   SHOW_COMMITS=3                # show up to N example commits for "unique commits" reason
#   FORCE_DELETE=false            # for the safe set only: true => -D, false => -d
#   DRY_RUN=false                 # preview actions (no changes)
#   INTERACTIVE_ON_UNDELETABLE=true
#   BRANCH_FILTER_REGEX=''        # optional: only consider branches matching this regex (e.g. '^copilot/')

set -euo pipefail

MAIN_BRANCH="${MAIN_BRANCH:-main}"
PROTECT_REGEX="${PROTECT_REGEX:-^(main|master|dev|develop|release|staging)$}"
SHOW_COMMITS="${SHOW_COMMITS:-3}"
FORCE_DELETE="${FORCE_DELETE:-false}"
DRY_RUN="${DRY_RUN:-false}"
INTERACTIVE_ON_UNDELETABLE="${INTERACTIVE_ON_UNDELETABLE:-true}"
BRANCH_FILTER_REGEX="${BRANCH_FILTER_REGEX:-}"

# Colors
if [ -t 1 ]; then
  BOLD="$(tput bold || true)"; DIM="$(tput dim || true)"; RESET="$(tput sgr0 || true)"
  GREEN="$(tput setaf 2 || true)"; YELLOW="$(tput setaf 3 || true)"; RED="$(tput setaf 1 || true)"; BLUE="$(tput setaf 4 || true)"
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; BLUE=""
fi

say() { printf "%b\n" "$*"; }

say "${DIM}Fetching refs and pruning stale remotes...${RESET}"
git fetch --all --prune

# Try to fast-forward local main to origin/main if present
if git rev-parse -q --verify "origin/${MAIN_BRANCH}" >/dev/null 2>&1 \
&& git rev-parse -q --verify "${MAIN_BRANCH}" >/dev/null 2>&1; then
  cur_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$cur_branch" = "$MAIN_BRANCH" ]; then
    git pull --ff-only origin "${MAIN_BRANCH}" || true
  else
    git checkout -q "${MAIN_BRANCH}" && git pull --ff-only origin "${MAIN_BRANCH}" || true
    git checkout -q "${cur_branch}"
  fi
fi

# Shallow notice
if git rev-parse --is-shallow-repository >/dev/null 2>&1 && [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  say "${YELLOW}Note:${RESET} repo is shallow; for best results run: ${BOLD}git fetch --unshallow${RESET}"
fi

UPSTREAM="${MAIN_BRANCH}"
if git rev-parse -q --verify "origin/${MAIN_BRANCH}" >/dev/null 2>&1; then
  UPSTREAM="origin/${MAIN_BRANCH}"
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"

# Collect local branches
mapfile -t LOCAL_BRANCHES < <(git for-each-ref --format='%(refname:short)' refs/heads)

# Optional filter (e.g. only copilot/*)
if [[ -n "$BRANCH_FILTER_REGEX" ]]; then
  tmp=()
  for br in "${LOCAL_BRANCHES[@]}"; do
    [[ "$br" =~ $BRANCH_FILTER_REGEX ]] && tmp+=("$br")
  done
  LOCAL_BRANCHES=("${tmp[@]}")
fi

deletable=()
deleted_reason=()
kept=()
kept_reason=()
kept_promptable=()   # "yes" if we offer d/s prompt, else "no"

explain_unique_commits () {
  local br="$1"
  local count
  count="$(git cherry "${UPSTREAM}" "${br}" | awk '/^\+/{c++} END{print c+0}')"

  if (( count > 0 )); then
    printf "has %d unique commit(s) vs %s" "$count" "$UPSTREAM"

    # Collect unique commit SHAs
    mapfile -t uniq_shas < <(git cherry "${UPSTREAM}" "${br}" | awk '/^\+/{print $2}')

    local shown=0
    for sha in "${uniq_shas[@]}"; do
      ((shown++))
      ((shown > SHOW_COMMITS)) && break

      local subject
      subject="$(git show -s --format='%s' "$sha")"
      printf "\n  %s%s%s %s\n" "$DIM" "$sha" "$RESET" "$subject"

      # Show a brief file change summary
      git show --stat --oneline -n 1 "$sha" | sed -n '2,5p' | sed "s/^/      ${DIM}/; s/$/${RESET}/"

      echo "${DIM}      ─── sample diff ───${RESET}"

      # Process the diff to show a few lines of context per file
      git show --no-color --no-prefix -U2 "$sha" \
        | awk '
          /^diff --git a\// { file=$3; sub(/^a\//,"",file); next }
          /^@@ / { print "      \033[2m@@ " $0 " @@\033[0m"; next }
          /^[+-]/ {
            if (/^\+/) color="\033[32m"; else if (/^-/) color="\033[31m"; else color=""
            printf "      %s%s%s\n", color, $0, "\033[0m"
          }' \
        | sed "s/^/${DIM}/; s/$/${RESET}/" \
        | head -n 20

      echo "${DIM}      ────────────────────${RESET}"
    done
  else
    printf "changes not provably integrated (patch-id check inconclusive)"
  fi
}

# Evaluate each branch
for br in "${LOCAL_BRANCHES[@]}"; do
  # Protect
  if [[ "$br" =~ $PROTECT_REGEX ]]; then
    kept+=("$br"); kept_reason+=("protected by PROTECT_REGEX (${PROTECT_REGEX})"); kept_promptable+=("no"); continue
  fi
  # Current branch
  if [[ "$br" = "$current_branch" ]]; then
    kept+=("$br"); kept_reason+=("currently checked out"); kept_promptable+=("no"); continue
  fi
  # Fully merged (ancestor)
  if git merge-base --is-ancestor "$br" "$UPSTREAM" 2>/dev/null; then
    deletable+=("$br"); deleted_reason+=("fully merged (tip is ancestor of ${UPSTREAM})"); continue
  fi
  # Squash/rebase equivalent (no '+' unique commits)
  if ! git cherry "$UPSTREAM" "$br" | grep -q '^+'; then
    deletable+=("$br"); deleted_reason+=("integrated via squash/rebase (no unique commits vs ${UPSTREAM})"); continue
  fi
  # Not safely deletable — explain
  kept+=("$br")
  kept_reason+=("$(explain_unique_commits "$br")")
  kept_promptable+=("yes")
done

say ""
say "${BOLD}${GREEN}Deletable branches${RESET} (safe to remove):"
if ((${#deletable[@]}==0)); then
  say "  (none)"
else
  for i in "${!deletable[@]}"; do
    say "  ${deletable[$i]} ${DIM}- ${deleted_reason[$i]}${RESET}"
  done
fi

# Delete safe set
if ((${#deletable[@]})); then
  if [[ "$DRY_RUN" == "true" ]]; then
    say "\n${BLUE}[DRY RUN]${RESET} Would delete safely:"
    printf '  %s\n' "${deletable[@]}"
  else
    read -r -p $'Proceed to delete the safe set above? [y/N]: ' confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      for br in "${deletable[@]}"; do
        if [[ "$FORCE_DELETE" == "true" ]]; then git branch -D "$br" || true
        else                                   git branch -d "$br" || true
        fi
      done
      say "${GREEN}Safe deletions complete.${RESET}"
    else
      say "Skipped safe deletions."
    fi
  fi
fi

say ""
say "${BOLD}${YELLOW}Kept branches${RESET} (not deleted automatically) ${DIM}- with reasons:${RESET}"
if ((${#kept[@]}==0)); then
  say "  (none)"
  exit 0
fi

# Interactive prompts for the “unsafe” set
for i in "${!kept[@]}"; do
  br="${kept[$i]}"; reason="${kept_reason[$i]}"; promptable="${kept_promptable[$i]}"
  say "  ${br} ${DIM}- ${reason}${RESET}"
  if [[ "$INTERACTIVE_ON_UNDELETABLE" == "true" && "$promptable" == "yes" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      say "    ${BLUE}[DRY RUN]${RESET} Action for '${br}': (d)elete anyway / (s)kip [s]: s"
      continue
    fi
    while true; do
      read -r -p "    Action for '${br}': (d)elete anyway / (s)kip [s]: " choice
      choice="${choice:-s}"
      case "$choice" in
        d|D)
          if git branch -D "$br"; then
            say "    ${RED}Deleted anyway (-D).${RESET}"
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
          say "    Please type 'd' or 's'."
          ;;
      esac
    done
  fi
done
