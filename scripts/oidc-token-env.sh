#!/usr/bin/env bash
# Shared helpers for the GitHub OIDC token variable.
#
# Sourced by oidc-token.sh and oidc-token-keepalive.sh. The token is exported
# into the shell. It is not written to a file. A child of this bash step mints
# a new token every 4 minutes into an anonymous pipe. The shell copies the
# newest value into the environment before the next command.

oidc_reject_control_chars() {
    local value="$1" what="$2"
    case "$value" in
        *$'\n'*|*$'\r'*)
            echo "::error::${what} must be a single line." >&2
            return 1
            ;;
    esac
}

oidc_interval() {
    local interval="${OIDC_TOKEN_REFRESH_INTERVAL:-240}"
    case "$interval" in
        ''|*[!0-9]*) interval=240 ;;
    esac
    # The GitHub token expires after 5 minutes. Never wait longer than 4.
    if [ "$interval" -lt 1 ] || [ "$interval" -gt 240 ]; then
        interval=240
    fi
    printf '%s' "$interval"
}

oidc_token_env_name() {
    local name
    name="$(printf '%s' "${OIDC_TOKEN_NAME:-SNOWFLAKE_TOKEN}" | tr '[:lower:]' '[:upper:]')"
    case "$name" in
        ''|*[!A-Z0-9_]*|[0-9]*)
            echo "::error::OIDC token variable name is not an identifier." >&2
            return 1
            ;;
    esac
    printf '%s' "$name"
}

oidc_mint_github_token() {
    local audience="$1" python encoded response token
    python="$(command -v python3 || command -v python || true)"
    if [ -z "$python" ]; then
        echo "::error::No python interpreter (python3 or python) found to parse the OIDC token." >&2
        return 1
    fi
    if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
        echo "::error::use-oidc is set but the GitHub OIDC endpoint is unavailable. Add 'permissions: id-token: write' to the job." >&2
        return 1
    fi
    encoded="$("$python" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$audience")"
    response=$(curl -sS --fail \
        -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded}") || {
        echo "::error::Could not reach the GitHub OIDC endpoint to mint a token. Confirm the job has 'permissions: id-token: write' and that GitHub Actions OIDC is reachable." >&2
        return 1
    }
    token=$(printf '%s' "$response" | "$python" -c 'import sys, json; print(json.load(sys.stdin)["value"])') || {
        echo "::error::Failed to obtain an OIDC token from GitHub." >&2
        return 1
    }
    if [ -z "$token" ]; then
        echo "::error::Failed to obtain an OIDC token from GitHub." >&2
        return 1
    fi
    printf '%s' "$token"
}

# Put the token in this shell only. GITHUB_ENV is a file, so the token is not
# appended there.
oidc_export_token() {
    local name="$1" value="$2" now
    oidc_reject_control_chars "$value" "OIDC token" || return 1
    printf -v "$name" '%s' "$value"
    export "${name?}"
    now="$(date +%s)"
    printf -v OIDC_TOKEN_ISSUED_AT '%s' "$now"
    export OIDC_TOKEN_ISSUED_AT
    echo "::add-mask::${value}"
}

# Child of this shell. $1 is the parent pid. Bash does not update PPID inside
# a process substitution, so the parent passes $$. Mints immediately, then
# again every interval, and writes one token per line to the anonymous pipe.
# No setsid: the child stays in this step's process group and dies with it.
oidc_refresh_loop() {
    trap - DEBUG EXIT
    local parent="$1" interval audience token slept
    case "${parent:-}" in
        ''|*[!0-9]*) exit 0 ;;
    esac
    interval="$(oidc_interval)"
    while kill -0 "$parent" 2>/dev/null; do
        audience="${SNOWFLAKE_AUDIENCE:-${OIDC_AUDIENCE:-}}"
        token=""
        if [ -n "$audience" ]; then
            token="$(oidc_mint_github_token "$audience")" || token=""
        fi
        case "$token" in
            ''|*$'\n'*|*$'\r'*) token="" ;;
        esac
        if [ -n "$token" ]; then
            printf '%s\n' "$token" || exit 0
        fi
        slept=0
        while [ "$slept" -lt "$interval" ]; do
            kill -0 "$parent" 2>/dev/null || exit 0
            sleep 1 || exit 0
            slept=$((slept + 1))
        done
    done
    exit 0
}

