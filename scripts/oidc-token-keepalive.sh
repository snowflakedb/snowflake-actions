#!/usr/bin/env bash
# Sourced from BASH_ENV at the start of a bash step.
#
# Exports the OIDC token into this shell and starts a child that mints a new
# one every 4 minutes. The newest token is copied into this shell before the
# next command. Does not write the token to a file. Does not change shell
# options and does not exit the step.

if [ "${OIDC_KEEPALIVE_LOADED:-}" = 1 ]; then
    # `return` fails when this file is executed instead of sourced.
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
OIDC_KEEPALIVE_LOADED=1

_oidc_keepalive_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oidc-token-env.sh
. "${_oidc_keepalive_dir}/oidc-token-env.sh"
unset _oidc_keepalive_dir

# Start the child before the trap so the child does not inherit it, and export
# its first token before this step's commands run.
oidc_start_background_refresh || true

if [ "${OIDC_REFRESH_TRAP:-}" != 1 ]; then
    trap 'oidc_refresh_before_command' DEBUG
    OIDC_REFRESH_TRAP=1
fi
