#!/usr/bin/env bash

# Sourced from BASH_ENV at the start of a later bash step.
#
# Do not change shell options. A failure here must not abort a step that may
# not call snow. GitHub invokes bash with -e; guard every command that can fail.
#
# The runner drops a background process that stayed in the step's process
# group. If the refresher is gone, start it again. If the token file is older
# than the refresh interval, mint once before the step's commands run.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "source this file; do not execute it" >&2
    exit 1
fi

_oidc_keepalive() {
    local here state_file python now mtime age pid pidfile token current file_current
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    state_file="${here}/refresh.env"
    if [ ! -f "$state_file" ] || [ ! -f "${here}/oidc-token-refresh.sh" ]; then
        return 0
    fi
    # shellcheck disable=SC1091
    source "${here}/oidc-token-refresh.sh"
    local TOKEN_FILE TOKEN_ENV_NAME TOKEN_FILE_ENV_NAME AUDIENCE INTERVAL
    # shellcheck disable=SC1090
    source "$state_file"
    case "${INTERVAL:-}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ -z "${TOKEN_FILE:-}" ] || [ -z "${TOKEN_ENV_NAME:-}" ] || [ -z "${AUDIENCE:-}" ]; then
        return 0
    fi

    if [ -f "$TOKEN_FILE" ]; then
        python="$(command -v python3 || command -v python || true)"
        if [ -n "$python" ]; then
            now="$("$python" -c 'import time; print(int(time.time()))' 2>/dev/null || true)"
            mtime="$("$python" -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$TOKEN_FILE" 2>/dev/null || true)"
            case "$now" in
                ''|*[!0-9]*) ;;
                *)
                    case "$mtime" in
                        ''|*[!0-9]*) ;;
                        *)
                            age=$((now - mtime))
                            if [ "$age" -ge "$INTERVAL" ]; then
                                if ! oidc_refresh_once; then
                                    echo "::warning::Could not refresh the Snowflake OIDC token; later snow commands may fail authentication."
                                fi
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
    fi

    pidfile="${here}/refresh.pid"
    pid=""
    if [ -f "$pidfile" ]; then
        pid="$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || true)"
    fi
    if ! oidc_pid_alive "$pid"; then
        if ! oidc_start_daemon "$here" "${here}/oidc-token-refresh.sh"; then
            echo "::warning::Could not start background refresh of the Snowflake OIDC token. Bash steps will refresh a stale token before they run."
        fi
    fi

    if [ -f "$TOKEN_FILE" ]; then
        token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
        case "$token" in
            *$'\n'*|*$'\r'*) token="" ;;
        esac
        if [ -n "$token" ]; then
            echo "::add-mask::${token}"
            current="${!TOKEN_ENV_NAME-}"
            if [ "$current" != "$token" ]; then
                oidc_publish_env "$TOKEN_ENV_NAME" "$token" || true
            fi
        fi
    fi
    if [ -n "${TOKEN_FILE_ENV_NAME:-}" ]; then
        file_current="${!TOKEN_FILE_ENV_NAME-}"
        if [ "$file_current" != "$TOKEN_FILE" ]; then
            oidc_publish_env "$TOKEN_FILE_ENV_NAME" "$TOKEN_FILE" || true
        fi
    fi
    return 0
}

_oidc_keepalive || echo "::warning::Could not refresh the Snowflake OIDC token; later snow commands may fail authentication."
unset -f _oidc_keepalive \
    oidc_reject_control_chars \
    oidc_token_file_env_name \
    oidc_state_dir \
    oidc_interval \
    oidc_write_token_file \
    oidc_mint_github_token \
    oidc_refresh_once \
    oidc_pid_alive \
    oidc_publish_env \
    oidc_write_state \
    oidc_prepare_bash_env \
    oidc_start_daemon \
    oidc_install_refresh \
    oidc_refresh_loop || true
