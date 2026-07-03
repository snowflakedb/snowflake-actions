#!/usr/bin/env bash

# Run a Cortex Code prompt non-interactively in CI.
#
# The prompt comes from exactly one of two explicit inputs — an inline string
# or a path to a file. There is no path auto-detection, so an inline prompt can
# never be mistaken for a file (and vice versa).
#
# Env (set exactly one of CORTEX_PROMPT / CORTEX_PROMPT_FILE):
#   CORTEX_PROMPT       Inline prompt text.
#   CORTEX_PROMPT_FILE  Path to a file holding the prompt.
#   CONNECTION_NAME     Connection to run against (default "default").
#   CORTEX_PROMPT_ARGS  Extra arguments appended verbatim to `cortex exec`
#                       (e.g. "--max-turns 4 --output-format stream-json"). Split on
#                       whitespace; quoted arguments containing spaces are not
#                       supported.

set -euo pipefail

CONNECTION_NAME="${CONNECTION_NAME:-default}"
PROMPT="${CORTEX_PROMPT:-}"
PROMPT_FILE="${CORTEX_PROMPT_FILE:-}"

if [[ -n "$PROMPT" && -n "$PROMPT_FILE" ]]; then
    echo "::error::Set only one of prompt / prompt-file, not both." >&2
    exit 1
fi
if [[ -z "$PROMPT" && -z "$PROMPT_FILE" ]]; then
    echo "::error::run-prompt.sh called with neither prompt nor prompt-file set." >&2
    exit 1
fi

# Split the passthrough args on whitespace into an array (empty -> none). The
# `[@]+` guard keeps expansion safe under `set -u` when the array is empty.
EXTRA_ARGS=()
if [[ -n "${CORTEX_PROMPT_ARGS:-}" ]]; then
    read -ra EXTRA_ARGS <<< "$CORTEX_PROMPT_ARGS"
fi

if [[ -n "$PROMPT_FILE" && ! -f "$PROMPT_FILE" ]]; then
    echo "::error::prompt-file not found: ${PROMPT_FILE}" >&2
    exit 1
fi

# Preflight: the connection must exist before we hand off to cortex, otherwise
# `cortex exec` dies deep inside with a lower-level error. This catches the
# common case where setup-connection.py ran in install-only mode (use-oidc:
# false and no pre-set token) and never wrote the connection. Grep for the TOML
# section header — connection names are validated to [A-Za-z0-9_-] and the
# action writes the file in the standard `[name]` form.
CONN_FILE="${HOME}/.snowflake/connections.toml"
if [[ ! -f "$CONN_FILE" ]] || ! grep -q "^\[${CONNECTION_NAME}\]" "$CONN_FILE"; then
    echo "::error::prompt set but connection '${CONNECTION_NAME}' is not configured in ${CONN_FILE}. Set use-oidc: true (or pre-configure the connection) before running a prompt." >&2
    exit 1
fi

if [[ -n "$PROMPT_FILE" ]]; then
    echo "Running Cortex Code prompt from file: ${PROMPT_FILE}"
    cortex exec --file "$PROMPT_FILE" -c "$CONNECTION_NAME" --bypass --no-history "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
else
    echo "Running Cortex Code inline prompt"
    cortex exec "$PROMPT" -c "$CONNECTION_NAME" --bypass --no-history "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi
