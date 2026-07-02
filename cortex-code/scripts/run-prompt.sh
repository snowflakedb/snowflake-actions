#!/usr/bin/env bash

# Run a Cortex Code prompt non-interactively in CI.
#
# The prompt value is either an inline prompt string or a path to a file
# holding the prompt. It is treated as a file when a regular file exists at
# that path, and as a literal inline prompt otherwise.
#
# Env:
#   CORTEX_PROMPT       Inline prompt text, or a path to a prompt file (required).
#   CONNECTION_NAME     Connection to run against (default "default").
#   CORTEX_PROMPT_ARGS  Extra arguments appended verbatim to `cortex exec`
#                       (e.g. "--max-turns 4 --format json"). Split on
#                       whitespace; quoted arguments containing spaces are not
#                       supported.

set -euo pipefail

CONNECTION_NAME="${CONNECTION_NAME:-default}"

if [[ -z "${CORTEX_PROMPT:-}" ]]; then
    echo "::error::run-prompt.sh called with an empty prompt" >&2
    exit 1
fi

# Split the passthrough args on whitespace into an array (empty -> none). The
# `[@]+` guard keeps expansion safe under `set -u` when the array is empty.
EXTRA_ARGS=()
if [[ -n "${CORTEX_PROMPT_ARGS:-}" ]]; then
    read -ra EXTRA_ARGS <<< "$CORTEX_PROMPT_ARGS"
fi

if [[ -f "$CORTEX_PROMPT" ]]; then
    echo "Running Cortex Code prompt from file: ${CORTEX_PROMPT}"
    cortex exec --file "$CORTEX_PROMPT" -c "$CONNECTION_NAME" --bypass --no-history "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
else
    echo "Running Cortex Code inline prompt"
    cortex exec "$CORTEX_PROMPT" -c "$CONNECTION_NAME" --bypass --no-history "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi
