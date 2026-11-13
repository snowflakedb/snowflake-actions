#!/usr/bin/env bash
#
# Offline install and OIDC audience behavior (SNOW-4248736).
# Usage: bash tests/iso-offline.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() { echo "FAIL: $1"; exit 1; }

jwt_with_aud() {
    python3 -c '
import base64, json, sys
payload = json.dumps({"aud": sys.argv[1], "sub": "t"}).encode()
def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
print(b64(b"{\"alg\":\"none\"}") + "." + b64(payload) + ".sig")
' "$1"
}

TEST_ROOT="$(mktemp -d)"
cleanup() {
    local pidfile pid
    if [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ]; then
        while IFS= read -r pidfile; do
            pid="$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || true)"
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null || true
            fi
        done < <(find "$TEST_ROOT" -name refresh.pid -type f 2>/dev/null || true)
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

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

unset SNOWFLAKE_CLI_AIR_GAPPED SF_CICD_CLI_SOURCE || true
PLAN_OUT="$TEST_ROOT/plan-skip.out"
PLAN_ENV="$TEST_ROOT/plan-skip.env"
: > "$PLAN_ENV"
GITHUB_PATH="$TEST_ROOT/plan-skip.path" \
GITHUB_OUTPUT="$PLAN_OUT" \
GITHUB_ENV="$PLAN_ENV" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: preinstalled snow should succeed"
grep -qx 'skip_install=true' "$PLAN_OUT" || fail "plan: expected skip_install=true"
grep -qx 'skip_uv_setup=true' "$PLAN_OUT" || fail "plan: expected skip_uv_setup=true"
grep -qx "$TEST_ROOT/bin" "$TEST_ROOT/plan-skip.path" \
    || fail "plan: did not publish the preinstalled snow directory"
grep -qx 'SNOWFLAKE_CLI_AIR_GAPPED=true' "$PLAN_ENV" \
    || fail "plan: preinstalled snow did not export SNOWFLAKE_CLI_AIR_GAPPED"
echo "PASS: preinstalled snow skips uv and the CLI download and exports air-gapped mode"

# A snow this job already installed from PyPI must not be flipped.
PLAN_OUT="$TEST_ROOT/plan-reuse-network.out"
PLAN_ENV="$TEST_ROOT/plan-reuse-network.env"
: > "$PLAN_ENV"
SF_CICD_CLI_SOURCE=network \
GITHUB_PATH="$TEST_ROOT/plan-reuse-network.path" \
GITHUB_OUTPUT="$PLAN_OUT" \
GITHUB_ENV="$PLAN_ENV" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: reuse after a network install should succeed"
grep -qx 'skip_install=true' "$PLAN_OUT" || fail "plan: network reuse should still skip install"
grep -q 'SNOWFLAKE_CLI_AIR_GAPPED=' "$PLAN_ENV" \
    && fail "plan: network reuse exported SNOWFLAKE_CLI_AIR_GAPPED"
echo "PASS: reusing a CLI installed from the network does not set air-gapped mode"

# An explicit false is an opt-out.
PLAN_ENV="$TEST_ROOT/plan-explicit-false.env"
: > "$PLAN_ENV"
SNOWFLAKE_CLI_AIR_GAPPED=false \
GITHUB_OUTPUT="$TEST_ROOT/plan-explicit-false.out" \
GITHUB_ENV="$PLAN_ENV" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: explicit SNOWFLAKE_CLI_AIR_GAPPED=false should succeed"
[ ! -s "$PLAN_ENV" ] || fail "plan: explicit false was overwritten"
echo "PASS: an explicit SNOWFLAKE_CLI_AIR_GAPPED is left unchanged"

# --- plan: explicit latest does not skip ---
PLAN_OUT="$TEST_ROOT/plan-latest.out"
PLAN_ENV="$TEST_ROOT/plan-latest.env"
: > "$PLAN_ENV"
CLI_VERSION=latest GITHUB_OUTPUT="$PLAN_OUT" GITHUB_ENV="$PLAN_ENV" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: cli-version=latest should succeed"
grep -qx 'skip_install=false' "$PLAN_OUT" || fail "plan: latest should not skip install"
grep -qx 'skip_uv_setup=false' "$PLAN_OUT" || fail "plan: latest should not skip uv"
grep -q 'SNOWFLAKE_CLI_AIR_GAPPED=' "$PLAN_ENV" \
    && fail "plan: cli-version=latest exported SNOWFLAKE_CLI_AIR_GAPPED"
echo "PASS: cli-version=latest still downloads"

# --- plan: cli-artifact skips uv setup and refuses a version pin ---
PLAN_OUT="$TEST_ROOT/plan-artifact.out"
PLAN_ENV="$TEST_ROOT/plan-artifact.env"
: > "$PLAN_ENV"
CLI_ARTIFACT=./dist/snow.whl GITHUB_OUTPUT="$PLAN_OUT" GITHUB_ENV="$PLAN_ENV" \
    bash "$REPO_ROOT/scripts/plan-snowflake-cli-install.sh" \
    || fail "plan: cli-artifact should succeed"
grep -qx 'skip_install=false' "$PLAN_OUT" || fail "plan: artifact should still install"
grep -qx 'skip_uv_setup=true' "$PLAN_OUT" || fail "plan: artifact should skip uv setup"
grep -qx 'SNOWFLAKE_CLI_AIR_GAPPED=true' "$PLAN_ENV" \
    || fail "plan: cli-artifact did not export SNOWFLAKE_CLI_AIR_GAPPED"
echo "PASS: cli-artifact skips the uv download and exports air-gapped mode"

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
INSTALL_ENV="$TEST_ROOT/install-preinstalled.env"
: > "$INSTALL_ENV"
unset SNOWFLAKE_CLI_AIR_GAPPED SF_CICD_CLI_SOURCE || true
GITHUB_ENV="$INSTALL_ENV" \
    bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" \
    || fail "install: preinstalled snow should succeed without uv"
grep -qx 'SNOWFLAKE_CLI_AIR_GAPPED=true' "$INSTALL_ENV" \
    || fail "install: preinstalled snow did not export SNOWFLAKE_CLI_AIR_GAPPED"
echo "PASS: install script reuses snow already on PATH and exports air-gapped mode"

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
INSTALL_ENV="$TEST_ROOT/install-latest.env"
: > "$INSTALL_ENV"
unset SNOWFLAKE_CLI_AIR_GAPPED SF_CICD_CLI_SOURCE || true
CLI_VERSION=latest UV_LOG="$UV_LOG" GITHUB_ENV="$INSTALL_ENV" \
    bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" \
    || fail "install: latest should call uv"
grep -q 'tool install --no-build --python 3.11 snowflake-cli' "$UV_LOG" \
    || fail "install: latest did not call uv tool install --no-build"
grep -qx 'SF_CICD_CLI_SOURCE=network' "$INSTALL_ENV" \
    || fail "install: latest did not record a network install"
grep -q 'SNOWFLAKE_CLI_AIR_GAPPED=' "$INSTALL_ENV" \
    && fail "install: latest exported SNOWFLAKE_CLI_AIR_GAPPED"
echo "PASS: cli-version=latest installs from PyPI via uv"

# --- install: local wheel is offline and uses the wheel's directory as find-links ---
rm -f "$HOME/.local/bin/snow" "$TEST_ROOT/bin/snow"
mkdir -p "$TEST_ROOT/wheels"
printf 'not a real wheel' > "$TEST_ROOT/wheels/snowflake_cli-1.2.3-py3-none-any.whl"
UV_LOG="$TEST_ROOT/uv-wheel.log"
INSTALL_ENV="$TEST_ROOT/install-wheel.env"
: > "$UV_LOG"
: > "$INSTALL_ENV"
unset SNOWFLAKE_CLI_AIR_GAPPED SF_CICD_CLI_SOURCE || true
CLI_ARTIFACT="$TEST_ROOT/wheels/snowflake_cli-1.2.3-py3-none-any.whl" UV_LOG="$UV_LOG" \
GITHUB_ENV="$INSTALL_ENV" \
    bash "$REPO_ROOT/scripts/install-snowflake-cli.sh" \
    || fail "install: local wheel should succeed"
grep -q -- '--offline' "$UV_LOG" || fail "install: wheel path was not offline"
grep -q -- "--find-links ${TEST_ROOT}/wheels" "$UV_LOG" \
    || fail "install: wheel path did not pass the sibling directory as find-links"
grep -q 'pypi' "$UV_LOG" && fail "install: wheel path mentioned pypi"
grep -qx 'SNOWFLAKE_CLI_AIR_GAPPED=true' "$INSTALL_ENV" \
    || fail "install: wheel path did not export SNOWFLAKE_CLI_AIR_GAPPED"
grep -q 'SF_CICD_CLI_SOURCE=network' "$INSTALL_ENV" \
    && fail "install: wheel path recorded a network install"
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
unset SNOWFLAKE_TOKEN BASH_ENV || true
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
grep -qx 'SF_CICD_AUTH_TYPE=oidc' "$GITHUB_ENV" \
    || fail "oidc-token: GITHUB_ENV did not record oidc auth"
grep -q 'eyJhbGciOiJub25lIn0' "$GITHUB_ENV" \
    && fail "oidc-token: minted token was written to GITHUB_ENV"
grep -q '_FILE_PATH=' "$GITHUB_ENV" \
    && fail "oidc-token: GITHUB_ENV published a token file"
grep -qx "BASH_ENV=${REPO_ROOT}/scripts/oidc-token-keepalive.sh" "$GITHUB_ENV" \
    || fail "oidc-token: BASH_ENV does not refresh the token"
grep -qx 'OIDC_TOKEN_NAME=SNOWFLAKE_TOKEN' "$GITHUB_ENV" \
    || fail "oidc-token: token variable name was not published"
if [ -e "$TEST_ROOT/oidc-state/token" ] || [ -e "$TEST_ROOT/oidc-state/refresh.pid" ]; then
    fail "oidc-token: token was written to disk"
fi
grep -q 'snowflakecomputing.com' "$CURL_LOG" \
    && fail "oidc-token: commercial audience leaked into the request"
echo "PASS: oidc-token requests the configured audience"

# Default audience stays the commercial suffix.
CURL_LOG="$TEST_ROOT/curl-default.log"
GITHUB_ENV="$TEST_ROOT/github-default.env"
: > "$GITHUB_ENV"
unset SNOWFLAKE_AUDIENCE OIDC_AUDIENCE SNOWFLAKE_CLI_AIR_GAPPED || true
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

# Air-gapped mode refuses to invent the commercial audience. A job-level
# SNOWFLAKE_AUDIENCE still wins, and an explicit OIDC_AUDIENCE wins over that.
unset SNOWFLAKE_CLI_AIR_GAPPED || true
CURL_LOG="$TEST_ROOT/curl-airgap.log"
: > "$CURL_LOG"
GITHUB_ENV="$TEST_ROOT/github-airgap.env"
: > "$GITHUB_ENV"
set +e
SNOWFLAKE_CLI_AIR_GAPPED=true \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
CURL_LOG="$CURL_LOG" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" >"$TEST_ROOT/oidc-airgap.out" 2>&1
airgap_rc=$?
set -e
[ "$airgap_rc" -ne 0 ] || fail "oidc-token: air-gapped with no audience should fail"
grep -q 'SNOWFLAKE_AUDIENCE is not set' "$TEST_ROOT/oidc-airgap.out" \
    || fail "oidc-token: air-gapped error did not require an audience"
[ ! -s "$CURL_LOG" ] || fail "oidc-token: air-gapped failure still called curl"
echo "PASS: air-gapped oidc-token refuses the commercial default"

CURL_LOG="$TEST_ROOT/curl-airgap-env.log"
GITHUB_ENV="$TEST_ROOT/github-airgap-env.env"
: > "$GITHUB_ENV"
SNOWFLAKE_CLI_AIR_GAPPED=true \
SNOWFLAKE_AUDIENCE="iso.example" \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
CURL_LOG="$CURL_LOG" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: air-gapped with SNOWFLAKE_AUDIENCE should succeed"
grep -q 'audience=iso.example' "$CURL_LOG" \
    || fail "oidc-token: air-gapped run did not use SNOWFLAKE_AUDIENCE"
echo "PASS: air-gapped oidc-token keeps a job-level SNOWFLAKE_AUDIENCE"

CURL_LOG="$TEST_ROOT/curl-airgap-input.log"
GITHUB_ENV="$TEST_ROOT/github-airgap-input.env"
: > "$GITHUB_ENV"
SNOWFLAKE_CLI_AIR_GAPPED=true \
SNOWFLAKE_AUDIENCE="job.example" \
OIDC_AUDIENCE="step.example" \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
CURL_LOG="$CURL_LOG" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: explicit OIDC_AUDIENCE should succeed"
grep -q 'audience=step.example' "$CURL_LOG" \
    || fail "oidc-token: OIDC_AUDIENCE did not win over SNOWFLAKE_AUDIENCE"
echo "PASS: oidc-audience input wins over the job audience"

set +e
SNOWFLAKE_CLI_AIR_GAPPED=yes \
GITHUB_ENV="$TEST_ROOT/github-airgap-bad.env" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" >"$TEST_ROOT/oidc-airgap-bad.out" 2>&1
airgap_bad_rc=$?
set -e
[ "$airgap_bad_rc" -ne 0 ] || fail "oidc-token: invalid SNOWFLAKE_CLI_AIR_GAPPED should fail"
grep -q 'true, false, 1, or 0' "$TEST_ROOT/oidc-airgap-bad.out" \
    || fail "oidc-token: invalid air-gapped value was not rejected"
echo "PASS: oidc-token rejects a non-boolean SNOWFLAKE_CLI_AIR_GAPPED"

set +e
SNOWFLAKE_CLI_AIR_GAPPED=true \
GITHUB_ENV="$TEST_ROOT/configure-airgap.env" \
    bash "$REPO_ROOT/scripts/configure-snowflake-oidc.sh" >"$TEST_ROOT/configure-airgap.out" 2>&1
configure_airgap_rc=$?
set -e
[ "$configure_airgap_rc" -ne 0 ] || fail "configure: air-gapped with no audience should fail"
grep -q 'SNOWFLAKE_AUDIENCE is not set' "$TEST_ROOT/configure-airgap.out" \
    || fail "configure: air-gapped error did not require an audience"
echo "PASS: configure-snowflake-oidc refuses the commercial default when air-gapped"

# A carriage return must not reach GITHUB_ENV. The runner splits that file on
# CR as well as LF.
set +e
SNOWFLAKE_AUDIENCE=$'iso.example\rEVIL=1' \
GITHUB_ENV="$TEST_ROOT/github-cr.env" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" >"$TEST_ROOT/oidc-cr.out" 2>&1
cr_rc=$?
set -e
[ "$cr_rc" -ne 0 ] || fail "oidc-token: carriage return in audience should fail"
grep -q 'single line' "$TEST_ROOT/oidc-cr.out" \
    || fail "oidc-token: carriage return error did not say single line"
echo "PASS: oidc-token rejects a carriage return in the audience"

set +e
SNOWFLAKE_AUDIENCE=$'iso.example\rEVIL=1' \
GITHUB_ENV="$TEST_ROOT/configure-cr.env" \
    bash "$REPO_ROOT/scripts/configure-snowflake-oidc.sh" >"$TEST_ROOT/configure-cr.out" 2>&1
configure_cr_rc=$?
set -e
[ "$configure_cr_rc" -ne 0 ] || fail "configure: carriage return in audience should fail"
echo "PASS: configure-snowflake-oidc rejects a carriage return in the audience"

# Reuse writes the audience before returning, and only when the existing
# token's aud matches. Curl must not run.
cat > "$TEST_ROOT/bin/curl" << 'EOF'
#!/bin/sh
echo "curl should not have been called: $*" >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/curl"
REUSE_TOKEN="$(jwt_with_aud "iso.example")"
GITHUB_ENV="$TEST_ROOT/reuse.env"
: > "$GITHUB_ENV"
SNOWFLAKE_TOKEN="$REUSE_TOKEN" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: reuse with a matching audience should succeed"
grep -qx 'SNOWFLAKE_AUDIENCE=iso.example' "$GITHUB_ENV" \
    || fail "oidc-token: reuse did not write SNOWFLAKE_AUDIENCE"
echo "PASS: oidc-token reuse writes the audience and does not mint"

GITHUB_ENV="$TEST_ROOT/reuse-mismatch.env"
: > "$GITHUB_ENV"
set +e
SNOWFLAKE_TOKEN="$(jwt_with_aud "snowflakecomputing.com")" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" >"$TEST_ROOT/reuse-mismatch.out" 2>&1
mismatch_rc=$?
set -e
[ "$mismatch_rc" -ne 0 ] || fail "oidc-token: reuse with a different audience should fail"
grep -q 'different audience' "$TEST_ROOT/reuse-mismatch.out" \
    || fail "oidc-token: mismatch error did not name the audience"
grep -q 'SNOWFLAKE_AUDIENCE=' "$GITHUB_ENV" \
    && fail "oidc-token: mismatch wrote SNOWFLAKE_AUDIENCE"
echo "PASS: oidc-token refuses to reuse a token minted for another audience"

# configure-snowflake-oidc writes the same audience it minted with.
# A pre-set token makes oidc-token.sh return before curling; the configure
# script must still publish the override for later steps.
GITHUB_ENV="$TEST_ROOT/configure.env"
: > "$GITHUB_ENV"
SNOWFLAKE_TOKEN="$(jwt_with_aud "iso.example")" \
SNOWFLAKE_AUDIENCE="iso.example" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/configure-snowflake-oidc.sh" \
    || fail "configure: override audience should succeed"
grep -qx 'SNOWFLAKE_AUDIENCE=iso.example' "$GITHUB_ENV" \
    || fail "configure: did not publish the override audience"
grep -qx 'SNOWFLAKE_AUDIENCE=snowflakecomputing.com' "$GITHUB_ENV" \
    && fail "configure: hardcoded commercial audience overwrote the override"
echo "PASS: configure-snowflake-oidc publishes the override audience"

# A token the job already supplied is not rotated.
REUSE_DIR="$TEST_ROOT/oidc-reuse-refresh"
GITHUB_ENV="$TEST_ROOT/reuse-no-refresh.env"
: > "$GITHUB_ENV"
OIDC_TOKEN_REFRESH=true \
OIDC_REFRESH_STATE_DIR="$REUSE_DIR" \
OIDC_TOKEN_REFRESH_INTERVAL=1 \
SNOWFLAKE_TOKEN="$(jwt_with_aud "iso.example")" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: reuse with refresh enabled should succeed"
[ ! -e "$REUSE_DIR/refresh.pid" ] \
    || fail "oidc-token: reusing a supplied token started a refresher"
grep -q '_FILE_PATH=' "$GITHUB_ENV" \
    && fail "oidc-token: reuse published a token file this action does not update"
echo "PASS: oidc-token does not refresh a token it did not mint"

# A mint checks that OIDC works, then drops the token. Later bash steps mint a
# new token in the background every 4 minutes. The token is not written to
# GITHUB_ENV or to a file.
REFRESH_DIR="$TEST_ROOT/oidc-refresh"
mkdir -p "$REFRESH_DIR"
COUNTER="$REFRESH_DIR/count"
printf '0' > "$COUNTER"
export COUNTER
cat > "$TEST_ROOT/bin/curl" << 'EOF'
#!/bin/sh
n=$(cat "$COUNTER")
n=$((n + 1))
printf '%s' "$n" > "$COUNTER"
printf '%s' "{\"value\":\"token-$n\"}"
EOF
chmod +x "$TEST_ROOT/bin/curl"
unset SNOWFLAKE_TOKEN SNOWFLAKE_TOKEN_FILE_PATH BASH_ENV || true
GITHUB_ENV="$TEST_ROOT/refresh-github.env"
: > "$GITHUB_ENV"
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
GITHUB_ENV="$GITHUB_ENV" \
    bash "$REPO_ROOT/scripts/oidc-token.sh" \
    || fail "oidc-token: mint check should succeed"
[ "$(cat "$COUNTER")" = "1" ] || fail "oidc-token: mint check did not request a token"
grep -qx 'SF_CICD_AUTH_TYPE=oidc' "$GITHUB_ENV" \
    || fail "oidc-token: mint check did not record oidc auth"
grep -q 'token-1' "$GITHUB_ENV" \
    && fail "oidc-token: mint check wrote the token into GITHUB_ENV"
if [ -e "$REFRESH_DIR/token" ] || [ -e "$REFRESH_DIR/refresh.pid" ]; then
    fail "oidc-token: mint check wrote the token to disk"
fi
keepalive="$REPO_ROOT/scripts/oidc-token-keepalive.sh"
refreshed="$(
    BASH_ENV="$keepalive" \
    SNOWFLAKE_AUDIENCE="iso.example" \
    OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    GITHUB_ENV="$GITHUB_ENV" \
    COUNTER="$COUNTER" \
    bash -c 'printf %s "$SNOWFLAKE_TOKEN"' | tail -n 1
)"
[ "$refreshed" = "token-2" ] || fail "oidc-token: bash step did not export a fresh token (got ${refreshed})"
[ "$(cat "$COUNTER")" = "2" ] || fail "oidc-token: bash step did not mint"
grep -q 'token-2' "$GITHUB_ENV" \
    && fail "oidc-token: refreshed token was written to GITHUB_ENV"
