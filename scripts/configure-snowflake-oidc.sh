#!/usr/bin/env bash

# Configure Snowflake CLI workload-identity (OIDC) authentication.
#
# Delegates token minting, masking, and idempotency to oidc-token.sh (the single
# minting path, shared with the snow-free Cortex Code path), then sets the extra
# environment variables the Snowflake CLI's connector reads for a temporary
# workload-identity connection.
#
# Env:
#   OIDC_TOKEN_NAME           Env var later bash steps export the token into
#                             (default SNOWFLAKE_TOKEN). A value already set
#                             is left unchanged.
#   OIDC_AUDIENCE             Explicit oidc-audience input. Empty means omitted.
#   SNOWFLAKE_AUDIENCE        Audience already set on the job. Used when
#                             OIDC_AUDIENCE is empty. Exported before minting
#                             so the JWT aud and the env var match.
#   SNOWFLAKE_CLI_AIR_GAPPED  When true and neither audience is set, refuse to
#                             default to snowflakecomputing.com.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oidc-audience.sh
source "${SCRIPT_DIR}/oidc-audience.sh"
resolve_oidc_audience
export SNOWFLAKE_AUDIENCE="$AUDIENCE"

# Prove the GitHub OIDC endpoint is reachable. The minted token is masked and
# dropped. Later bash steps export a token and replace it every 4 minutes.
# A token the job already put in OIDC_TOKEN_NAME is left unchanged.
bash "${SCRIPT_DIR}/oidc-token.sh"

{
    echo "SNOWFLAKE_AUTHENTICATOR=WORKLOAD_IDENTITY"
    echo "SNOWFLAKE_WORKLOAD_IDENTITY_PROVIDER=OIDC"
    echo "SNOWFLAKE_AUDIENCE=${AUDIENCE}"
} >> "$GITHUB_ENV"
