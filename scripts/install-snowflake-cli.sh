#!/usr/bin/env bash

# Install the Snowflake CLI into an isolated `uv` tool environment.
#
# Python is pinned per-install via `uv tool install --python 3.11` rather than
# UV_PYTHON, so the consumer's job environment is never touched (a leaked
# UV_PYTHON would break later `uv` steps that require a different interpreter).
# The local-artifact path is the exception: it uses the python3 already on
# PATH and `--offline`, so uv does not download an interpreter or wheels.
#
# Offline / air-gapped runners:
#   - If `snow` is already on PATH and the caller did not set CLI_VERSION,
#     CUSTOM_GITHUB_REF, or CLI_ARTIFACT, this script does nothing.
#   - CLI_VERSION=latest still installs from PyPI, even when snow is present.
#   - CLI_ARTIFACT installs that wheel, sdist, or directory of wheels with
#     `uv tool install --offline`. Dependency wheels must sit next to the
#     artifact (or inside the directory) so `--find-links` can resolve them.
#
# Requires `uv` on PATH for any install that actually runs. The action runs
# astral-sh/setup-uv first unless the plan step skips it.
#
# PyPI installs pass --no-build (wheels only). A git ref is a source
# checkout, so that path does not.
#
# Env:
#   CLI_VERSION         Snowflake CLI version (e.g. "3.20.0"), "latest", or empty.
#   CUSTOM_GITHUB_REF   Branch/tag/commit to install from source instead of PyPI.
#   CLI_ARTIFACT        Local wheel, sdist, or directory of wheels. Offline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli-airgap-env.sh
source "${SCRIPT_DIR}/cli-airgap-env.sh"

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

publish_path() {
    if [ -z "${GITHUB_PATH:-}" ]; then
        return 0
    fi
    echo "${HOME}/.local/bin" >> "$GITHUB_PATH"
    if command -v snow >/dev/null 2>&1; then
        dirname "$(command -v snow)" >> "$GITHUB_PATH"
    fi
}

if [ -z "$CLI_VERSION" ] && [ -z "$CUSTOM_GITHUB_REF" ] && [ -z "$CLI_ARTIFACT" ] \
    && command -v snow >/dev/null 2>&1; then
    echo "Snowflake CLI already on PATH ($(command -v snow)); skipping download."
    snow --version
    publish_path
    publish_air_gapped_cli_env
    exit 0
fi

if [ -n "$CLI_ARTIFACT" ]; then
    if [ ! -e "$CLI_ARTIFACT" ]; then
        echo "::error::cli-artifact path does not exist: ${CLI_ARTIFACT}"
        exit 1
    fi
    if ! command -v uv >/dev/null 2>&1; then
        echo "::error::cli-artifact is set but uv is not on PATH. Preinstall uv; this path does not download it."
        exit 1
    fi
    python="$(command -v python3 || true)"
    if [ -z "$python" ]; then
        echo "::error::cli-artifact is set but python3 is not on PATH. Preinstall Python; this path does not download an interpreter."
        exit 1
    fi
    echo "Installing Snowflake CLI from local artifact ${CLI_ARTIFACT} (offline)"
    if [ -d "$CLI_ARTIFACT" ]; then
        uv tool install --offline --python "$python" --find-links "$CLI_ARTIFACT" snowflake-cli
    else
        links="$(cd "$(dirname "$CLI_ARTIFACT")" && pwd)"
        uv tool install --offline --python "$python" --find-links "$links" "$CLI_ARTIFACT"
    fi
    publish_air_gapped_cli_env
elif [ -n "$CUSTOM_GITHUB_REF" ]; then
    echo "Installing Snowflake CLI from snowflakedb/snowflake-cli@${CUSTOM_GITHUB_REF}"
    uv tool install --python 3.11 "git+https://github.com/snowflakedb/snowflake-cli.git@${CUSTOM_GITHUB_REF}"
elif [ -n "$CLI_VERSION" ] && [ "$CLI_VERSION" != "latest" ]; then
    echo "Installing Snowflake CLI ${CLI_VERSION}"
    uv tool install --no-build --python 3.11 "snowflake-cli==${CLI_VERSION}"
else
    echo "Installing latest Snowflake CLI release"
    uv tool install --no-build --python 3.11 snowflake-cli
fi

if [ -z "$CLI_ARTIFACT" ]; then
    publish_network_cli_source
fi

publish_path
export PATH="${HOME}/.local/bin:${PATH}"
snow --version
