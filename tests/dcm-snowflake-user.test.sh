#!/usr/bin/env bash
#
# snowflake-user is optional. An empty value must not export SNOWFLAKE_USER,
# because the CLI sends that variable as LOGIN_NAME. A later snow step must
# also drop a user inherited from the job when no login name was provided.
#
# Usage: bash tests/dcm-snowflake-user.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/dcm-lib.sh
source "${REPO_ROOT}/scripts/dcm-lib.sh"

fail() { echo "FAIL: $1"; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

export_user() {
  GITHUB_ENV="$ROOT/env"
  : > "$GITHUB_ENV"
  dcm_export_snowflake_user "$1"
}

export_user ""
grep -q 'DCM_SNOWFLAKE_USER_SET=false' "$GITHUB_ENV" || fail "an empty user should record that no login name was set"
if grep -q '^SNOWFLAKE_USER' "$GITHUB_ENV"; then
  fail "an empty user must not write SNOWFLAKE_USER"
fi
echo "PASS: an empty user does not export SNOWFLAKE_USER"

export_user "SVC_GITHUB_ACTIONS"
grep -q 'DCM_SNOWFLAKE_USER_SET=true' "$GITHUB_ENV" || fail "a login name should be recorded"
grep -q 'SNOWFLAKE_USER<<GH_EOF' "$GITHUB_ENV" || fail "a login name should be written with the multiline env syntax"
grep -q 'SVC_GITHUB_ACTIONS' "$GITHUB_ENV" || fail "the login name should be preserved"
echo "PASS: a login name is exported"

rc=0
export_user $'bad\nuser' || rc=$?
[ "$rc" -ne 0 ] || fail "a newline in snowflake-user should be rejected"
if grep -q 'SNOWFLAKE_USER' "$GITHUB_ENV"; then
  fail "a rejected user must not be written"
fi
echo "PASS: a newline in snowflake-user is rejected"

rc=0
export_user $'bad\ruser' || rc=$?
[ "$rc" -ne 0 ] || fail "a carriage return in snowflake-user should be rejected"
if grep -q 'SNOWFLAKE_USER' "$GITHUB_ENV"; then
  fail "a rejected user must not be written"
fi
echo "PASS: a carriage return in snowflake-user is rejected"

export SNOWFLAKE_USER="leaked-from-job"
export DCM_SNOWFLAKE_USER_SET=false
dcm_apply_snowflake_user
[ -z "${SNOWFLAKE_USER:-}" ] || fail "snow should not see a job-level user when no login name was provided"
echo "PASS: a job-level user is unset when no login name was provided"

export SNOWFLAKE_USER="SVC_GITHUB_ACTIONS"
export DCM_SNOWFLAKE_USER_SET=true
dcm_apply_snowflake_user
[ "${SNOWFLAKE_USER:-}" = "SVC_GITHUB_ACTIONS" ] || fail "an explicit login name should be kept"
echo "PASS: an explicit login name is kept"

echo "ALL PASS"
