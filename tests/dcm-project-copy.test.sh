#!/usr/bin/env bash
#
# Checks for scripts/dcm-lib.sh: a copied project accepts a relative
# post-scripts path and rejects a path that leaves the copy.
#
# Usage: bash tests/dcm-project-copy.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/dcm-lib.sh
source "${REPO_ROOT}/scripts/dcm-lib.sh"

fail() { echo "FAIL: $1"; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
DEST="$ROOT/project"
mkdir -p "$DEST/scripts" "$ROOT/outside"
printf 'name: demo\n' > "$DEST/manifest.yml"
printf 'select 1;\n' > "$DEST/scripts/a.sql"

dcm_check_copied_project "$DEST" "scripts" || fail "a relative post-scripts path should be accepted"
echo "PASS: a relative post-scripts path is accepted"

rc=0
dcm_check_copied_project "$DEST" "../outside" || rc=$?
[ "$rc" -ne 0 ] || fail "a post-scripts path above the project should be rejected"
echo "PASS: a post-scripts path above the project is rejected"

rc=0
dcm_check_copied_project "$DEST" "$ROOT/outside" || rc=$?
[ "$rc" -ne 0 ] || fail "an absolute post-scripts path should be rejected"
echo "PASS: an absolute post-scripts path is rejected"

echo "ALL PASS"
