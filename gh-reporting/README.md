# gh-reporting

Scripts for generating GitHub PR evidence for performance reviews.

## Scripts

### `gh-evidence.sh`

Discovers every repo where you authored (or reviewed) a PR in a date window and writes the results to a report directory as JSON and optionally Markdown and PDF.

**Requires:** `gh` (authenticated), `jq`

```bash
# Default output (json + md)
./gh-evidence.sh --from 2025-06-01 --to 2026-06-30

# Scoped to one or more orgs
./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --org my-org
./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --org org-a --org org-b

# All formats
./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --org my-org --format json,md,pdf

# Include PRs you reviewed
./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --include-reviews

# Add a specific repo on top of discovery
./gh-evidence.sh --from 2025-06-01 --to 2026-06-30 --repo owner/some-repo

# Filter by merged date instead of updated date
./gh-evidence.sh --from 2025-01-01 --to 2025-12-31 --date-field merged
```

**Options:**

| Flag                 | Description                                                              |
| :------------------- | :----------------------------------------------------------------------- |
| `--from DATE`        | Start of window (YYYY-MM-DD). Required.                                  |
| `--to DATE`          | End of window (YYYY-MM-DD). Required.                                    |
| `--org NAME`         | Restrict to this org/user. Repeatable.                                   |
| `--repo OWNER/NAME`  | Add a specific repo on top of discovery. Repeatable.                     |
| `--date-field FIELD` | `created` \| `updated` \| `merged`. Default: `updated`.                  |
| `--login NAME`       | GitHub login to report on. Default: `@me`.                               |
| `--include-reviews`  | Include PRs you reviewed (default: authored only).                       |
| `--lines-changed`    | Include +/− lines-changed metric in output.                              |
| `--no-lines-changed` | Explicitly disable lines-changed metric.                                 |
| `--aggregate`        | Include aggregate summary section per repo (default: off).               |
| `--format LIST`      | Comma-separated output formats: `json`, `md`, `pdf`. Default: `json,md`. |
| `--limit N`          | Max results per query. Default: 1000.                                    |
| `--out DIR`          | Output directory. Default: `reports-FROM_to_TO`.                         |

**Outputs** (written into the report directory):

- `github-evidence.json` — structured source data (always produced)
- `github-evidence.md` — Markdown report (when `md` in `--format`)
- `github-evidence.pdf` — PDF report (when `pdf` in `--format`)

Report directories are named `reports-FROM_to_TO` and automatically suffixed (`-2`, `-3`, …) if a directory with that name already exists.

---

### `gh-evidence-pdf.sh`

Renders a `github-evidence.json` file as a compact A4-landscape PDF using weasyprint. Can be called directly or is invoked automatically by `gh-evidence.sh` when `--format` includes `pdf`.

**Requires:** `jq`, `weasyprint` (`brew install weasyprint`)

```bash
# From a report directory
./gh-evidence-pdf.sh reports-2025-06-30_to_2026-06-30

# From a JSON file directly
./gh-evidence-pdf.sh reports-2025-06-30_to_2026-06-30/github-evidence.json

# Include +/− lines-changed column
./gh-evidence-pdf.sh reports-2025-06-30_to_2026-06-30 --lines-changed
```

**Output:** `github-evidence.pdf` written into the same directory as the JSON.

## Output structure

```
reports-2025-06-30_to_2026-06-30/
    github-evidence.json   # structured data (source of truth)
    github-evidence.md     # markdown report
    github-evidence.pdf    # PDF report
```

## Roadmap

- [ ] Extract Markdown generation out of `gh-evidence.sh` into a dedicated `gh-evidence-md.sh` script so the data-gathering step is cleanly separated from rendering
- [ ] Create a unified `gh-render.sh` (or similar) that takes a report directory and produces MD and PDF output, replacing the need to call `gh-evidence-pdf.sh` directly
- [ ] Update `gh-evidence.sh` `--format` handling to delegate all rendering to the unified script
