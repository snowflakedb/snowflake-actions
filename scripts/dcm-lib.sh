#!/usr/bin/env bash
#
# DCM-specific helpers for the Snowflake DCM composite actions.
# Builds on the generic gh-actions-lib.sh (summary + result helpers).
#
# Source this file from a step's `run:` block:
#
#   . "$GITHUB_ACTION_PATH/../../scripts/dcm-lib.sh"
#
# It in turn sources gh-actions-lib.sh, so gha_* functions are also available.

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/gh-actions-lib.sh"

# Lines left out of the plan/deploy summaries. The CLI's live progress renderer
# repaints a step while it runs, so in a non-interactive log each step appears
# twice: once as "Running..." and again as the completed or failed line. Only the
# transient repaint is dropped; completed and failed step lines and their detail
# lines are kept. The second alternation covers the spinner-only rows the newer
# progress layout prints for a running step. Anchoring on the end of the line keeps
# object text that mentions "Running..." intact. The raw Actions log is untouched.
: "${GHA_OUTPUT_DROP_REGEX:=(Running\.\.\.|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)[[:space:]]*$}"
export GHA_OUTPUT_DROP_REGEX

# Read a scalar value from manifest.yml.
# Usage: dcm_manifest_value <yq-path> [manifest-path]
dcm_manifest_value() {
  local path="$1"
  local manifest="${2:-manifest.yml}"
  yq eval "$path" "$manifest"
}

# Read the manifest target and export the Snowflake connection env vars.
# Also writes project-name / manifest-account / manifest-role to $GITHUB_OUTPUT
# so steps that need them (e.g. connection-test) can consume them.
#
# Required env: TARGET, SNOWFLAKE_USER
# Optional env: MANIFEST_PATH (default: manifest.yml)
dcm_read_manifest() {
  local manifest="${MANIFEST_PATH:-manifest.yml}"

  local project_name account owner_role
  project_name=$(dcm_manifest_value ".targets.$TARGET.project_name" "$manifest")
  account=$(dcm_manifest_value ".targets.$TARGET.account_identifier" "$manifest")
  owner_role=$(dcm_manifest_value ".targets.$TARGET.project_owner" "$manifest")

  # Use GitHub's multiline-value syntax so a value containing a newline
  # can't inject extra env vars.
  printf 'SNOWFLAKE_ACCOUNT<<GH_EOF\n%s\nGH_EOF\n' "$account"   >> "$GITHUB_ENV"
  printf 'SNOWFLAKE_ROLE<<GH_EOF\n%s\nGH_EOF\n'    "$owner_role" >> "$GITHUB_ENV"
  printf 'SNOWFLAKE_USER<<GH_EOF\n%s\nGH_EOF\n'    "$SNOWFLAKE_USER" >> "$GITHUB_ENV"

  # Sanitized project name for use in artifact names. GitHub artifact names
  # disallow / \ : * ? " < > |, so replace every character that is not
  # alphanumeric, dot, underscore, or hyphen with an underscore. This keeps
  # uploaded artifacts unique when the same target is planned/deployed for
  # different projects in a single workflow run.
  local project_slug
  project_slug=$(printf '%s' "$project_name" | tr -c 'a-zA-Z0-9._-' '_')
  printf 'DCM_PROJECT_SLUG<<GH_EOF\n%s\nGH_EOF\n' "$project_slug" >> "$GITHUB_ENV"

  {
    echo "project-name=$project_name"
    echo "manifest-account=$account"
    echo "manifest-role=$owner_role"
  } >> "$GITHUB_OUTPUT"
}

# Where the changeset starts and ends within a plan/deploy output. Used to move the
# changeset rows into their own collapsible section.
DCM_CHANGESET_START_REGEX='^(CREATE|ALTER|DROP)[[:space:]]'
DCM_CHANGESET_END_REGEX='^(Planned|Deployed|Purged|No changes detected)'
# Summary line of that section. It names the interaction rather than the content,
# because GitHub renders it next to a disclosure arrow.
DCM_CHANGESET_LABEL='collapse/expand'