rotated="$(
    BASH_ENV="$keepalive" \
    SNOWFLAKE_AUDIENCE="iso.example" \
    OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
    OIDC_TOKEN_ISSUED_AT="$(date +%s)" \
    SNOWFLAKE_TOKEN="token-2" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    GITHUB_ENV="$GITHUB_ENV" \
    COUNTER="$COUNTER" \
    bash -c 'OIDC_TOKEN_ISSUED_AT=0; printf %s "$SNOWFLAKE_TOKEN"' | tail -n 1
)"
[ "$rotated" = "token-3" ] || fail "oidc-token: a later command did not replace a token older than the interval (got ${rotated})"
[ "$(cat "$COUNTER")" = "3" ] || fail "oidc-token: stale token was not refreshed"
if [ -e "$REFRESH_DIR/token" ] || [ -e "${TMPDIR:-/tmp}/snowflake-oidc-refresh/token" ]; then
    fail "oidc-token: refresh wrote the token to disk"
fi

# The background child mints on the interval while this shell is idle.
# The next command exports that token. Nothing is written to a file.
before_bg="$(cat "$COUNTER")"
prefetched="$(
    BASH_ENV="$keepalive" \
    SNOWFLAKE_AUDIENCE="iso.example" \
    OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
    OIDC_TOKEN_REFRESH_INTERVAL=1 \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    GITHUB_ENV="$GITHUB_ENV" \
    COUNTER="$COUNTER" \
    bash -c '
        start=$SNOWFLAKE_TOKEN
        i=0
        while [ "$i" -lt 8 ]; do
            i=$((i + 1))
            sleep 1
            [ "$SNOWFLAKE_TOKEN" != "$start" ] && break
        done
        printf %s "$SNOWFLAKE_TOKEN"
    ' | tail -n 1
)"
sync_n=$((before_bg + 1))
prefetched_n="${prefetched#token-}"
case "$prefetched_n" in
    ''|*[!0-9]*) fail "oidc-token: background refresh did not export a token (got ${prefetched})" ;;
