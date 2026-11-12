#!/usr/bin/env bash

# Keep a GitHub Actions OIDC token fresh for later `snow` commands.
#
# GitHub's OIDC ID token expires after 5 minutes. Snowflake CLI 3.33 and later
# keep a connection token or token_file_path that is already set, so a later
# `snow` process will not mint its own. This action writes the token to a file
# and exports the matching *_TOKEN_FILE_PATH variable. The connector reads that
# file when it connects, which is how a refresh becomes visible to the next
# `snow` process.
#
# A background loop replaces the file every 4 minutes (inside the 5 minute
# lifetime). It must not write $GITHUB_ENV: that path belongs to one step, and
# the runner applies it only when the step ends. The loop also leaves the
# step's process group (the runner kills that group when the step ends).
#
# Sourced by oidc-token.sh and by oidc-token-keepalive.sh. Executed, it is the
# loop. OIDC_TOKEN_REFRESH=false skips the loop; the tests use that.

oidc_reject_control_chars() {
    local value="$1" what="$2"
    case "$value" in
        *$'\n'*|*$'\r'*)
            echo "::error::${what} must be a single line." >&2
            return 1
            ;;
    esac
}

oidc_token_file_env_name() {
    printf '%s_FILE_PATH' "$1"
}

oidc_state_dir() {
    printf '%s' "${OIDC_REFRESH_STATE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/snowflake-oidc-refresh}"
}

oidc_interval() {
    local interval="${OIDC_TOKEN_REFRESH_INTERVAL:-240}"
    case "$interval" in
        ''|*[!0-9]*) interval=240 ;;
    esac
    # Never refresh slower than every 4 minutes. The token expires at 5.
    if [ "$interval" -lt 1 ] || [ "$interval" -gt 240 ]; then
        interval=240
    fi
    printf '%s' "$interval"
}

