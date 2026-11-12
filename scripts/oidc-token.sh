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
# Idempotent: if a prior step already exported a token, it is left in place
# rather than re-minted. Reuse writes SNOWFLAKE_AUDIENCE before returning, and
# only when that token's aud matches the audience requested on this step.
#
# A token this script mints is not stored. GitHub expires it after 5 minutes,
# and Snowflake CLI 3.33 keeps a token or token_file_path that is already set
# instead of minting. The setup step mints once to prove the OIDC endpoint is
# reachable, masks that value, and drops it. Each later snow command mints its
# own token in that process.
#
# Requires `permissions: id-token: write` on the job.
#
# Env:
#   OIDC_TOKEN_NAME           Env var to treat as a caller-supplied token
#                             (default SNOWFLAKE_TOKEN). When it is already
#                             set, it is left unchanged. This script does not
#                             write it.
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

oidc_mint_github_token() {
    local audience="$1" encoded response token
    if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
        echo "::error::use-oidc is set but the GitHub OIDC endpoint is unavailable. Add 'permissions: id-token: write' to the job." >&2
        return 1
    fi
    encoded="$("$PYTHON" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$audience")"
    response=$(curl -sS --fail \
        -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded}") || {
        echo "::error::Could not reach the GitHub OIDC endpoint to mint a token. Confirm the job has 'permissions: id-token: write' and that GitHub Actions OIDC is reachable." >&2
        return 1
    }
    token=$(printf '%s' "$response" | "$PYTHON" -c 'import sys, json; print(json.load(sys.stdin)["value"])') || {
        echo "::error::Failed to obtain an OIDC token from GitHub." >&2
        return 1
    }
    if [ -z "$token" ]; then
        echo "::error::Failed to obtain an OIDC token from GitHub." >&2
        return 1
    fi
    printf '%s' "$token"
}

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

# Prove the job can mint, then drop the token. Do not append it to GITHUB_ENV
# and do not write it to a file. CLI 3.33 will not mint its own token when
# either of those is set.
token="$(oidc_mint_github_token "$AUDIENCE")" || exit 1
case "$token" in
    *$'\n'*|*$'\r'*)
        echo "::error::OIDC token must be a single line." >&2
        exit 1
        ;;
esac
echo "::add-mask::${token}"
unset token
{
    echo "SF_CICD_AUTH_TYPE=oidc"
    printf 'SNOWFLAKE_AUDIENCE=%s\n' "$AUDIENCE"
} >> "$GITHUB_ENV"
echo "Checked GitHub OIDC (audience: ${AUDIENCE}). Each snow command mints its own token."
