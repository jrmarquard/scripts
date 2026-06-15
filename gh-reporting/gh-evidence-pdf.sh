#!/usr/bin/env bash
#
# gh-evidence-pdf.sh — Render a github-evidence.json report as a PDF.
#
# Reads the structured JSON produced by gh-evidence.sh and generates a compact,
# monochrome A4-landscape PDF via weasyprint. PR numbers are hyperlinked.
#
# Usage:
#   ./gh-evidence-pdf.sh <report-dir>
#   ./gh-evidence-pdf.sh <path/to/github-evidence.json>
#   ./gh-evidence-pdf.sh <report-dir> --lines-changed
#
# Output: github-evidence.pdf written into the same directory as the JSON.
#
# Requires: jq, weasyprint (brew install weasyprint)

set -euo pipefail

SHOW_LINES=0
INPUT=""

# ----------------------------- arg parse ----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines-changed) SHOW_LINES=1; shift;;
    -h|--help)       sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)              echo "Unknown option: $1" >&2; exit 1;;
    *)               INPUT="$1"; shift;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "Usage: $0 <report-dir | github-evidence.json> [--lines-changed]" >&2
  exit 1
fi

# ----------------------------- resolve paths ------------------------
if [[ -d "$INPUT" ]]; then
  JSON_FILE="${INPUT}/github-evidence.json"
  PDF_OUT="${INPUT}/github-evidence.pdf"
elif [[ -f "$INPUT" ]]; then
  JSON_FILE="$INPUT"
  PDF_OUT="${INPUT%.*}.pdf"
else
  echo "Error: '$INPUT' is not a file or directory." >&2
  exit 1
fi

[[ -f "$JSON_FILE" ]] || { echo "Error: '$JSON_FILE' not found." >&2; exit 1; }

# ----------------------------- preflight ----------------------------
command -v jq          >/dev/null 2>&1 || { echo "Error: 'jq' not found." >&2; exit 1; }
command -v weasyprint  >/dev/null 2>&1 || { echo "Error: 'weasyprint' not found. Install: brew install weasyprint" >&2; exit 1; }