esac
[ "$prefetched_n" -gt "$sync_n" ] \
    || fail "oidc-token: background refresh did not pre-mint (got ${prefetched}, first mint was token-${sync_n})"
grep -q "$prefetched" "$GITHUB_ENV" \
    && fail "oidc-token: background token was written to GITHUB_ENV"
# The child stays in the step's process group. Once that shell exits it stops
# minting. A detached refresher would keep writing tokens after this.
after_bg="$(cat "$COUNTER")"
sleep 2
[ "$(cat "$COUNTER")" = "$after_bg" ] \
    || fail "oidc-token: background refresh kept minting after the step exited"
if [ -e "$REFRESH_DIR/token" ] || [ -e "$REFRESH_DIR/refresh.pid" ] \
    || [ -e "${TMPDIR:-/tmp}/snowflake-oidc-refresh/token" ]; then
    fail "oidc-token: background refresh wrote the token to disk"
fi

# A token the job supplied is not replaced by the background loop.
supplied_before="$(cat "$COUNTER")"
supplied_out="$(
    BASH_ENV="$keepalive" \
    SNOWFLAKE_AUDIENCE="iso.example" \
    OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
    OIDC_TOKEN_SUPPLIED=true \
    OIDC_TOKEN_REFRESH_INTERVAL=1 \
    SNOWFLAKE_TOKEN="supplied-token" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    GITHUB_ENV="$GITHUB_ENV" \
    COUNTER="$COUNTER" \
    bash -c 'sleep 2; printf %s "$SNOWFLAKE_TOKEN"' | tail -n 1
)"
[ "$supplied_out" = "supplied-token" ] \
    || fail "oidc-token: background refresh replaced a supplied token (got ${supplied_out})"
