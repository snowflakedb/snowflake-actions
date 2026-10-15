#!/usr/bin/env bash

# Resolve the OIDC audience for this step into $AUDIENCE.
#
# An explicit oidc-audience input (OIDC_AUDIENCE) wins. Otherwise a
# SNOWFLAKE_AUDIENCE already in the environment is kept, so a job can set it
# once. When neither is set, the commercial audience is used unless
# SNOWFLAKE_CLI_AIR_GAPPED is true. Air-gapped mode matches the CLI: true or 1
# refuses to invent snowflakecomputing.com. false, 0, and empty do not.

resolve_oidc_audience() {
    local input="${OIDC_AUDIENCE:-}"
    local from_env="${SNOWFLAKE_AUDIENCE:-}"
    local air
    air="$(printf '%s' "${SNOWFLAKE_CLI_AIR_GAPPED:-}" | tr '[:upper:]' '[:lower:]')"

    if [ -n "$input" ]; then
        AUDIENCE="$input"
    elif [ -n "$from_env" ]; then
        AUDIENCE="$from_env"
    else
        case "$air" in
            "" | false | 0)
                AUDIENCE="snowflakecomputing.com"
                ;;
            true | 1)
                echo "::error::SNOWFLAKE_AUDIENCE is not set. Set oidc-audience or SNOWFLAKE_AUDIENCE to the audience for this deployment."
                exit 1
                ;;
            *)
                echo "::error::SNOWFLAKE_CLI_AIR_GAPPED must be true, false, 1, or 0."
                exit 1
                ;;
        esac
    fi

    # GITHUB_ENV is split on CR and LF. A carriage return would turn the rest of
    # the line into another assignment.
    case "$AUDIENCE" in
        *$'\n'* | *$'\r'*)
            echo "::error::oidc-audience must be a single line"
            exit 1
            ;;
    esac
}
