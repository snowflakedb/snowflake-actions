#!/usr/bin/env bash

# Configure Snowflake CLI workload-identity (OIDC) authentication.
#
# Sets the environment variables the CLI's connector reads, and mints the
# GitHub-issued OIDC token via the Snowflake CLI itself. Only used on the
# snow-install path, where the `snow` binary is guaranteed to be present.
#
# (The Cortex Code path mints its token without the CLI — see oidc-token.sh.)
#
# Env:
#   OIDC_TOKEN_NAME   Name of the env var to export the token as
#                     (default SNOWFLAKE_TOKEN).

set -euo pipefail

TOKEN_NAME_UPPER=$(echo "${OIDC_TOKEN_NAME:-SNOWFLAKE_TOKEN}" | tr '[:lower:]' '[:upper:]')

{
    echo "SNOWFLAKE_AUTHENTICATOR=WORKLOAD_IDENTITY"
    echo "SNOWFLAKE_WORKLOAD_IDENTITY_PROVIDER=OIDC"
    echo "SNOWFLAKE_AUDIENCE=snowflakecomputing.com"
    # Tell the CLI which auth type this action configured.
    echo "SF_CICD_AUTH_TYPE=oidc"
    echo "${TOKEN_NAME_UPPER}=$(snow auth oidc read-token --type=github)"
} >> "$GITHUB_ENV"