[ "$(cat "$COUNTER")" = "$supplied_before" ] \
    || fail "oidc-token: background refresh minted for a supplied token"

# A token set on a later step, with no job-level supplied flag, is left unchanged.
step_before="$(cat "$COUNTER")"
step_out="$(
    env -u OIDC_TOKEN_SUPPLIED -u OIDC_TOKEN_ISSUED_AT -u OIDC_KEEPALIVE_LOADED \
        -u OIDC_REFRESH_FD -u OIDC_KEEPALIVE_ENTER \
    BASH_ENV="$keepalive" \
    SNOWFLAKE_AUDIENCE="iso.example" \
    OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
    SNOWFLAKE_TOKEN="user-step-token" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    GITHUB_ENV="$GITHUB_ENV" \
    COUNTER="$COUNTER" \
    bash -c 'printf %s "$SNOWFLAKE_TOKEN"'
)"
[ "$step_out" = "user-step-token" ] \
    || fail "oidc-token: a step-level token was replaced (got ${step_out})"
[ "$(cat "$COUNTER")" = "$step_before" ] \
    || fail "oidc-token: a step-level token was minted over"
echo "PASS: a token already set in the step is left unchanged"

# set -x must not print the token or the Actions request token before the mask.
x_before="$(cat "$COUNTER")"
x_out="$TEST_ROOT/xtrace.out"
x_err="$TEST_ROOT/xtrace.err"
env -u OIDC_TOKEN_SUPPLIED -u OIDC_TOKEN_ISSUED_AT -u OIDC_KEEPALIVE_LOADED \
    -u OIDC_REFRESH_FD -u SNOWFLAKE_TOKEN -u OIDC_KEEPALIVE_ENTER \
