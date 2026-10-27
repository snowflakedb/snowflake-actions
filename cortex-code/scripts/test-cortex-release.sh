#!/usr/bin/env bash

# Exercise cortex-release.sh against a fake curl. No network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

new_home() {
    HOME=$(mktemp -d)
    export HOME
    GITHUB_PATH="${HOME}/github_path"
    export GITHUB_PATH
    : > "$GITHUB_PATH"
}

install_fake_curl() {
    local bin="$1"
    local fixture="$2"
    mkdir -p "$bin"
    cat > "${bin}/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dest=""
url=""
http1=no
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o)
            dest="\$2"
            shift 2
            ;;
        -w)
            shift 2
            ;;
        --http1.1)
            http1=yes
            shift
            ;;
        -f|-s|-S|-sS|-L|-fsSL|--fail|--silent|--show-error|--location)
            shift
            ;;
        *)
            url="\$1"
            shift
            ;;
    esac
done
name=\$(basename "\$url")
name=\${name//%2B/+}
if [[ -n "\${CURL_STATE:-}" ]]; then
    printf '%s http1=%s\n' "\$name" "\$http1" >> "\${CURL_STATE}/calls"
fi
case "\${CURL_FAULT:-}" in
    tar-bytes)
        if [[ "\$name" == *.tar.gz ]]; then
            if [[ -f "\${CURL_STATE}/tar.seen" ]]; then
                echo "second package download" >&2
                exit 99
            fi
            touch "\${CURL_STATE}/tar.seen"
            cp "${fixture}/\${name}" "\$dest"
            printf '000'
            exit 1
        fi
        ;;
    tar-empty)
        if [[ "\$name" == *.tar.gz && "\$http1" != yes ]]; then
            printf '000'
            exit 1
        fi
        ;;
    tar-partial)
        if [[ "\$name" == *.tar.gz ]]; then
            if [[ -f "\${CURL_STATE}/tar.seen" ]]; then
                echo "retried partial package" >&2
                exit 99
            fi
            touch "\${CURL_STATE}/tar.seen"
            printf 'partial' > "\$dest"
            printf '000'
            exit 1
        fi
        ;;
    manifest-fail)
        if [[ "\$name" == manifest.json ]]; then
            if [[ -f "\${CURL_STATE}/manifest.seen" ]]; then
                echo "retried manifest" >&2
                exit 99
            fi
            touch "\${CURL_STATE}/manifest.seen"
            printf '000'
            exit 1
        fi
        ;;
esac
if [[ ! -f "${fixture}/\${name}" ]]; then
    printf '404'
    exit 0
fi
cp "${fixture}/\${name}" "\$dest"
printf '200'
EOF
    chmod +x "${bin}/curl"
    # This host is aarch64. The script selects the archive from uname, so the
    # fixture is named for the real platform and the fake curl maps that name.
}

run_case() {
    local name="$1"
    echo "== ${name} =="
    PASS=$((PASS + 1))
}

# --- channel install ---
run_case "channel install uses the release archive"
fixture=$(mktemp -d)
version="1.2.3+build.abc"
printf '%s\n' "$version" > "${fixture}/stable_version.txt"
# Build for this machine's platform. The fake curl serves it under the name
# the script requests.
os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | tr '[:upper:]' '[:lower:]')
case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
esac
work=$(mktemp -d)
pkg_dir="coco-${version}-${os_name}-${arch}"
mkdir -p "${work}/${pkg_dir}"
cat > "${work}/${pkg_dir}/cortex" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "cortex test-version"
fi
exit 0
EOF
chmod +x "${work}/${pkg_dir}/cortex"
tar_name="${pkg_dir}.tar.gz"
tar -czf "${fixture}/${tar_name}" -C "$work" "$pkg_dir"
checksum=$(sha256sum "${fixture}/${tar_name}" | awk '{print $1}')
python3 - "$version" "$os_name" "$arch" "$tar_name" "$checksum" "${fixture}/manifest.json" <<'PY'
import json, sys
version, os_name, arch, name, checksum, path = sys.argv[1:]
manifest = {
    "version": version,
    "packages": {os_name: {arch: {"name": name, "checksum": checksum}}},
}
# The script requests .../<version>/manifest.json. basename() of that URL is
# manifest.json, so one fixture serves every version in this test.
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
rm -rf "$work"

bin=$(mktemp -d)
install_fake_curl "$bin" "$fixture"
new_home
PATH="${bin}:/usr/bin:/bin" CORTEX_CHANNEL=stable bash "${ROOT}/install-cortex.sh" >"${HOME}/out.txt"
grep -q "cortex test-version" "${HOME}/out.txt" || fail "version output missing"
test -x "${HOME}/.local/bin/cortex" || fail "binary not installed"
test -f "${HOME}/.local/share/cortex/${version}/cortex" || fail "versioned install missing"
grep -q "${HOME}/.local/bin" "$GITHUB_PATH" || fail "GITHUB_PATH not updated"
echo "PASS"

