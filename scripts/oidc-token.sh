#!/usr/bin/env bash

# Mint a GitHub Actions OIDC token for Snowflake workload-identity auth WITHOUT
# requiring the Snowflake CLI.
#
# This is the single token-minting path for the whole repo: the Cortex Code
# action calls it directly, and the snow-install path calls it via
# configure-snowflake-oidc.sh. It replaces `snow auth oidc read-token
# --type=github` — both request the GitHub-issued JWT for the resolved audience
# from the Actions OIDC endpoint — so minting, masking, and idempotency live in
# exactly one place and neither path needs `snow`. An omitted audience is
# snowflakecomputing.com unless SNOWFLAKE_CLI_AIR_GAPPED is true.
#
# Idempotent: if a prior step (e.g. the snow-install OIDC path) already exported
# the token, it is reused rather than re-minted. Reuse writes SNOWFLAKE_AUDIENCE
# before returning, and only when that token's aud matches the audience requested
# on this step.
#
# Requires `permissions: id-token: write` on the job.
#
# Env:
#   OIDC_TOKEN_NAME           Name of the env var to export the token as
#                             (default SNOWFLAKE_TOKEN).
#   OIDC_AUDIENCE             Explicit oidc-audience input. Empty means omitted.
#   SNOWFLAKE_AUDIENCE        Audience already set on the job. Used when
#                             OIDC_AUDIENCE is empty.
#   SNOWFLAKE_CLI_AIR_GAPPED  When true and neither audience is set, refuse to
#                             default to snowflakecomputing.com.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oidc-audience.sh
source "${SCRIPT_DIR}/oidc-audience.sh"
resolve_oidc_audience

TOKEN_NAME_UPPER=$(echo "${OIDC_TOKEN_NAME:-SNOWFLAKE_TOKEN}" | tr '[:lower:]' '[:upper:]')

# Parse JSON and encode the audience with the stdlib. Prefer python3, falling
# back to python (Windows runners expose the interpreter as `python`).
PYTHON="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON" ]; then
    echo "::error::No python interpreter (python3 or python) found to parse the OIDC token."
    exit 1
fi

# Reuse a token that's already in the env rather than minting again. This covers
# the intended case (the snow-install and Cortex Code paths both run with
# use-oidc, so one mints and the other reuses). The Cortex steps call this
# script directly, so the audience has to be published here, before the return.
# Reuse keeps the existing token, so that token has to have been minted for
# this same audience.
if [ -n "${!TOKEN_NAME_UPPER:-}" ]; then
    echo "::add-mask::${!TOKEN_NAME_UPPER}"
    aud_status="$("$PYTHON" -c '
import base64, json, sys
token, expected = sys.argv[1], sys.argv[2]
parts = token.split(".")
if len(parts) < 2:
    print("not-jwt")
    raise SystemExit(0)
payload = parts[1]
payload += "=" * (-len(payload) % 4)
try:
    data = json.loads(base64.urlsafe_b64decode(payload))
except Exception:
    print("not-jwt")
    raise SystemExit(0)
aud = data.get("aud")
if isinstance(aud, list):
    match = expected in aud
else:
    match = aud == expected
print("match" if match else "mismatch")
' "${!TOKEN_NAME_UPPER}" "$AUDIENCE")"
    case "$aud_status" in
        match) ;;
        mismatch)
            echo "::error::Existing ${TOKEN_NAME_UPPER} was minted for a different audience than oidc-audience. Refusing to reuse it."
            exit 1
            ;;
        *)
            echo "::error::Existing ${TOKEN_NAME_UPPER} is not a JWT, so its audience cannot be checked. Refusing to reuse it."
            exit 1
            ;;
    esac
    echo "SNOWFLAKE_AUDIENCE=${AUDIENCE}" >> "$GITHUB_ENV"
    echo "OIDC token already present in \$${TOKEN_NAME_UPPER}; reusing it."
    exit 0
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "::error::use-oidc is set but the GitHub OIDC endpoint is unavailable. Add 'permissions: id-token: write' to the job."
    exit 1
fi
# GitHub takes the audience as a query parameter. Encode it so an in-zone
# value that contains reserved characters cannot break the request URL.
encoded_audience="$("$PYTHON" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$AUDIENCE")"

response=$(curl -sS --fail \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded_audience}") || {
    echo "::error::Could not reach the GitHub OIDC endpoint to mint a token. Confirm the job has 'permissions: id-token: write' and that GitHub Actions OIDC is reachable."
    exit 1
}

token=$(printf '%s' "$response" | "$PYTHON" -c 'import sys, json; print(json.load(sys.stdin)["value"])')

if [ -z "$token" ]; then
    echo "::error::Failed to obtain an OIDC token from GitHub."
    exit 1
fi

echo "::add-mask::${token}"
{
    echo "${TOKEN_NAME_UPPER}=${token}"
    # Record the auth type this action configured (telemetry). Set here on the
    # shared minting path so both the snow and Cortex Code paths report it.
    echo "SF_CICD_AUTH_TYPE=oidc"
    # Keep the connector/CLI audience env aligned with the aud we just requested.
    echo "SNOWFLAKE_AUDIENCE=${AUDIENCE}"
} >> "$GITHUB_ENV"
echo "Minted GitHub OIDC token into \$${TOKEN_NAME_UPPER} (audience: ${AUDIENCE})."
