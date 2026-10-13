#!/usr/bin/env bash
#
# Offline install and OIDC audience behavior (SNOW-4248736).
# Usage: bash tests/iso-offline.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() { echo "FAIL: $1"; exit 1; }

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Isolated PATH: real python3 stays available, curl/uv/snow are the fakes we add.
REAL_PYTHON_DIR="$(dirname "$(command -v python3)")"
export PATH="${TEST_ROOT}/bin:${REAL_PYTHON_DIR}:/usr/bin:/bin"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home/.local/bin"
export HOME="$TEST_ROOT/home"

# --- plan: preinstalled snow skips both downloads ---
cat > "$TEST_ROOT/bin/snow" << 'EOF'
#!/bin/sh
echo "snow 9.9.9"
EOF
chmod +x "$TEST_ROOT/bin/snow"

PLAN_OUT="$TEST_ROOT/plan-skip.out"
GITHUB_PATH="$TEST_ROOT/plan-skip.path" \
GITHUB_OUTPUT="$PLAN_OUT" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: preinstalled snow should succeed"
grep -qx 'skip_install=true' "$PLAN_OUT" || fail "plan: expected skip_install=true"
grep -qx 'skip_uv_setup=true' "$PLAN_OUT" || fail "plan: expected skip_uv_setup=true"
grep -qx "$TEST_ROOT/bin" "$TEST_ROOT/plan-skip.path" \
    || fail "plan: did not publish the preinstalled snow directory"
echo "PASS: preinstalled snow skips uv and the CLI download"

# --- plan: explicit latest does not skip ---
PLAN_OUT="$TEST_ROOT/plan-latest.out"
CLI_VERSION=latest GITHUB_OUTPUT="$PLAN_OUT" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: cli-version=latest should succeed"
grep -qx 'skip_install=false' "$PLAN_OUT" || fail "plan: latest should not skip install"
grep -qx 'skip_uv_setup=false' "$PLAN_OUT" || fail "plan: latest should not skip uv"
echo "PASS: cli-version=latest still downloads"

# --- plan: cli-artifact skips uv setup and refuses a version pin ---
PLAN_OUT="$TEST_ROOT/plan-artifact.out"
CLI_ARTIFACT=./dist/snow.whl GITHUB_OUTPUT="$PLAN_OUT" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: cli-artifact should succeed"
grep -qx 'skip_install=false' "$PLAN_OUT" || fail "plan: artifact should still install"
grep -qx 'skip_uv_setup=true' "$PLAN_OUT" || fail "plan: artifact should skip uv setup"
echo "PASS: cli-artifact skips the uv download"

set +e
CLI_VERSION=3.20.0 CLI_ARTIFACT=./dist/snow.whl GITHUB_OUTPUT="$TEST_ROOT/plan-conflict.out" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" >/dev/null 2>&1
conflict_rc=$?
set -e
[ "$conflict_rc" -ne 0 ] || fail "plan: cli-version plus cli-artifact should fail"
echo "PASS: cli-artifact cannot be combined with cli-version"

# --- install: preinstalled snow does not invoke uv ---
cat > "$TEST_ROOT/bin/uv" << 'EOF'
#!/bin/sh
echo "uv should not have been called: $*" >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/uv"
bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" \
    || fail "install: preinstalled snow should succeed without uv"
echo "PASS: install script reuses snow already on PATH"

# --- install: explicit latest reaches uv ---
rm -f "$TEST_ROOT/bin/snow"
cat > "$TEST_ROOT/bin/uv" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$UV_LOG"
# Pretend the tool install dropped a snow binary.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/snow" << 'EOS'
#!/bin/sh
echo "snow from-uv"
EOS
chmod +x "$HOME/.local/bin/snow"
EOF
chmod +x "$TEST_ROOT/bin/uv"
UV_LOG="$TEST_ROOT/uv-latest.log"
CLI_VERSION=latest UV_LOG="$UV_LOG" \
    bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" \
    || fail "install: latest should call uv"
grep -q 'tool install --python 3.11 snowflake-cli' "$UV_LOG" \
    || fail "install: latest did not call uv tool install"
echo "PASS: cli-version=latest installs from PyPI via uv"

# --- install: local wheel is offline and uses the wheel's directory as find-links ---
rm -f "$HOME/.local/bin/snow" "$TEST_ROOT/bin/snow"
mkdir -p "$TEST_ROOT/wheels"
printf 'not a real wheel' > "$TEST_ROOT/wheels/snowflake_cli-1.2.3-py3-none-any.whl"
UV_LOG="$TEST_ROOT/uv-wheel.log"
: > "$UV_LOG"
CLI_ARTIFACT="$TEST_ROOT/wheels/snowflake_cli-1.2.3-py3-none-any.whl" UV_LOG="$UV_LOG" \
    bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" \
    || fail "install: local wheel should succeed"
grep -q -- '--offline' "$UV_LOG" || fail "install: wheel path was not offline"
grep -q -- "--find-links ${TEST_ROOT}/wheels" "$UV_LOG" \
    || fail "install: wheel path did not pass the sibling directory as find-links"
