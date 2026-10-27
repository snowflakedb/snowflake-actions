#!/usr/bin/env bash

# Install one Cortex Code CLI build from its release archive.
#
# --channel <stable|beta> reads that channel's current version, then installs it.
# --version <version> installs that version. Exit 44 when that version has no
# archive, so the caller can fall back to `cortex update`.

set -euo pipefail

RELEASE_BASE="https://sfc-repo.snowflakecomputing.com/cortex-code-cli/a4643c4278"
CLEANUP_PATHS=()

cleanup() {
    local path
    for path in "${CLEANUP_PATHS[@]}"; do
        rm -rf "$path"
    done
}

trap cleanup EXIT

usage() {
    echo "usage: cortex-release.sh --channel <stable|beta> | --version <version>" >&2
    exit 1
}

encode_plus() {
    printf '%s' "${1//+/%2B}"
}

require_version_token() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]] || [[ "$version" == *..* ]]; then
        echo "::error::Unexpected Cortex Code version '${version}'."
        exit 1
    fi
}

platform() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac
    printf '%s %s\n' "$os" "$arch"
}

download() {
    local url="$1"
    local dest="$2"
    local http_code
    # No checksum for this body. A failed curl must not leave an error page to parse.
    http_code=$(curl -sS -L -o "$dest" -w '%{http_code}' "$url") || {
        rm -f "$dest"
        echo "::error::Could not download Cortex Code release." >&2
        exit 1
    }
    printf '%s' "$http_code"
}

# Package tarball only. A dropped transfer can exit non-zero after the body is
# on disk. Retry once with HTTP/1.1 when dest is missing or empty. Do not retry
# when dest already has bytes: a second curl can replace a good file with a
# partial. The caller checks the bytes against manifest.json.
download_package() {
    local url="$1"
    local dest="$2"
    local http_code=""

    if ! http_code=$(curl -sS -L -o "$dest" -w '%{http_code}' "$url"); then
        if [[ -s "$dest" ]]; then
            printf '%s' "$http_code"
            return 0
        fi
        rm -f "$dest"
        if ! http_code=$(curl -sS -L --http1.1 -o "$dest" -w '%{http_code}' "$url"); then
            if [[ ! -s "$dest" ]]; then
                rm -f "$dest"
                echo "::error::Could not download Cortex Code release." >&2
                exit 1
            fi
        fi
    fi
    printf '%s' "$http_code"
}

package_for_platform() {
    local manifest="$1"
    local os_name="$2"
    local arch="$3"
    python3 - "$os_name" "$arch" "$manifest" <<'PY'
import json
import sys

os_name, arch, path = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
try:
    package = data["packages"][os_name][arch]
except (KeyError, TypeError):
    print(f"Cortex Code is not available for {os_name}-{arch}.", file=sys.stderr)
    sys.exit(1)
name = package.get("name") or ""
checksum = package.get("checksum") or ""
if not name or not checksum:
    print(f"Cortex Code is not available for {os_name}-{arch}.", file=sys.stderr)
    sys.exit(1)
print(name)
print(checksum)
PY
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "::error::sha256sum or shasum is required to install Cortex Code."
        exit 1
    fi
}