# The read end is not a file. Close it on exec so a later command does not
# hold the pipe open. Windows python has no fcntl; the runner still kills the
# step's process group.
oidc_cloexec() {
    local fd="$1" python
    python="$(command -v python3 || command -v python || true)"
    [ -n "$python" ] || return 0
    "$python" -c 'import fcntl,sys
fd = int(sys.argv[1])
fcntl.fcntl(fd, fcntl.F_SETFD, fcntl.FD_CLOEXEC)' "$fd" 2>/dev/null || true
}

# Block until the child has minted once, and export that value.
oidc_export_first_token() {
    local line name fd
    fd="${OIDC_REFRESH_FD:-}"
    [ -n "$fd" ] || return 1
    name="$(oidc_token_env_name)" || return 1
    if IFS= read -r -t 30 -u "$fd" line; then
        [ -n "$line" ] || return 1
        oidc_export_token "$name" "$line"
        return 0
    fi
    return 1
}

# Start the mint loop in this shell. A caller-supplied token is left alone.
# `{fd}` allocation is bash 4.1. macOS runners still ship bash 3.2.
oidc_start_background_refresh() {
    local fd
    [ "${OIDC_TOKEN_SUPPLIED:-}" = "true" ] && return 0
    [ "${OIDC_TOKEN_REFRESH:-}" = "false" ] && return 0
    [ -n "${OIDC_REFRESH_FD:-}" ] && return 0
    fd=""
    for fd in 9 8 7; do
        if ! { true >&"$fd"; } 2>/dev/null; then
            break
        fi
        fd=""
    done
    if [ -z "$fd" ]; then
        echo "::warning::Could not start background refresh of the Snowflake OIDC token."
        return 0
    fi
    OIDC_REFRESH_FD=$fd
    case "$fd" in
        9) exec 9< <(oidc_refresh_loop "$$") ;;
        8) exec 8< <(oidc_refresh_loop "$$") ;;
        7) exec 7< <(oidc_refresh_loop "$$") ;;
    esac
    oidc_cloexec "$fd"
    if ! oidc_export_first_token; then
        echo "::warning::Could not refresh the Snowflake OIDC token; later snow commands may fail authentication."
    fi
}

# Copy the newest background token into this shell. Does not mint.
oidc_take_prefetched_token() {
    local fd line latest name
    fd="${OIDC_REFRESH_FD:-}"
    [ -n "$fd" ] || return 0
    latest=
    # `read -t 0` only reports readiness. A closed pipe stays ready, so the
    # next read has to consume the line or the EOF or this loop never ends.
    while read -t 0 <&"$fd"; do
        IFS= read -r line <&"$fd" || break
        [ -n "$line" ] && latest=$line
    done || true
    [ -n "$latest" ] || return 0
    name="$(oidc_token_env_name)" || return 0
    oidc_export_token "$name" "$latest" || true
}

oidc_refresh_before_command() {
    [ "${OIDC_REFRESH_BUSY:-}" = 1 ] && return 0
    OIDC_REFRESH_BUSY=1
    oidc_take_prefetched_token || true
    OIDC_REFRESH_BUSY=0
    return 0
}

oidc_install_keepalive() {
    local here keepalive target previous quoted
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    keepalive="${here}/oidc-token-keepalive.sh"
    target="$keepalive"
    if [ -n "${BASH_ENV:-}" ] && [ "$BASH_ENV" != "$keepalive" ]; then
        local dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/snowflake-oidc-refresh"
        mkdir -p "$dir"
        target="${dir}/bash-env.sh"
        previous="$(printf '%q' "$BASH_ENV")"
        quoted="$(printf '%q' "$keepalive")"
        cat > "$target" << EOF
if [ -f $previous ]; then
  # shellcheck disable=SC1090
  . $previous
fi
# shellcheck disable=SC1091
. $quoted
EOF
    fi
    export BASH_ENV="$target"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'BASH_ENV=%s\n' "$target" >> "$GITHUB_ENV"
        printf 'OIDC_TOKEN_NAME=%s\n' "$(oidc_token_env_name)" >> "$GITHUB_ENV"
    fi
}
