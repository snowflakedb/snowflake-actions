#!/usr/bin/env bash

# Validate the Cortex Code CLI channel and version inputs.
#
# Shared by the root action (cortex-channel / cortex-version inputs) and the
# cortex-code leaf action (cli-channel / cli-version inputs). Each caller passes
# the values plus the input names to surface in errors, so the message names the
# input the consumer actually set.
#
# Env:
#   CHANNEL             Channel value to validate (stable|beta).
#   VERSION             Version value to validate (latest|semver).
#   CHANNEL_INPUT_NAME  Input name for error messages (default "cli-channel").
#   VERSION_INPUT_NAME  Input name for error messages (default "cli-version").

set -euo pipefail

CHANNEL_INPUT_NAME="${CHANNEL_INPUT_NAME:-cli-channel}"
VERSION_INPUT_NAME="${VERSION_INPUT_NAME:-cli-version}"

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "beta" ]]; then
    echo "::error::${CHANNEL_INPUT_NAME} must be 'stable' or 'beta', got '${CHANNEL}'"
    exit 1
fi

if [[ "$VERSION" != "latest" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error::${VERSION_INPUT_NAME} must be 'latest' or a semver (e.g. 1.5.2), got '${VERSION}'"
    exit 1
fi
