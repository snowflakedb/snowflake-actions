#!/usr/bin/env bash

set -euo pipefail

if [ ! -e "$CONFIG_FILE_PATH" ]
then
    echo "Provided file $CONFIG_FILE_PATH not found, using default config file."
    exit 0
fi

# The command `chown $USER config.toml` doesn't work in this context,
# so copying the file is a workaround to change the file ownership to the current user.
# Stage the copy in a unique temporary directory, then install into ~/.snowflake.
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
TEMP_CONFIG="${TEMP_DIR}/config.toml"

cp "$CONFIG_FILE_PATH" "$TEMP_CONFIG"

if [[ ${RUNNER_OS:-} != "Windows" ]]; then
    chmod 0600 "$TEMP_CONFIG"
fi

mkdir -p ~/.snowflake/
mv -f "$TEMP_CONFIG" ~/.snowflake/config.toml
