#!/usr/bin/env bash
# Shared helpers for the GitHub OIDC token variable.
#
# Sourced by oidc-token.sh and oidc-token-keepalive.sh. The token is exported
# into the shell. It is not written to a file. A child of this bash step mints
# a new token every 4 minutes into an anonymous pipe. The shell copies the
# newest value into the environment before the next command.
#
# Mint helpers clear BASH_ENV. A bash python or curl (pyenv, asdf, Nix) would
# otherwise source the keepalive again before the token exists. xtrace is off
# while the token or the Actions request token is expanded. ::add-mask:: is
# written to the stdout saved when the keepalive loaded, because a DEBUG trap
# inherits the current command's redirect.

# Turn xtrace off without tracing the token. Nested calls restore it once.
oidc_xtrace_off() {
    if [ "${OIDC_XTRACE_DEPTH:-0}" -eq 0 ]; then
        case $- in
            *x*) OIDC_XTRACE_RESTORE=1 ;;
            *) OIDC_XTRACE_RESTORE=0 ;;
        esac
    fi
    OIDC_XTRACE_DEPTH=$(( ${OIDC_XTRACE_DEPTH:-0} + 1 ))
    { set +x; } 2>/dev/null
}

oidc_xtrace_on() {
    if [ "${OIDC_XTRACE_DEPTH:-0}" -gt 0 ]; then
        OIDC_XTRACE_DEPTH=$(( OIDC_XTRACE_DEPTH - 1 ))
    fi
    if [ "${OIDC_XTRACE_DEPTH:-0}" -eq 0 ] && [ "${OIDC_XTRACE_RESTORE:-0}" = 1 ]; then
        OIDC_XTRACE_RESTORE=0
        set -x
    fi
}

# Run a mint helper without BASH_ENV. The subshell is a fork, not a new bash,
# so it does not source BASH_ENV before the exec.
oidc_exec() {
    (
        unset BASH_ENV
        unset ENV
        export OIDC_KEEPALIVE_ENTER=1
        exec "$@"
    )
}

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

oidc_first_wait() {
    local wait="${OIDC_TOKEN_FIRST_WAIT:-30}"
    case "$wait" in
        ''|*[!0-9]*) wait=30 ;;
    esac
    printf '%s' "$wait"
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
    oidc_xtrace_off
    local audience="$1" python encoded response token
    python="$(command -v python3 || command -v python || true)"
    if [ -z "$python" ]; then
        echo "::error::No python interpreter (python3 or python) found to parse the OIDC token." >&2
        oidc_xtrace_on
        return 1
    fi
    if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
        echo "::error::use-oidc is set but the GitHub OIDC endpoint is unavailable. Add 'permissions: id-token: write' to the job." >&2
        oidc_xtrace_on
        return 1
    fi
    encoded="$(oidc_exec "$python" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$audience")"
    response=$(oidc_exec curl -sS --fail --max-time 10 --connect-timeout 10 \
        -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded}") || {
        echo "::error::Could not reach the GitHub OIDC endpoint to mint a token. Confirm the job has 'permissions: id-token: write' and that GitHub Actions OIDC is reachable." >&2
        oidc_xtrace_on
        return 1
    }
    token=$(printf '%s' "$response" | oidc_exec "$python" -c 'import sys, json; print(json.load(sys.stdin)["value"])') || {
        echo "::error::Failed to obtain an OIDC token from GitHub." >&2
        oidc_xtrace_on
        return 1
    }
    if [ -z "$token" ]; then
        echo "::error::Failed to obtain an OIDC token from GitHub." >&2
        oidc_xtrace_on
        return 1
    fi
    printf '%s' "$token"
    oidc_xtrace_on
}

# Dup of the step's stdout. The DEBUG trap runs with the next command's
# redirect, and a mask written there never reaches the runner. bash 3.2 has
# no exec {fd}; fd 19 is fixed.
oidc_save_runner_stdout() {
    if { true >&19; } 2>/dev/null; then
        return 0
    fi
    exec 19>&1
    oidc_cloexec 19
}

oidc_mask_value() {
    local value="$1"
    if { true >&19; } 2>/dev/null; then
        printf '%s\n' "::add-mask::${value}" >&19
    else
        printf '%s\n' "::add-mask::${value}"
    fi
}

# Put the token in this shell only. GITHUB_ENV is a file, so the token is not
# appended there. Mask before the assignment, while xtrace is off.
oidc_export_token() {
    local name="$1" value="$2" now
    oidc_xtrace_off
    oidc_reject_control_chars "$value" "OIDC token" || {
        oidc_xtrace_on
        return 1
    }
    oidc_mask_value "$value"
    printf -v "$name" '%s' "$value"
    export "${name?}"
    now="$(date +%s)"
    printf -v OIDC_TOKEN_ISSUED_AT '%s' "$now"
    export OIDC_TOKEN_ISSUED_AT
    oidc_xtrace_on
}