BASH_ENV="$keepalive" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
GITHUB_ENV="$GITHUB_ENV" \
COUNTER="$COUNTER" \
    bash -x -c 'set +x; printf %s "$SNOWFLAKE_TOKEN"' >"$x_out" 2>"$x_err"
x_n=$((x_before + 1))
grep -F "token-${x_n}" "$x_err" \
    && fail "oidc-token: xtrace printed the OIDC token"
grep -F "request-token" "$x_err" \
    && fail "oidc-token: xtrace printed the Actions request token"
grep -F "::add-mask::token-${x_n}" "$x_out" \
    || fail "oidc-token: mask was not written for the minted token"
echo "PASS: xtrace does not print the token before the mask"

# A command that redirects stdout must not capture ::add-mask::.
redir_before="$(cat "$COUNTER")"
redir_file="$TEST_ROOT/redir-cmd.out"
redir_stdout="$TEST_ROOT/redir-step.out"
env -u OIDC_TOKEN_SUPPLIED -u OIDC_TOKEN_ISSUED_AT -u OIDC_KEEPALIVE_LOADED \
    -u OIDC_REFRESH_FD -u SNOWFLAKE_TOKEN -u OIDC_KEEPALIVE_ENTER \
BASH_ENV="$keepalive" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
GITHUB_ENV="$GITHUB_ENV" \
COUNTER="$COUNTER" \
REDIR_FILE="$redir_file" \
    bash -c '{ printf %s "$SNOWFLAKE_TOKEN"; } > "$REDIR_FILE"' \
    >"$redir_stdout"
