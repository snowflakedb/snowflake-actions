#!/usr/bin/env bash

# Configure Snowflake CLI workload-identity (OIDC) authentication.
#
# Does not export a token. Snowflake CLI 3.33 reuses a token that is already
# set, and a GitHub OIDC token expires after about 5 minutes, so a token
# written here fails a later snow command in a long job. Each snow command
# mints its own token when token and token_file_path are both empty.
#
# Cortex Code does not mint. That path still calls oidc-token.sh.
#
# Env:
#   OIDC_AUDIENCE             Explicit oidc-audience input. Empty means omitted.
#   SNOWFLAKE_AUDIENCE        Audience already set on the job. Used when
#                             OIDC_AUDIENCE is empty. Exported so the JWT aud
#                             the CLI requests matches this value.
#   SNOWFLAKE_CLI_AIR_GAPPED  When true and neither audience is set, refuse to
#                             default to snowflakecomputing.com.
#   SNOWFLAKE_TOKEN           When the job already set this, it is left as-is
#                             and the OIDC endpoint is not required. The CLI
#                             reuses that token.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oidc-audience.sh
source "${SCRIPT_DIR}/oidc-audience.sh"
resolve_oidc_audience

# The CLI mints from the Actions OIDC endpoint on each command. Fail in this
# step when that endpoint is missing and the job did not supply a token.
if [ -z "${SNOWFLAKE_TOKEN:-}" ]; then
    if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
        echo "::error::use-oidc is set but the GitHub OIDC endpoint is unavailable. Add 'permissions: id-token: write' to the job."
        exit 1
    fi
fi

{
    echo "SNOWFLAKE_AUTHENTICATOR=WORKLOAD_IDENTITY"
    echo "SNOWFLAKE_WORKLOAD_IDENTITY_PROVIDER=OIDC"
    echo "SNOWFLAKE_AUDIENCE=${AUDIENCE}"
    echo "SF_CICD_AUTH_TYPE=oidc"
} >> "$GITHUB_ENV"

echo "Snowflake CLI will mint a GitHub OIDC token on each command (audience: ${AUDIENCE})."
