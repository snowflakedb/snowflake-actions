#!/usr/bin/env bash
# Shared helpers for the GitHub OIDC token variable.
#
# Sourced by oidc-token.sh and oidc-token-keepalive.sh. The token is exported
# into the shell. It is not written to a file. A later process cannot see a
# variable this shell has not exported, so the keepalive refreshes it in this
# shell before a command once the token is older than 4 minutes.

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

oidc_refresh_env_if_due() {
    local name interval now issued audience token
    [ "${OIDC_TOKEN_SUPPLIED:-}" = "true" ] && return 0
    name="$(oidc_token_env_name)" || return 1
    interval="$(oidc_interval)"
    now="$(date +%s)"
    issued="${OIDC_TOKEN_ISSUED_AT:-0}"
    case "$issued" in
        ''|*[!0-9]*) issued=0 ;;
    esac
    if [ -n "${!name:-}" ] && [ "$issued" -gt 0 ] && [ $((now - issued)) -lt "$interval" ]; then
        return 0
    fi
    audience="${SNOWFLAKE_AUDIENCE:-${OIDC_AUDIENCE:-}}"
    if [ -z "$audience" ]; then
        echo "::error::SNOWFLAKE_AUDIENCE is not set, so the OIDC token cannot be refreshed." >&2
        return 1
    fi
    token="$(oidc_mint_github_token "$audience")" || return 1
    oidc_export_token "$name" "$token"
}

oidc_refresh_before_command() {
    [ "${OIDC_REFRESH_BUSY:-}" = 1 ] && return 0
    OIDC_REFRESH_BUSY=1
    oidc_refresh_env_if_due || true
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
