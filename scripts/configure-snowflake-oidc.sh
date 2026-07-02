#!/usr/bin/env bash

# Configure Snowflake CLI workload-identity (OIDC) authentication.
#
# Delegates token minting, masking, and idempotency to oidc-token.sh (the single
# minting path, shared with the snow-free Cortex Code path), then sets the extra
# environment variables the Snowflake CLI's connector reads for a temporary
# workload-identity connection.
#
# Env:
#   OIDC_TOKEN_NAME   Name of the env var to export the token as
#                     (default SNOWFLAKE_TOKEN).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mint (or reuse) and mask the GitHub OIDC token, exporting it under
# OIDC_TOKEN_NAME and recording SF_CICD_AUTH_TYPE.
bash "${SCRIPT_DIR}/oidc-token.sh"

{
    echo "SNOWFLAKE_AUTHENTICATOR=WORKLOAD_IDENTITY"
    echo "SNOWFLAKE_WORKLOAD_IDENTITY_PROVIDER=OIDC"
    echo "SNOWFLAKE_AUDIENCE=snowflakecomputing.com"
} >> "$GITHUB_ENV"
