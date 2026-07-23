#!/usr/bin/env bash

# Validate the Cortex Code CLI channel and version inputs.
#
# Shared by the root action (cortex-channel / cortex-version inputs) and the
# cortex-code leaf action (cli-channel / cli-version inputs). Each caller passes
# the values plus the input names to surface in errors, so the message names the
# input the consumer actually set.
#
# Env:
#   CHANNEL             Channel value to validate (stable|beta). The exec
#                       subcommand is GA on stable from v1.1.41.
#   VERSION             Version value to validate (latest, or a version like
#                       1.5.2 or 0.26.106+015728.dcf1621f with build metadata).
#   CHANNEL_INPUT_NAME  Input name for error messages (default "cli-channel").
#   VERSION_INPUT_NAME  Input name for error messages (default "cli-version").

set -euo pipefail

CHANNEL_INPUT_NAME="${CHANNEL_INPUT_NAME:-cli-channel}"
VERSION_INPUT_NAME="${VERSION_INPUT_NAME:-cli-version}"

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "beta" ]]; then
    echo "::error::${CHANNEL_INPUT_NAME} must be 'stable' or 'beta', got '${CHANNEL}'"
    exit 1
fi

# Accept a plain X.Y.Z semver or one carrying build metadata (cortex publishes
# versions like 0.26.106+015728.dcf1621f).
if [[ "$VERSION" != "latest" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "::error::${VERSION_INPUT_NAME} must be 'latest' or a version (e.g. 1.5.2 or 0.26.106+015728.dcf1621f), got '${VERSION}'"
    exit 1
fi
