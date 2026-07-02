#!/usr/bin/env bash

# Mint a GitHub Actions OIDC token for Snowflake workload-identity auth WITHOUT
# requiring the Snowflake CLI.
#
# This is the single token-minting path for the whole repo: the Cortex Code
# action calls it directly, and the snow-install path calls it via
# configure-snowflake-oidc.sh. It replaces `snow auth oidc read-token
# --type=github` — both request the GitHub-issued JWT for audience
# "snowflakecomputing.com" from the Actions OIDC endpoint — so minting, masking,
# and idempotency live in exactly one place and neither path needs `snow`.
#
# Idempotent: if a prior step (e.g. the snow-install OIDC path) already exported
# the token, it is reused rather than re-minted.
#
# Requires `permissions: id-token: write` on the job.
#
# Env:
#   OIDC_TOKEN_NAME    Name of the env var to export the token as
#                      (default SNOWFLAKE_TOKEN).
#   SNOWFLAKE_AUDIENCE Audience claim to request (default snowflakecomputing.com).

set -euo pipefail

TOKEN_NAME_UPPER=$(echo "${OIDC_TOKEN_NAME:-SNOWFLAKE_TOKEN}" | tr '[:lower:]' '[:upper:]')
AUDIENCE="${SNOWFLAKE_AUDIENCE:-snowflakecomputing.com}"

# Reuse a token a parent step already minted (avoids a redundant request when
# the snow-install path and the Cortex Code path both run with use-oidc).
if [ -n "${!TOKEN_NAME_UPPER:-}" ]; then
    echo "OIDC token already present in \$${TOKEN_NAME_UPPER}; reusing it."
    exit 0
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "::error::use-oidc is set but the GitHub OIDC endpoint is unavailable. Add 'permissions: id-token: write' to the job."
    exit 1
fi

response=$(curl -sS --fail \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}")

# Parse the JSON {"value": "<jwt>"} with the stdlib. Prefer python3, falling
# back to python (Windows runners expose the interpreter as `python`).
PYTHON="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON" ]; then
    echo "::error::No python interpreter (python3 or python) found to parse the OIDC token."
    exit 1
fi
token=$(echo "$response" | "$PYTHON" -c 'import sys, json; print(json.load(sys.stdin)["value"])')

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
} >> "$GITHUB_ENV"
echo "Minted GitHub OIDC token into \$${TOKEN_NAME_UPPER} (audience: ${AUDIENCE})."