# Child of this shell. $1 is the parent pid. Bash does not update PPID inside
# a process substitution, so the parent passes $$. Mints immediately, then
# again every interval, and writes one token per line to the anonymous pipe.
# No setsid: the child stays in this step's process group and dies with it.
# A down endpoint is reported once until a mint succeeds.
oidc_refresh_loop() {
    trap - DEBUG EXIT
    { set +x; } 2>/dev/null
    unset BASH_ENV
    unset ENV
    export OIDC_KEEPALIVE_ENTER=1
    local parent="$1" interval audience token slept fail_streak
    case "${parent:-}" in
        ''|*[!0-9]*) exit 0 ;;
    esac
    interval="$(oidc_interval)"
    fail_streak=0
    while kill -0 "$parent" 2>/dev/null; do
        audience="${SNOWFLAKE_AUDIENCE:-${OIDC_AUDIENCE:-}}"
        token=""
        if [ -n "$audience" ]; then
            if [ "$fail_streak" -eq 0 ]; then
                token="$(oidc_mint_github_token "$audience")" || token=""
            else
                token="$(oidc_mint_github_token "$audience" 2>/dev/null)" || token=""
            fi
        fi
        case "$token" in
            ''|*$'\n'*|*$'\r'*) token="" ;;
        esac
        if [ -n "$token" ]; then
            fail_streak=0
            printf '%s\n' "$token" || exit 0
        else
            fail_streak=$((fail_streak + 1))
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
    oidc_exec "$python" -c 'import fcntl,sys
fd = int(sys.argv[1])
fcntl.fcntl(fd, fcntl.F_SETFD, fcntl.FD_CLOEXEC)' "$fd" 2>/dev/null || true
}

# Block until the child has minted once, and export that value.
oidc_export_first_token() {
    local line name fd wait
    fd="${OIDC_REFRESH_FD:-}"
    [ -n "$fd" ] || return 1
    name="$(oidc_token_env_name)" || return 1
    wait="$(oidc_first_wait)"
    if IFS= read -r -t "$wait" -u "$fd" line; then
        [ -n "$line" ] || return 1
        oidc_export_token "$name" "$line"
        return 0
    fi
    return 1
}

# Start the mint loop in this shell. A token already set in this shell, and
# not minted here, is left alone. `{fd}` allocation is bash 4.1. macOS runners
# still ship bash 3.2.
oidc_start_background_refresh() {
    oidc_xtrace_off
    oidc_start_background_refresh_inner || true
    oidc_xtrace_on
}

oidc_start_background_refresh_inner() {
    local fd name
    [ "${OIDC_TOKEN_SUPPLIED:-}" = "true" ] && return 0
    [ "${OIDC_TOKEN_REFRESH:-}" = "false" ] && return 0
    [ -n "${OIDC_REFRESH_FD:-}" ] && return 0
    name="$(oidc_token_env_name)" || return 0
    # Empty OIDC_TOKEN_ISSUED_AT means this keepalive did not mint the value.
    if [ -n "${!name:-}" ] && [ -z "${OIDC_TOKEN_ISSUED_AT:-}" ]; then
        return 0
    fi
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
    oidc_xtrace_off
    if [ "${OIDC_REFRESH_BUSY:-}" = 1 ]; then
        oidc_xtrace_on
        return 0
    fi
    export OIDC_REFRESH_BUSY=1
    oidc_take_prefetched_token || true
    OIDC_REFRESH_BUSY=0
    oidc_xtrace_on
    return 0
}

oidc_install_keepalive() {
    local here keepalive target previous quoted wrapper dir
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    keepalive="${here}/oidc-token-keepalive.sh"
    wrapper="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/snowflake-oidc-refresh/bash-env.sh"
    # A second install must not rewrite the wrapper so that it sources itself.
    if [ "${BASH_ENV:-}" = "$keepalive" ] || [ "${BASH_ENV:-}" = "$wrapper" ]; then
        target="${BASH_ENV}"
    elif [ -n "${BASH_ENV:-}" ]; then
        dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/snowflake-oidc-refresh"
        mkdir -p "$dir"
        target="$wrapper"
        previous="$(printf '%q' "$BASH_ENV")"
        quoted="$(printf '%q' "$keepalive")"
        cat > "$target" << EOF
if [ "\${OIDC_KEEPALIVE_LOADED:-}" = 1 ] || [ "\${OIDC_KEEPALIVE_ENTER:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi
export OIDC_KEEPALIVE_ENTER=1
if [ -f $previous ]; then
  # shellcheck disable=SC1090
  . $previous
fi
unset OIDC_KEEPALIVE_ENTER
# shellcheck disable=SC1091
. $quoted
EOF
    else
        target="$keepalive"
    fi
    export BASH_ENV="$target"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'BASH_ENV=%s\n' "$target" >> "$GITHUB_ENV"
        printf 'OIDC_TOKEN_NAME=%s\n' "$(oidc_token_env_name)" >> "$GITHUB_ENV"
    fi
}