oidc_write_token_file() {
    local path="$1" token="$2" dir tmp
    oidc_reject_control_chars "$token" "OIDC token" || return 1
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    chmod 700 "$dir"
    tmp="$(mktemp "${dir}/token.XXXXXX")"
    chmod 600 "$tmp"
    printf '%s' "$token" > "$tmp"
    mv -f "$tmp" "$path"
    chmod 600 "$path"
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

oidc_refresh_once() {
    local token
    token="$(oidc_mint_github_token "$AUDIENCE")" || return 1
    oidc_write_token_file "$TOKEN_FILE" "$token" || return 1
}

oidc_pid_alive() {
    local pid="$1" cmdline
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
        case "$cmdline" in
            *oidc-token-refresh.sh*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

oidc_publish_env() {
    local name="$1" value="$2"
    case "$name" in
        ''|*[!A-Z0-9_]*) return 1 ;;
    esac
    oidc_reject_control_chars "$value" "$name" || return 1
    export "${name}=${value}"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "$name" "$value" >> "$GITHUB_ENV"
    fi
}

oidc_write_state() {
    local state_dir="$1" state_file tmp
    state_file="${state_dir}/refresh.env"
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    tmp="$(mktemp "${state_dir}/refresh.env.XXXXXX")"
    chmod 600 "$tmp"
    {
        printf 'TOKEN_FILE=%q\n' "$TOKEN_FILE"
        printf 'TOKEN_ENV_NAME=%q\n' "$TOKEN_ENV_NAME"
        printf 'TOKEN_FILE_ENV_NAME=%q\n' "$TOKEN_FILE_ENV_NAME"
        printf 'AUDIENCE=%q\n' "$AUDIENCE"
        printf 'INTERVAL=%q\n' "$INTERVAL"
    } > "$tmp"
    mv -f "$tmp" "$state_file"
    chmod 600 "$state_file"
}

oidc_prepare_bash_env() {
    local state_dir="$1" keepalive="$2" target previous quoted_keepalive
    if [ -z "${BASH_ENV:-}" ] || [ "$BASH_ENV" = "$keepalive" ]; then
        printf '%s' "$keepalive"
        return 0
    fi
    target="${state_dir}/bash-env.sh"
    previous="$(printf '%q' "$BASH_ENV")"
    quoted_keepalive="$(printf '%q' "$keepalive")"
    cat > "$target" << EOF
# Chain the BASH_ENV that was already set, then refresh the Snowflake OIDC token.
if [ -f $previous ]; then
  # shellcheck disable=SC1090
  source $previous
fi
# shellcheck disable=SC1091
source $quoted_keepalive
EOF
    chmod 700 "$target"
    printf '%s' "$target"
}

oidc_start_daemon() {
    local state_dir="$1" script="$2" pidfile log python bash existing
    pidfile="${state_dir}/refresh.pid"
    log="${state_dir}/refresh.log"
    if [ -f "$pidfile" ]; then
        existing="$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || true)"
        if oidc_pid_alive "$existing"; then
            return 0
        fi
    fi
    python="$(command -v python3 || command -v python || true)"
    bash="$(command -v bash || true)"
    if [ -z "$python" ] || [ -z "$bash" ]; then
        return 1
    fi
    : > "$log"
    chmod 600 "$log"
    "$python" - "$pidfile" "$bash" "$script" "$log" << 'PY'
import os
import sys

pidfile, bash, script, logpath = sys.argv[1:5]


def write_pid(pid):
    with open(pidfile, "w", encoding="ascii") as handle:
        handle.write(str(pid))
        handle.write("\n")


def launch_windows():
    import subprocess

    env = os.environ.copy()
    env.pop("BASH_ENV", None)
    # CREATE_BREAKAWAY_FROM_JOB (0x01000000) lets the loop survive the step.
    # Windows may refuse it; the retry still detaches from this console.
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP | 0x01000000
    with open(logpath, "a", encoding="utf-8") as log_handle:
        try:
            proc = subprocess.Popen(
                [bash, script],
                creationflags=flags,
                close_fds=True,
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                env=env,
            )
        except OSError:
            flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
            proc = subprocess.Popen(
                [bash, script],
                creationflags=flags,
                close_fds=True,
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                env=env,
            )
    write_pid(proc.pid)


def launch_unix():
    # The parent writes the grandchild pid before it exits, so the caller can
    # read the pidfile as soon as this process returns. setsid leaves the
    # step's process group; the second fork reparents the loop to init.
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid > 0:
        os.close(write_fd)
        data = b""
        while not data.endswith(b"\n") and len(data) < 64:
            chunk = os.read(read_fd, 64)
            if not chunk:
                break
            data += chunk
        os.close(read_fd)
        write_pid(int(data.strip() or "0"))
        if int(data.strip() or "0") <= 0:
            raise SystemExit(1)
        os._exit(0)
    os.close(read_fd)
    os.setsid()
    os.environ.pop("BASH_ENV", None)
    pid = os.fork()
    if pid > 0:
        os.write(write_fd, str(pid).encode("ascii") + b"\n")
        os.close(write_fd)
        os._exit(0)
    os.close(write_fd)
    os.chdir("/")
    os.umask(0o077)
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    log_fd = os.open(logpath, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(log_fd, 1)
    os.dup2(log_fd, 2)
    if devnull > 2:
        os.close(devnull)
    if log_fd > 2:
        os.close(log_fd)
    os.execv(bash, [bash, script])


try:
    if os.name == "nt":
        launch_windows()
    else:
        launch_unix()
except SystemExit:
    raise
except Exception as exc:
    sys.stderr.write(f"refresh launch failed: {exc}\n")
    sys.exit(1)
PY
}

oidc_install_refresh() {
    local token="$1" state_dir script_dir interval token_file bash_env
    local refresh_copy keepalive_copy
    case "$TOKEN_NAME_UPPER" in
        ''|*[!A-Z0-9_]*)
            echo "::error::oidc-token-name must be an environment variable name." >&2
            return 1
            ;;
    esac
    oidc_reject_control_chars "$token" "OIDC token" || return 1
    oidc_reject_control_chars "$AUDIENCE" "OIDC audience" || return 1
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    state_dir="$(oidc_state_dir)"
    interval="$(oidc_interval)"
    token_file="${state_dir}/token"
    oidc_reject_control_chars "$token_file" "OIDC token file path" || return 1
    TOKEN_FILE="$token_file"
    TOKEN_ENV_NAME="$TOKEN_NAME_UPPER"
    # SNOWFLAKE_TOKEN -> SNOWFLAKE_TOKEN_FILE_PATH, and
    # SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN -> SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN_FILE_PATH.
    # The CLI only maps a file variable for names that end in _TOKEN.
    TOKEN_FILE_ENV_NAME=""
    case "$TOKEN_NAME_UPPER" in
        *_TOKEN) TOKEN_FILE_ENV_NAME="$(oidc_token_file_env_name "$TOKEN_NAME_UPPER")" ;;
    esac
    INTERVAL="$interval"
    umask 077
    oidc_write_token_file "$token_file" "$token"
    oidc_write_state "$state_dir"
    echo "::add-mask::${token}"
    {
        printf '%s=%s\n' "$TOKEN_ENV_NAME" "$token"
        if [ -n "$TOKEN_FILE_ENV_NAME" ]; then
            printf '%s=%s\n' "$TOKEN_FILE_ENV_NAME" "$token_file"
        fi
        echo "SF_CICD_AUTH_TYPE=oidc"
        printf 'SNOWFLAKE_AUDIENCE=%s\n' "$AUDIENCE"
    } >> "$GITHUB_ENV"
    if [ "${OIDC_TOKEN_REFRESH:-true}" = "false" ]; then
        echo "Minted GitHub OIDC token into \$${TOKEN_ENV_NAME} (audience: ${AUDIENCE})."
        return 0
    fi
    refresh_copy="${state_dir}/oidc-token-refresh.sh"
    keepalive_copy="${state_dir}/oidc-token-keepalive.sh"
    cp "$script_dir/oidc-token-refresh.sh" "$refresh_copy"
    cp "${script_dir}/oidc-token-keepalive.sh" "$keepalive_copy"
    chmod 700 "$refresh_copy" "$keepalive_copy"
    bash_env="$(oidc_prepare_bash_env "$state_dir" "$keepalive_copy")"
    oidc_reject_control_chars "$bash_env" "BASH_ENV path" || return 1
    printf 'BASH_ENV=%s\n' "$bash_env" >> "$GITHUB_ENV"
    if ! oidc_start_daemon "$state_dir" "$refresh_copy"; then
        echo "::warning::Could not start background refresh of the Snowflake OIDC token. Bash steps will refresh a stale token before they run."
    fi
    echo "Minted GitHub OIDC token into \$${TOKEN_ENV_NAME} (audience: ${AUDIENCE}). Refreshing it every ${interval}s."
}

oidc_refresh_loop() {
    local here state_file
    trap '' HUP
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    state_file="${here}/refresh.env"
    if [ ! -f "$state_file" ]; then
        echo "refresh failed" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$state_file"
    case "${INTERVAL:-}" in
        ''|*[!0-9]*)
            echo "refresh failed" >&2
            exit 1
            ;;
    esac
    if [ -z "${TOKEN_FILE:-}" ] || [ -z "${AUDIENCE:-}" ]; then
        echo "refresh failed" >&2
        exit 1
    fi
    # Sleep first. The caller just minted this token.
    while true; do
        sleep "$INTERVAL" || exit 0
        if ! oidc_refresh_once; then
            echo "refresh failed" >&2
        fi
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    oidc_refresh_loop
fi
