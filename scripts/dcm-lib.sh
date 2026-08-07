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

# Emit a step summary for a command that prints a DCM changeset, with emoji
# injected inline into the CLI output. Used by both plan and deploy, which render
# the same changeset format. Lines that start with CREATE/ALTER/DROP are prefixed
# with 🟩/🟨/🟥 so the colour coding is part of the output tree rather than a
# separate section. GitHub strips HTML/CSS in PR comments, so emoji is the only
# reliably visible colouring option.
#
# Usage: dcm_emit_changeset_summary <success|failure> <header> <output-file>
dcm_emit_changeset_summary() {
  local status="$1"
  local header="$2"
  local output_file="$3"

  if [ "$status" = "success" ]; then
    gha_summary_line "### ✅ ${header}"
  else
    gha_summary_line "### ❌ ${header}"
  fi

  gha_summary_line '```'
  if [ -s "$output_file" ]; then
    while IFS= read -r line; do
      case "$line" in
        CREATE\ *) gha_summary_output_line "🟩 $line" "$line" ;;
        ALTER\ *)  gha_summary_output_line "🟨 $line" "$line" ;;
        DROP\ *)   gha_summary_output_line "🟥 $line" "$line" ;;
        *)         gha_summary_output_line "$line" ;;
      esac
    done < "$output_file"
  else
    gha_summary_line "No output captured. Check the Actions log for details."
  fi
  gha_summary_line '```'
}

# Persist a DCM step result to the shared results directory for later aggregation.
# Usage: dcm_write_result <kind> <target> <result>
dcm_write_result() {
  local kind="$1"
  local target="$2"
  local result="$3"
  gha_write_result "/tmp/dcm-results/dcm-${kind}-${target}.txt" "$result"
}