install_tree() {
    local version="$1"
    local archive_dir="$2"
    local install_dir="${HOME}/.local/share/cortex/${version}"
    local bin_dir="${HOME}/.local/bin"
    local extracted

    extracted=""
    for candidate in "$archive_dir"/*; do
        if [[ -d "$candidate" ]]; then
            extracted="$candidate"
            break
        fi
    done
    if [[ -z "$extracted" ]]; then
        echo "::error::Cortex Code release archive did not contain a directory."
        exit 1
    fi

    rm -rf "$install_dir"
    mkdir -p "${HOME}/.local/share/cortex" "$bin_dir"
    mv "$extracted" "$install_dir"

    if [[ -f "$install_dir/dist/index.js" ]]; then
        if ! command -v node >/dev/null 2>&1; then
            echo "::error::Node.js is required for this Cortex Code version but is not installed."
            exit 1
        fi
        cat > "$bin_dir/cortex" <<EOF
#!/bin/sh
exec node "${install_dir}/dist/index.js" "\$@"
EOF
        chmod +x "$bin_dir/cortex"
        return
    fi

    if [[ ! -f "$install_dir/cortex" ]]; then
        echo "::error::Cortex Code release archive did not contain the cortex binary."
        exit 1
    fi
    chmod +x "$install_dir/cortex"
    rm -f "$bin_dir/cortex"
    ln -sf "$install_dir/cortex" "$bin_dir/cortex"
}

install_version() {
    local version="$1"
    local missing_is_soft="${2:-false}"
    local tmp http_code manifest_url os_name arch package_info tar_name checksum
    local encoded_version encoded_tar tarball actual expected

    require_version_token "$version"
    tmp=$(mktemp -d)
    CLEANUP_PATHS+=("$tmp")

    encoded_version=$(encode_plus "$version")
    manifest_url="${RELEASE_BASE}/${encoded_version}/manifest.json"
    http_code=$(download "$manifest_url" "$tmp/manifest.json")
    if [[ "$http_code" == "404" && "$missing_is_soft" == "true" ]]; then
        return 44
    fi
    if [[ "$http_code" != "200" ]]; then
        echo "::error::Could not download Cortex Code ${version} (${http_code})."
        exit 1
    fi

    read -r os_name arch < <(platform)
    if ! package_info=$(package_for_platform "$tmp/manifest.json" "$os_name" "$arch"); then
        exit 1
    fi
    tar_name=$(printf '%s\n' "$package_info" | sed -n '1p')
    checksum=$(printf '%s\n' "$package_info" | sed -n '2p')
    encoded_tar=$(encode_plus "$tar_name")
    tarball="$tmp/package.tar.gz"
    http_code=$(download_package "${RELEASE_BASE}/${encoded_version}/${encoded_tar}" "$tarball")
    # 000 or an empty status means the transfer dropped. The checksum is the gate.
    if [[ -n "$http_code" && "$http_code" != "200" && "$http_code" != "000" ]]; then
        echo "::error::Could not download Cortex Code package ${tar_name} (${http_code})."
        exit 1
    fi
    if [[ ! -s "$tarball" ]]; then
        echo "::error::Could not download Cortex Code package ${tar_name}."
        exit 1
    fi

    actual=$(sha256_file "$tarball" | tr '[:upper:]' '[:lower:]')
    expected=$(printf '%s' "$checksum" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual" != "$expected" ]]; then
        echo "::error::Cortex Code package does not match the release manifest."
        exit 1
    fi

    mkdir -p "$tmp/extract"
    tar -xzf "$tarball" -C "$tmp/extract"
    echo "Installing Cortex Code ${version}..."
    install_tree "$version" "$tmp/extract"
}

mode=""
value=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            mode="channel"
            value="${2:-}"
            shift 2
            ;;
        --version)
            mode="version"
            value="${2:-}"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "$mode" || -z "$value" ]]; then
    usage
fi

if [[ "$mode" == "channel" ]]; then
    if [[ "$value" != "stable" && "$value" != "beta" ]]; then
        echo "::error::Cortex Code channel must be stable or beta, got '${value}'."
        exit 1
    fi
    version_file=$(mktemp)
    CLEANUP_PATHS+=("$version_file")
    http_code=$(download "${RELEASE_BASE}/${value}_version.txt" "$version_file")
    if [[ "$http_code" != "200" ]]; then
        echo "::error::Could not read the ${value} Cortex Code version (${http_code})."
        exit 1
    fi
    version=$(tr -d '[:space:]' < "$version_file")
    install_version "$version" false
    exit 0
fi

install_version "$value" true
