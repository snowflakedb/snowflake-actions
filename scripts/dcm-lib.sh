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

# Read a scalar value from manifest.yml with surrounding quotes stripped.
# Usage: dcm_manifest_value <yq-path> [manifest-path]
dcm_manifest_value() {
  local path="$1"
  local manifest="${2:-manifest.yml}"
  yq eval "$path" "$manifest" | sed 's/"//g' | sed "s/'//g"
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

  {
    echo "SNOWFLAKE_ACCOUNT=$account"
    echo "SNOWFLAKE_ROLE=$owner_role"
    echo "SNOWFLAKE_USER=$SNOWFLAKE_USER"
  } >> "$GITHUB_ENV"

  {
    echo "project-name=$project_name"
    echo "manifest-account=$account"
    echo "manifest-role=$owner_role"
  } >> "$GITHUB_OUTPUT"
}

# Persist a DCM step result to the shared results directory for later aggregation.
# Usage: dcm_write_result <kind> <target> <result>
dcm_write_result() {
  local kind="$1"
  local target="$2"
  local result="$3"
  gha_write_result "/tmp/dcm-results/dcm-${kind}-${target}.txt" "$result"
}
