#!/usr/bin/env bash
#
# Tests for scripts/setup-config-file.sh.
# Usage: bash tests/setup-config-file.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/setup-config-file.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: ${SCRIPT} not found"; exit 1; }

fail() { echo "FAIL: $1"; exit 1; }

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
STAGE_ROOT="$TEST_ROOT/tmp"
mkdir -p "$STAGE_ROOT"

run_script() {
  local workdir="$1" fake_home="$2" config_path="$3" runner_os="${4:-Linux}" rc=0
  (
    cd "$workdir"
    HOME="$fake_home" \
    RUNNER_OS="$runner_os" \
    TMPDIR="$STAGE_ROOT" \
    CONFIG_FILE_PATH="$config_path" \
      bash "$SCRIPT"
  ) || rc=$?
  return "$rc"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# A normal config is installed as a regular file with owner-only permissions,
# without leaving ./temp in the workspace.
WS="$TEST_ROOT/install/checkout"
HOME_DIR="$TEST_ROOT/install/home"
mkdir -p "$WS"
printf 'CONFIG-INSTALL\n' > "$WS/config.toml"
run_script "$WS" "$HOME_DIR" "./config.toml" || fail "install: script failed on a normal checkout"
[ -f "$HOME_DIR/.snowflake/config.toml" ] && [ ! -L "$HOME_DIR/.snowflake/config.toml" ] \
  || fail "install: config was not installed as a regular file"
grep -q 'CONFIG-INSTALL' "$HOME_DIR/.snowflake/config.toml" \
  || fail "install: installed config does not match the source"
[ "$(file_mode "$HOME_DIR/.snowflake/config.toml")" = "600" ] \
  || fail "install: installed config mode is not 600"
[ ! -e "$WS/temp" ] || fail "install: script created ./temp in the workspace"
echo "PASS: a normal config is installed into ~/.snowflake"

# A missing config path is a no-op.
WS="$TEST_ROOT/missing/checkout"
HOME_DIR="$TEST_ROOT/missing/home"
mkdir -p "$WS"
run_script "$WS" "$HOME_DIR" "./config.toml" || fail "missing: script should exit 0"
[ ! -e "$HOME_DIR/.snowflake/config.toml" ] \
  || fail "missing: nothing should be installed when the config is absent"
echo "PASS: a missing config file is a clean no-op"

# Replacing an existing config keeps a regular file.
WS="$TEST_ROOT/replace/checkout"
HOME_DIR="$TEST_ROOT/replace/home"
mkdir -p "$WS" "$HOME_DIR/.snowflake"
printf 'CONFIG-NEW\n' > "$WS/config.toml"
printf 'CONFIG-OLD\n' > "$HOME_DIR/.snowflake/config.toml"
run_script "$WS" "$HOME_DIR" "./config.toml" || fail "replace: script failed when replacing an existing config"
[ -f "$HOME_DIR/.snowflake/config.toml" ] && [ ! -L "$HOME_DIR/.snowflake/config.toml" ] \
  || fail "replace: replaced config is not a regular file"
grep -q 'CONFIG-NEW' "$HOME_DIR/.snowflake/config.toml" \
  || fail "replace: replaced config does not contain the new bytes"
echo "PASS: an existing config is replaced in place"

# Windows skips chmod; the file still installs.
WS="$TEST_ROOT/windows/checkout"
HOME_DIR="$TEST_ROOT/windows/home"
mkdir -p "$WS"
printf 'CONFIG-WINDOWS\n' > "$WS/config.toml"
run_script "$WS" "$HOME_DIR" "./config.toml" "Windows" || fail "windows: script failed with RUNNER_OS=Windows"
[ -f "$HOME_DIR/.snowflake/config.toml" ] && [ ! -L "$HOME_DIR/.snowflake/config.toml" ] \
  || fail "windows: config not installed as a regular file"
grep -q 'CONFIG-WINDOWS' "$HOME_DIR/.snowflake/config.toml" \
  || fail "windows: installed config does not match the source"
echo "PASS: RUNNER_OS=Windows still installs the config"

leftovers="$(find "$STAGE_ROOT" -mindepth 1 -print | wc -l | tr -d ' ')"
[ "$leftovers" = "0" ] || fail "temporary directory was not cleaned up ($leftovers leftover paths)"
echo "PASS: temporary directory is empty after install"

echo "ALL PASS"
