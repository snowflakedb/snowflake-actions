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

  {
    echo "project-name=$project_name"
    echo "manifest-account=$account"
    echo "manifest-role=$owner_role"
  } >> "$GITHUB_OUTPUT"
}

# Emit a DCM plan step summary with emoji injected inline into the CLI output.
# Lines that start with CREATE/ALTER/DROP are prefixed with 🟩/🟨/🟥 so the
# colour coding is part of the output tree rather than a separate section.
# GitHub strips HTML/CSS in PR comments, so emoji is the only reliably visible
# colouring option.
#
# Usage: dcm_emit_plan_summary <success|failure> <header> <output-file>
dcm_emit_plan_summary() {
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
        CREATE\ *) gha_summary_line "🟩 $line" ;;
        ALTER\ *)  gha_summary_line "🟨 $line" ;;
        DROP\ *)   gha_summary_line "🟥 $line" ;;
        *)         gha_summary_line "$line" ;;
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