# ----------------------------- metadata ----------------------------
LOGIN=$(jq -r '
  [.[] | select(.role=="authored") | .author.login]
  | group_by(.) | sort_by(-length) | .[0][0] // "unknown"
' "$JSON_FILE")
TOTAL=$(jq 'length' "$JSON_FILE")
REPOS=$(jq -r '[.[].repo] | unique | .[]' "$JSON_FILE")
REPO_COUNT=0
[[ -n "$REPOS" ]] && REPO_COUNT=$(printf '%s\n' "$REPOS" | wc -l | tr -d ' ')
GENERATED=$(date +%F)
# Extract the window bounds from the data itself
FROM_DATE=$(jq -r '[.[].updatedAt] | sort | .[0] | .[0:10]' "$JSON_FILE")
TO_DATE=$(jq -r '[.[].updatedAt] | sort | last | .[0:10]' "$JSON_FILE")

# ----------------------------- HTML generation ----------------------
generate_html() {
  # ---- common CSS (style tag left open — column widths appended below) ----
  cat <<'EOCSS'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
@page {
  size: A4 landscape;
  margin: 0.3in;
}
* { box-sizing: border-box; }
body {
  font-family: "Courier New", Courier, monospace;
  font-size: 7.5pt;
  line-height: 1.2;
  color: #000;
}
h1 {
  font-size: 11pt;
  margin: 0 0 1px 0;
  padding-bottom: 2px;
  border-bottom: 1.5px solid #000;
}
.meta { font-size: 7.5pt; color: #555; margin: 1px 0 8px 0; }
h2 {
  font-size: 11pt;
  font-weight: bold;
  margin: 18px 0 4px 0;
  padding: 0;
  border: none;
  color: #000;
  page-break-after: avoid;
}
table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  margin-bottom: 6px;
}
th, td {
  border: 1px solid #777;
  padding: 2px 3px;
  text-align: left;
  vertical-align: top;
  word-wrap: break-word;
  overflow: hidden;
}
th {
  background-color: #444;
  color: #fff;
  font-weight: bold;
  font-size: 7pt;
}
tr:nth-child(even) td { background-color: #f0f0f0; }
a { color: #1a56cc; text-decoration: underline; }
td.dimmed { color: #999; }
.toc { margin: 4px 0 10px 0; }
.toc ul { margin: 2px 0; padding-left: 16px; }
.toc li { margin: 1px 0; }
.toc a { font-size: 7.5pt; }
EOCSS

  # ---- column widths (appended into the open <style> block) ----
  if [[ $SHOW_LINES -eq 1 ]]; then
    cat <<'EOCOLS'
th:nth-child(1), td:nth-child(1) { width:  3%; } /* #      */
th:nth-child(2), td:nth-child(2) { width:  6%; } /* Role   */
th:nth-child(3), td:nth-child(3) { width: 37%; } /* Title  */
th:nth-child(4), td:nth-child(4) { width: 26%; } /* Branch */
th:nth-child(5), td:nth-child(5) { width:  8%; } /* State  */
th:nth-child(6), td:nth-child(6) { width:  9%; } /* Date   */
th:nth-child(7), td:nth-child(7) { width:  9%; } /* +/-    */
EOCOLS
  else
    cat <<'EOCOLS'
th:nth-child(1), td:nth-child(1) { width:  3%; } /* #      */
th:nth-child(2), td:nth-child(2) { width:  7%; } /* Role   */
th:nth-child(3), td:nth-child(3) { width: 43%; } /* Title  */
th:nth-child(4), td:nth-child(4) { width: 28%; } /* Branch */
th:nth-child(5), td:nth-child(5) { width:  9%; } /* State  */
th:nth-child(6), td:nth-child(6) { width:  9%; } /* Date   */
EOCOLS
  fi

  echo '</style></head><body>'
  echo "<h1>PR Request Summary &mdash; ${LOGIN}</h1>"
  echo "<p class=\"meta\">From ${FROM_DATE} to ${TO_DATE}, generated on ${GENERATED}</p>"

  # Table of contents (only when >1 repo)
  if [[ "$REPO_COUNT" -gt 1 ]]; then
    echo '<div class="toc"><strong>Repos</strong><ul>'
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      anchor=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/-*$//')
      pr_count=$(jq --arg repo "$repo" '[.[] | select(.repo == $repo)] | length' "$JSON_FILE")
      echo "  <li><a href=\"#${anchor}\">${repo}</a> (${pr_count})</li>"
    done <<< "$REPOS"
    echo '</ul></div>'
  fi

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    anchor=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/-*$//')
    echo "<h2 id=\"${anchor}\">${repo}</h2>"
    echo '<table><thead><tr>'
    echo '  <th>#</th><th>Role</th><th>Title</th><th>Branch</th><th>State</th><th>Date</th>'
    [[ $SHOW_LINES -eq 1 ]] && echo '  <th>+/&#8722;</th>'
    echo '</tr></thead><tbody>'

    jq -r --arg repo "$repo" --argjson showlines "$SHOW_LINES" '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      def stateclass: ascii_downcase | if . == "open" or . == "merged" then "" else "dimmed" end;
      [ .[] | select(.repo == $repo) ]
      | sort_by(.updatedAt)
      | .[]
      | "<tr>"
        + "<td><a href=\"\(.url)\">\(.number)</a></td>"
        + "<td>\(.role | esc)</td>"
        + "<td>\(.title | esc)</td>"
        + "<td>\((.headRefName // "—") | esc)</td>"
        + "<td class=\"\(.state | stateclass)\">\(.state | ascii_downcase)\(if .isDraft then " (draft)" else "" end)</td>"
        + "<td>\(.updatedAt[0:10])</td>"
        + (if $showlines == 1 then
            "<td>\(if .role == "authored" then "+\(.additions)/\u2212\(.deletions)" else "—" end)</td>"
          else "" end)
        + "</tr>"
    ' "$JSON_FILE"

    echo '</tbody></table>'
  done <<< "$REPOS"

  echo '</body></html>'
}

# ----------------------------- render -------------------------------
echo ">> Generating ${PDF_OUT}..."
generate_html | weasyprint - "$PDF_OUT"
echo ">> Done."
