#!/usr/bin/env bash

# Set the environment variables every Snowflake action exports at startup:
# the CI/CD integration version and the "invoked via a Snowflake GitHub action"
# marker.
#
# The integration version is read from the repo-root VERSION file (located
# relative to this script), so it is defined in exactly one place instead of
# being hardcoded in each action manifest. Any action — root or leaf, at any
# directory depth — calls this the same way; the script self-locates VERSION.
#
# Usage:
#   bash <path>/scripts/setup-environment.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/../VERSION")"

{
    echo "SF_GITHUB_ACTION=true"
    echo "SF_CICD_INTEGRATION_VERSION=${VERSION}"
} >> "$GITHUB_ENV"
