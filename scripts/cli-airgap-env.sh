#!/usr/bin/env bash

# Publish Snowflake CLI air-gap mode for later steps in the job.
#
# An offline setup (a local cli-artifact, or a snow binary this job did not
# install from the network) exports SNOWFLAKE_CLI_AIR_GAPPED=true. Later snow
# commands then skip public-internet behavior: auto-upgrade, the commercial
# OIDC audience default, and public template downloads. Callers do not have
# to set that variable themselves.
#
# An explicit SNOWFLAKE_CLI_AIR_GAPPED is left alone, including false.
# A CLI installed from PyPI or GitHub earlier in this job is recorded as
# SF_CICD_CLI_SOURCE=network. A later step that only reuses that binary must
# not flip the CLI into air-gapped mode.

publish_air_gapped_cli_env() {
    if [ -z "${GITHUB_ENV:-}" ]; then
        return 0
    fi
    if [ -n "${SNOWFLAKE_CLI_AIR_GAPPED:-}" ]; then
        echo "SNOWFLAKE_CLI_AIR_GAPPED is already set; leaving it unchanged."
        return 0
    fi
    if [ "${SF_CICD_CLI_SOURCE:-}" = "network" ]; then
        echo "Snowflake CLI was installed from the network earlier in this job; not setting SNOWFLAKE_CLI_AIR_GAPPED."
        return 0
    fi
    echo "SNOWFLAKE_CLI_AIR_GAPPED=true" >> "$GITHUB_ENV"
    echo "Exported SNOWFLAKE_CLI_AIR_GAPPED=true so later snow commands run air-gapped."
}

publish_network_cli_source() {
    if [ -z "${GITHUB_ENV:-}" ]; then
        return 0
    fi
    echo "SF_CICD_CLI_SOURCE=network" >> "$GITHUB_ENV"
}