grep -q 'pypi' "$UV_LOG" && fail "install: wheel path mentioned pypi"
echo "PASS: cli-artifact installs offline from the local wheel"

# --- install: missing uv with an artifact fails before any download ---
rm -f "$TEST_ROOT/bin/uv" "$HOME/.local/bin/snow"
set +e
CLI_ARTIFACT="$TEST_ROOT/wheels/snowflake_cli-1.2.3-py3-none-any.whl" \
    bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" >"$TEST_ROOT/missing-uv.out" 2>&1
missing_uv_rc=$?
set -e
[ "$missing_uv_rc" -ne 0 ] || fail "install: missing uv should fail"
grep -q 'uv is not on PATH' "$TEST_ROOT/missing-uv.out" \
    || fail "install: missing uv error did not name uv"
echo "PASS: cli-artifact without uv fails loudly"

# --- oidc audience is forwarded into the token request and GITHUB_ENV ---
cat > "$TEST_ROOT/bin/curl" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$CURL_LOG"
printf '%s' '{"value":"eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0In0.sig"}'
EOF
chmod +x "$TEST_ROOT/bin/curl"
# The install tests left a fake uv that writes UV_LOG. Drop it so it cannot
# interfere, and drop snow so we know the token path does not need it.
rm -f "$TEST_ROOT/bin/uv" "$TEST_ROOT/bin/snow" "$HOME/.local/bin/snow"

CURL_LOG="$TEST_ROOT/curl-aud.log"
GITHUB_ENV="$TEST_ROOT/github.env"
: > "$GITHUB_ENV"
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
SNOWFLAKE_AUDIENCE="snowflake.iso.example/aud" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
CURL_LOG="$CURL_LOG" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: custom audience should succeed"
grep -q 'audience=snowflake.iso.example%2Faud' "$CURL_LOG" \
    || fail "oidc-token: audience was not URL-encoded into the request"
grep -qx 'SNOWFLAKE_AUDIENCE=snowflake.iso.example/aud' "$GITHUB_ENV" \
    || fail "oidc-token: GITHUB_ENV audience was not the override"
grep -q 'snowflakecomputing.com' "$CURL_LOG" \
    && fail "oidc-token: commercial audience leaked into the request"
echo "PASS: oidc-token requests the configured audience"

# Default audience stays the commercial suffix.
CURL_LOG="$TEST_ROOT/curl-default.log"
GITHUB_ENV="$TEST_ROOT/github-default.env"
: > "$GITHUB_ENV"
unset SNOWFLAKE_AUDIENCE || true
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
CURL_LOG="$CURL_LOG" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: default audience should succeed"
grep -q 'audience=snowflakecomputing.com' "$CURL_LOG" \
    || fail "oidc-token: default audience was not snowflakecomputing.com"
echo "PASS: default OIDC audience is unchanged"

# configure-snowflake-oidc writes the same audience it minted with.
# A pre-set token makes oidc-token.sh return before curling; the configure
# script must still publish the override for later steps.
GITHUB_ENV="$TEST_ROOT/configure.env"
: > "$GITHUB_ENV"
SNOWFLAKE_TOKEN="already-minted" \
SNOWFLAKE_AUDIENCE="iso.example" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/configure-snowflake-oidc.sh" \
    || fail "configure: override audience should succeed"
grep -qx 'SNOWFLAKE_AUDIENCE=iso.example' "$GITHUB_ENV" \
    || fail "configure: did not publish the override audience"
grep -qx 'SNOWFLAKE_AUDIENCE=snowflakecomputing.com' "$GITHUB_ENV" \
    && fail "configure: hardcoded commercial audience overwrote the override"
echo "PASS: configure-snowflake-oidc publishes the override audience"

# --- cortex: local binary does not curl ---
cat > "$TEST_ROOT/bin/curl" << 'EOF'
#!/bin/sh
echo "curl should not have been called: $*" >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/curl"
printf '#!/bin/sh\necho cortex-local\n' > "$TEST_ROOT/cortex-bin"
chmod +x "$TEST_ROOT/cortex-bin"
GITHUB_PATH="$TEST_ROOT/github.path" \
CORTEX_BINARY="$TEST_ROOT/cortex-bin" \
    bash "$REPO_ROOT/cortex-code/scripts/install-cortex.sh" \
    || fail "cortex: local binary should succeed"
[ -x "$HOME/.local/bin/cortex" ] || fail "cortex: local binary was not installed"
echo "PASS: cortex-binary does not contact ai.snowflake.com"

# Preinstalled cortex is reused.
rm -f "$HOME/.local/bin/cortex"
printf '#!/bin/sh\necho cortex-preinstalled\n' > "$TEST_ROOT/bin/cortex"
chmod +x "$TEST_ROOT/bin/cortex"
GITHUB_PATH="$TEST_ROOT/github.path" \
    bash "$REPO_ROOT/cortex-code/scripts/install-cortex.sh" \
    || fail "cortex: preinstalled binary should succeed"
echo "PASS: cortex already on PATH skips the installer download"
