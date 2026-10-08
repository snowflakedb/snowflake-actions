#!/usr/bin/env bash

# Print the installed Snowflake CLI version and expose it as a step output.
#
# Shared by the root action and the snowflake-cli leaf action so the version-string
# parsing and install-location assumption live in one place.

set -euo pipefail

export PATH="${HOME}/.local/bin:$PATH"
VERSION=$(SNOWFLAKE_CLI_IGNORE_NEW_VERSION_WARNING=true snow --version 2>&1 | head -1)
echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
echo "Snowflake CLI: ${VERSION}"