# Emit a step summary for a command that prints a DCM changeset, identically to the
# step summary and to the PR-comment copy.
#
# Lines that start with CREATE/ALTER/DROP are prefixed with 🟩/🟨/🟥 so the colour
# coding is part of the output tree rather than a separate section. GitHub strips
# HTML and CSS from comment bodies, so emoji is the only reliably visible colouring
# option. Those rows are then moved into a <details> section, leaving the processing
# steps above it and the closing totals line below it.
#
# The fourth argument controls whether that section starts open. Plan passes `open`,
# because its comment is where a reviewer reads what will change; deploy passes
# `closed`, because by then the same rows have been reviewed. Output with no
# changeset rows, such as a failure before the plan ran, is emitted as one flat block.
#
# Usage: dcm_emit_changeset_summary <success|failure> <header> <output-file> [open|closed]
dcm_emit_changeset_summary() {
  local status="$1"
  local header="$2"
  local output_file="$3"
  local fold_state="${4:-open}"

  if [ "$status" = "success" ]; then
    gha_summary_line "### ✅ ${header}"
  else
    gha_summary_line "### ❌ ${header}"
  fi

  if [ ! -s "$output_file" ]; then
    gha_summary_line '```'
    gha_summary_line "No output captured. Check the Actions log for details."
    gha_summary_line '```'
    return
  fi

  local details_open='<details open>'
  if [ "$fold_state" = "closed" ]; then
    details_open='<details>'
  fi

  # preamble -> changeset -> epilogue. Blank lines are held back so a section never
  # ends on one, and are dropped entirely at a section boundary.
  local region="preamble"
  local pending_blanks=0
  local marked line

  gha_summary_line '```'
  while IFS= read -r line; do
    if [ -n "${GHA_OUTPUT_DROP_REGEX:-}" ] && [[ $line =~ $GHA_OUTPUT_DROP_REGEX ]]; then
      continue
    fi

    if [ "$region" = "preamble" ] && [[ $line =~ $DCM_CHANGESET_START_REGEX ]]; then
      pending_blanks=0
      gha_summary_line '```'
      gha_summary_line ''
      gha_summary_line "${details_open}<summary>${DCM_CHANGESET_LABEL}</summary>"
      gha_summary_line ''
      gha_summary_line '```'
      region="changeset"
    elif [ "$region" = "changeset" ] && [[ $line =~ $DCM_CHANGESET_END_REGEX ]]; then
      pending_blanks=0
      gha_summary_line '```'
      gha_summary_line ''
      gha_summary_line '</details>'
      gha_summary_line ''
      gha_summary_line '```'
      region="epilogue"
    fi

    if [ -z "$line" ]; then
      pending_blanks=$((pending_blanks + 1))
      continue
    fi
    while [ "$pending_blanks" -gt 0 ]; do
      gha_summary_line ''
      pending_blanks=$((pending_blanks - 1))
    done

    case "$line" in
      CREATE\ *) marked="🟩 $line" ;;
      ALTER\ *)  marked="🟨 $line" ;;
      DROP\ *)   marked="🟥 $line" ;;
      *)         marked="$line" ;;
    esac
    gha_summary_line "$marked"
  done < "$output_file"
  gha_summary_line '```'

  # A changeset that never reached its closing summary line still needs the section
  # closed, or the markdown that follows is swallowed by it.
  if [ "$region" = "changeset" ]; then
    gha_summary_line ''
    gha_summary_line '</details>'
  fi
}

# Persist a DCM step result to the shared results directory for later aggregation.
# Usage: dcm_write_result <kind> <target> <result>
dcm_write_result() {
  local kind="$1"
  local target="$2"
  local result="$3"
  gha_write_result "/tmp/dcm-results/dcm-${kind}-${target}.txt" "$result"
}