redir_n=$((redir_before + 1))
[ "$(cat "$redir_file")" = "token-${redir_n}" ] \
    || fail "oidc-token: redirected command did not print the token (got $(cat "$redir_file"))"
grep -F '::add-mask::' "$redir_file" \
    && fail "oidc-token: command redirect captured ::add-mask::"
grep -F "::add-mask::token-${redir_n}" "$redir_stdout" \
    || fail "oidc-token: mask did not reach the step stdout"
echo "PASS: ::add-mask:: stays on the step stdout"

# A down endpoint is reported once, and curl is given a timeout.
CURL_ARGS="$TEST_ROOT/curl-args.txt"
: > "$CURL_ARGS"
cat > "$TEST_ROOT/bin/curl" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_ARGS"
exit 1
EOF
chmod +x "$TEST_ROOT/bin/curl"
fail_err="$TEST_ROOT/oidc-fail.err"
fail_out="$TEST_ROOT/oidc-fail.out"
env -u OIDC_TOKEN_SUPPLIED -u OIDC_TOKEN_ISSUED_AT -u OIDC_KEEPALIVE_LOADED \
    -u OIDC_REFRESH_FD -u SNOWFLAKE_TOKEN -u OIDC_KEEPALIVE_ENTER \
BASH_ENV="$keepalive" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
OIDC_TOKEN_REFRESH_INTERVAL=1 \
OIDC_TOKEN_FIRST_WAIT=1 \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
GITHUB_ENV="$GITHUB_ENV" \
CURL_ARGS="$CURL_ARGS" \
    bash -c 'sleep 3; printf %s "leftover=${SNOWFLAKE_TOKEN}"' >"$fail_out" 2>"$fail_err"
fail_errors="$(grep -c '::error::' "$fail_err" || true)"
[ "$fail_errors" -eq 1 ] \
    || fail "oidc-token: a down endpoint was reported ${fail_errors} times"
grep -q 'leftover=' "$fail_out" \
    || fail "oidc-token: a failed refresh stopped the step"
