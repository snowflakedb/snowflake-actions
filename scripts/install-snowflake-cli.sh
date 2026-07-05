#!/usr/bin/env bash

# Install the Snowflake CLI into an isolated `uv` tool environment.
#
# Python is pinned per-install via `uv tool install --python 3.11` rather than
# UV_PYTHON, so the consumer's job environment is never touched (a leaked
# UV_PYTHON would break later `uv` steps that require a different interpreter).
#
# Requires `uv` to already be on PATH (the action runs astral-sh/setup-uv first).
#
# Env:
#   CLI_VERSION         Snowflake CLI version (e.g. "3.20.0"), "latest", or empty.
#   CUSTOM_GITHUB_REF   Branch/tag/commit to install from source instead of PyPI.

set -euo pipefail

CLI_VERSION="${CLI_VERSION:-}"
CUSTOM_GITHUB_REF="${CUSTOM_GITHUB_REF:-}"

if [ -n "$CLI_VERSION" ] && [ -n "$CUSTOM_GITHUB_REF" ]; then
    echo "::error::You cannot set BOTH cli-version and custom-github-ref"
    exit 1
fi

if [ -n "$CUSTOM_GITHUB_REF" ]; then
    echo "Installing Snowflake CLI from snowflakedb/snowflake-cli@${CUSTOM_GITHUB_REF}"
    uv tool install --python 3.11 "git+https://github.com/snowflakedb/snowflake-cli.git@${CUSTOM_GITHUB_REF}"
elif [ -n "$CLI_VERSION" ] && [ "$CLI_VERSION" != "latest" ]; then
    echo "Installing Snowflake CLI ${CLI_VERSION}"
    uv tool install --python 3.11 "snowflake-cli==${CLI_VERSION}"
else
    echo "Installing latest Snowflake CLI release"
    uv tool install --python 3.11 snowflake-cli
fi
