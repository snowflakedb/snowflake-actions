#!/usr/bin/env bash

# Decide whether this job must download uv or the Snowflake CLI.
#
# Writes skip_uv_setup and skip_install to $GITHUB_OUTPUT.
#
# skip_install   snow is already on PATH and the caller did not set
#                cli-version, custom-github-ref, or cli-artifact.
# skip_uv_setup  do not run astral-sh/setup-uv (that action downloads uv
#                from GitHub Releases). Set when the install is skipped, and
#                when cli-artifact is set: an offline wheel install must not
#                fetch uv either. uv and python3 have to already be on PATH.

set -euo pipefail

CLI_VERSION="${CLI_VERSION:-}"
CUSTOM_GITHUB_REF="${CUSTOM_GITHUB_REF:-}"
CLI_ARTIFACT="${CLI_ARTIFACT:-}"

if [ -n "$CLI_VERSION" ] && [ -n "$CUSTOM_GITHUB_REF" ]; then
    echo "::error::You cannot set BOTH cli-version and custom-github-ref"
    exit 1
fi
if [ -n "$CLI_ARTIFACT" ] && { [ -n "$CLI_VERSION" ] || [ -n "$CUSTOM_GITHUB_REF" ]; }; then
    echo "::error::cli-artifact cannot be combined with cli-version or custom-github-ref"
    exit 1
fi

export PATH="${HOME}/.local/bin:${PATH}"

skip_install=false
skip_uv_setup=false

if [ -n "$CLI_ARTIFACT" ]; then
    # Local wheel/sdist. Never download uv; install-snowflake-cli.sh fails
    # loudly if uv or python3 is missing.
    skip_uv_setup=true
elif [ -z "$CLI_VERSION" ] && [ -z "$CUSTOM_GITHUB_REF" ] && command -v snow >/dev/null 2>&1; then
    skip_install=true
    skip_uv_setup=true
    echo "snow already on PATH ($(command -v snow)); skipping uv and Snowflake CLI downloads."
    # The install step is skipped, so publish snow's directory for later steps.
    # The plan step's PATH export does not survive the step boundary.
    if [ -n "${GITHUB_PATH:-}" ]; then
        dirname "$(command -v snow)" >> "$GITHUB_PATH"
    fi
fi

{
    echo "skip_install=${skip_install}"
    echo "skip_uv_setup=${skip_uv_setup}"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