grep -q -- '--max-time' "$CURL_ARGS" \
    || fail "oidc-token: curl was not given --max-time"
echo "PASS: a down OIDC endpoint warns once and curl has a timeout"

# A bash python and curl must not re-enter the keepalive.
REAL_PY="${REAL_PYTHON_DIR}/python3"
[ -x "$REAL_PY" ] || fail "oidc-token: real python3 missing"
PYCOUNT="$TEST_ROOT/pycount"
CURLCOUNT="$TEST_ROOT/curlcount"
HELPER_LOG="$TEST_ROOT/helper-bash-env.log"
printf '0' > "$PYCOUNT"
printf '0' > "$CURLCOUNT"
: > "$HELPER_LOG"
cat > "$TEST_ROOT/bin/python3" << EOF
#!/usr/bin/env bash
n=\$(cat "$PYCOUNT")
n=\$((n + 1))
printf '%s' "\$n" > "$PYCOUNT"
if [ -n "\${BASH_ENV:-}" ]; then
  printf '%s\n' "python saw BASH_ENV" >> "$HELPER_LOG"
fi
if [ "\$n" -gt 40 ]; then
  echo "python reentered \$n times" >&2
  exit 99
fi
exec "$REAL_PY" "\$@"
EOF
chmod +x "$TEST_ROOT/bin/python3"
cat > "$TEST_ROOT/bin/curl" << EOF
#!/usr/bin/env bash
n=\$(cat "$CURLCOUNT")
n=\$((n + 1))
printf '%s' "\$n" > "$CURLCOUNT"
if [ -n "\${BASH_ENV:-}" ]; then
  printf '%s\n' "curl saw BASH_ENV" >> "$HELPER_LOG"
fi
if [ "\$n" -gt 10 ]; then
  echo "curl reentered \$n times" >&2
  exit 99
fi
printf '%s' '{"value":"token-shim"}'
EOF
chmod +x "$TEST_ROOT/bin/curl"
shim_out="$TEST_ROOT/shim.out"
shim_err="$TEST_ROOT/shim.err"
set +e
env -u OIDC_TOKEN_SUPPLIED -u OIDC_TOKEN_ISSUED_AT -u OIDC_KEEPALIVE_LOADED \
    -u OIDC_REFRESH_FD -u SNOWFLAKE_TOKEN -u OIDC_KEEPALIVE_ENTER \
BASH_ENV="$keepalive" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
GITHUB_ENV="$GITHUB_ENV" \
PYCOUNT="$PYCOUNT" \
CURLCOUNT="$CURLCOUNT" \
HELPER_LOG="$HELPER_LOG" \
    timeout 5 bash -c 'printf %s "$SNOWFLAKE_TOKEN"' >"$shim_out" 2>"$shim_err"
shim_rc=$?
set -e
[ "$shim_rc" -eq 0 ] || fail "oidc-token: bash python/curl re-entered (rc ${shim_rc})"
grep -q 'token-shim' "$shim_out" \
    || fail "oidc-token: bash shim mint did not export the token (got $(cat "$shim_out"))"
[ ! -s "$HELPER_LOG" ] || fail "oidc-token: mint helper inherited BASH_ENV ($(cat "$HELPER_LOG"))"
[ "$(cat "$PYCOUNT")" -le 40 ] || fail "oidc-token: python re-entered"
[ "$(cat "$CURLCOUNT")" -le 10 ] || fail "oidc-token: curl re-entered"
echo "PASS: bash python and curl do not re-enter the keepalive"

# A second install must not point the BASH_ENV wrapper at itself.
double_root="$TEST_ROOT/double-install"
mkdir -p "$double_root"
double_env="$double_root/github.env"
: > "$double_env"
user_env="$double_root/user-bash-env.sh"
cat > "$user_env" << 'EOF'
printf '%s\n' user-sourced
python3 -c 'print(1)'
EOF
wrapper="$double_root/snowflake-oidc-refresh/bash-env.sh"
(
    unset OIDC_KEEPALIVE_LOADED OIDC_KEEPALIVE_ENTER OIDC_REFRESH_FD || true
    export RUNNER_TEMP="$double_root"
    export GITHUB_ENV="$double_env"
    export BASH_ENV="$user_env"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/oidc-token-env.sh"
    oidc_install_keepalive
    oidc_install_keepalive
)
[ -f "$wrapper" ] || fail "oidc-token: keepalive wrapper was not written"
grep -q -F "$user_env" "$wrapper" \
    || fail "oidc-token: wrapper dropped the original BASH_ENV"
grep -q -F "$wrapper" "$wrapper" \
    && fail "oidc-token: wrapper sources itself"
double_out="$double_root/step.out"
double_err="$double_root/step.err"
set +e
env -u OIDC_TOKEN_SUPPLIED -u OIDC_TOKEN_ISSUED_AT -u OIDC_KEEPALIVE_LOADED \
    -u OIDC_REFRESH_FD -u SNOWFLAKE_TOKEN -u OIDC_KEEPALIVE_ENTER \