# --- manifest mismatch ---
run_case "mismatched manifest fails before install"
python3 - "$os_name" "$arch" "$tar_name" "${fixture}/manifest.json" <<'PY'
import json, sys
os_name, arch, name, path = sys.argv[1:]
manifest = {
    "packages": {os_name: {arch: {"name": name, "checksum": "deadbeef"}}},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
new_home
set +e
output=$(PATH="${bin}:/usr/bin:/bin" CORTEX_CHANNEL=stable bash "${ROOT}/install-cortex.sh" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "mismatch should fail, got: $output"
printf '%s\n' "$output" | grep -q "does not match the release manifest" || fail "missing mismatch message: $output"
test ! -e "${HOME}/.local/bin/cortex" || fail "binary installed despite mismatch"
echo "PASS"

# --- pin archive ---
run_case "pinned published version installs the archive"
new_home
# Restore a matching manifest for the pin path.
python3 - "$version" "$os_name" "$arch" "$tar_name" "$checksum" "${fixture}/manifest.json" <<'PY'
import json, sys
version, os_name, arch, name, checksum, path = sys.argv[1:]
manifest = {"packages": {os_name: {arch: {"name": name, "checksum": checksum}}}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
PATH="${bin}:/usr/bin:/bin" CORTEX_INSTALL_MODE=downloaded CORTEX_VERSION="$version" bash "${ROOT}/pin-cortex-version.sh" >"${HOME}/pin.txt"
grep -q "Installing Cortex Code ${version}" "${HOME}/pin.txt" || fail "pin did not install the archive"
test -x "${HOME}/.local/bin/cortex" || fail "pin did not install cortex"
echo "PASS"

# --- pin fallback ---
run_case "pinned unpublished version uses cortex update"
fake_bin=$(mktemp -d)
cat > "${fake_bin}/cortex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "${CORTEX_ARGS_FILE:?}"
exit 0
EOF
chmod +x "${fake_bin}/cortex"
args_file=$(mktemp)
new_home
# No manifest and no package for this version. basename of the manifest URL is
# still manifest.json, so point the fixture at an empty directory.
empty=$(mktemp -d)
empty_bin=$(mktemp -d)
install_fake_curl "$empty_bin" "$empty"
CORTEX_ARGS_FILE="$args_file" PATH="${empty_bin}:${fake_bin}:/usr/bin:/bin" \
    CORTEX_INSTALL_MODE=downloaded CORTEX_VERSION="9.9.9" bash "${ROOT}/pin-cortex-version.sh"
grep -qx "update" "$args_file" || fail "expected cortex update, got: $(cat "$args_file")"
# The second arg is the version. The stub records every arg on its own line.
grep -qx "9.9.9" "$args_file" || fail "update was not passed the version"
echo "PASS"

# --- package transfer drop with a full body ---
run_case "package curl failure with a full archive still installs"
state=$(mktemp -d)
new_home
CURL_FAULT=tar-bytes CURL_STATE="$state" PATH="${bin}:/usr/bin:/bin" \
    CORTEX_CHANNEL=stable bash "${ROOT}/install-cortex.sh" >"${HOME}/out.txt"
grep -q "cortex test-version" "${HOME}/out.txt" || fail "version output missing after transport error"
test -x "${HOME}/.local/bin/cortex" || fail "binary not installed after transport error"
grep -q "http1=yes" "${state}/calls" && fail "retried a package that already had bytes"
echo "PASS"

# --- empty dest retries once over HTTP/1.1 ---
run_case "empty package download retries once with http1.1"
state=$(mktemp -d)
new_home
CURL_FAULT=tar-empty CURL_STATE="$state" PATH="${bin}:/usr/bin:/bin" \
    CORTEX_CHANNEL=stable bash "${ROOT}/install-cortex.sh" >"${HOME}/out.txt"
grep -q "cortex test-version" "${HOME}/out.txt" || fail "retry did not install"
grep -q "\\.tar.gz http1=no" "${state}/calls" || fail "missing first package attempt: $(cat "${state}/calls")"
grep -q "\\.tar.gz http1=yes" "${state}/calls" || fail "missing http1.1 retry: $(cat "${state}/calls")"
echo "PASS"

# --- partial body is not retried ---
run_case "partial package is not retried"
state=$(mktemp -d)
new_home
set +e
output=$(CURL_FAULT=tar-partial CURL_STATE="$state" PATH="${bin}:/usr/bin:/bin" \
    CORTEX_CHANNEL=stable bash "${ROOT}/install-cortex.sh" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "partial package should fail, got: $output"
[[ "$status" -ne 99 ]] || fail "partial package was retried: $output"
printf '%s\n' "$output" | grep -q "does not match the release manifest" || fail "missing mismatch message: $output"
test ! -e "${HOME}/.local/bin/cortex" || fail "binary installed from a partial package"
echo "PASS"

# --- manifest download stays strict ---
run_case "manifest download does not retry"
state=$(mktemp -d)
new_home
set +e
output=$(CURL_FAULT=manifest-fail CURL_STATE="$state" PATH="${bin}:/usr/bin:/bin" \
    CORTEX_CHANNEL=stable bash "${ROOT}/install-cortex.sh" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "manifest failure should fail, got: $output"
[[ "$status" -ne 99 ]] || fail "manifest was retried: $output"
printf '%s\n' "$output" | grep -q "Could not download Cortex Code release." || fail "missing strict download error: $output"
if grep -q "\\.tar.gz" "${state}/calls"; then
    fail "package download ran after a failed manifest: $(cat "${state}/calls")"
fi
test ! -e "${HOME}/.local/bin/cortex" || fail "binary installed after manifest failure"
echo "PASS"

echo "OK ${PASS} cases"