BASH_ENV="$wrapper" \
SNOWFLAKE_AUDIENCE="iso.example" \
OIDC_TOKEN_NAME="SNOWFLAKE_TOKEN" \
ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token" \
ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
GITHUB_ENV="$double_env" \
PYCOUNT="$PYCOUNT" \
CURLCOUNT="$CURLCOUNT" \
HELPER_LOG="$HELPER_LOG" \
    timeout 5 bash -c 'printf ok' >"$double_out" 2>"$double_err"
double_rc=$?
set -e
[ "$double_rc" -eq 0 ] || fail "oidc-token: second keepalive install hung (rc ${double_rc})"
grep -q 'user-sourced' "$double_out" \
    || fail "oidc-token: wrapper did not source the original BASH_ENV"
echo "PASS: a second keepalive install does not wrap itself"
echo "PASS: oidc-token refreshes the variable in the background and does not write a file"
unset SNOWFLAKE_TOKEN SNOWFLAKE_TOKEN_FILE_PATH GITHUB_ENV COUNTER \
    ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN BASH_ENV \
    OIDC_TOKEN_ISSUED_AT || true

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
GITHUB_OUTPUT="$TEST_ROOT/cortex-local.out" \
CORTEX_BINARY="$TEST_ROOT/cortex-bin" \
    bash "$REPO_ROOT/cortex-code/scripts/install-cortex.sh" \
    || fail "cortex: local binary should succeed"
[ -x "$HOME/.local/bin/cortex" ] || fail "cortex: local binary was not installed"
grep -qx 'install_mode=local' "$TEST_ROOT/cortex-local.out" \
    || fail "cortex: local binary did not record install_mode=local"
echo "PASS: cortex-binary does not download a release archive"

# Preinstalled cortex is reused.
rm -f "$HOME/.local/bin/cortex"
printf '#!/bin/sh\necho cortex-preinstalled\n' > "$TEST_ROOT/bin/cortex"
chmod +x "$TEST_ROOT/bin/cortex"
GITHUB_PATH="$TEST_ROOT/github.path" \
GITHUB_OUTPUT="$TEST_ROOT/cortex-preinstalled.out" \
    bash "$REPO_ROOT/cortex-code/scripts/install-cortex.sh" \
    || fail "cortex: preinstalled binary should succeed"
grep -qx 'install_mode=preinstalled' "$TEST_ROOT/cortex-preinstalled.out" \
    || fail "cortex: preinstalled binary did not record install_mode=preinstalled"
echo "PASS: cortex already on PATH skips the release-archive download"

# Pinning must fail before cortex update for a preinstalled binary and for a
# local binary. A fresh download is the only mode that may call update.
cat > "$TEST_ROOT/bin/cortex" << 'EOF'
#!/bin/sh
echo "cortex should not have been called: $*" >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/cortex"
set +e
CORTEX_INSTALL_MODE=preinstalled CORTEX_VERSION=1.5.2 \
    bash "$REPO_ROOT/cortex-code/scripts/pin-cortex-version.sh" >"$TEST_ROOT/pin-preinstalled.out" 2>&1
pin_pre_rc=$?
set -e
[ "$pin_pre_rc" -ne 0 ] || fail "pin: preinstalled cortex plus a version should fail"
grep -q 'cortex should not have been called' "$TEST_ROOT/pin-preinstalled.out" \
    && fail "pin: preinstalled path called cortex update"
echo "PASS: pinning a preinstalled cortex fails before cortex update"

set +e
CORTEX_BINARY="$TEST_ROOT/cortex-bin" CORTEX_INSTALL_MODE=local CORTEX_VERSION=1.5.2 \
    bash "$REPO_ROOT/cortex-code/scripts/pin-cortex-version.sh" >"$TEST_ROOT/pin-local.out" 2>&1
pin_local_rc=$?
set -e
[ "$pin_local_rc" -ne 0 ] || fail "pin: cortex-binary plus a version should fail"
grep -q 'cannot be combined' "$TEST_ROOT/pin-local.out" \
    || fail "pin: local binary error did not reject the combination"
grep -q 'cortex should not have been called' "$TEST_ROOT/pin-local.out" \
    && fail "pin: local binary path called cortex update"
echo "PASS: cortex-binary cannot be combined with a pinned version"

cat > "$HOME/.local/bin/cortex" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$CORTEX_LOG"
EOF
chmod +x "$HOME/.local/bin/cortex"
# No release archive for this version, so the pin falls back to cortex update.
cat > "$TEST_ROOT/bin/curl" << 'EOF'
#!/bin/sh
printf '404'
exit 0
EOF
chmod +x "$TEST_ROOT/bin/curl"
CORTEX_LOG="$TEST_ROOT/cortex-update.log"
: > "$CORTEX_LOG"
CORTEX_INSTALL_MODE=downloaded CORTEX_VERSION=1.5.2 CORTEX_LOG="$CORTEX_LOG" \
    bash "$REPO_ROOT/cortex-code/scripts/pin-cortex-version.sh" \
    || fail "pin: downloaded cortex should accept a version"
grep -qx 'update 1.5.2' "$CORTEX_LOG" \
    || fail "pin: downloaded path did not run cortex update"
echo "PASS: a fresh Cortex download can still be pinned"
