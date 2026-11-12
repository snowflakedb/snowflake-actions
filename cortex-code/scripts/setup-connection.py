#!/usr/bin/env python3
"""Auto-configure connections.toml for Cortex Code CLI.

Detection logic:
1. If connection already exists in connections.toml -> skip (no overwrite).
2. If the parent action configured OIDC (SF_CICD_AUTH_TYPE=oidc, or a token env
   var) -> write a workload-identity connection. The token stays in the
   environment and is not copied into the file.
3. If neither signal nor an existing connection -> skip gracefully (install-only mode).

Requires Python 3.11+ (tomllib in stdlib).
"""

import json
import os
import re
import sys
from pathlib import Path
from typing import NoReturn

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("::error::Python 3.11+ required (tomllib not available).")


def error(msg: str) -> NoReturn:
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def env_optional(name: str) -> str:
    return os.environ.get(name, "").strip()


def write_toml_value(f, key: str, value: str) -> None:
    # json.dumps gives correct TOML basic string quoting (handles " and \ safely)
    f.write(f"{key:<27}= {json.dumps(value)}\n")


def main() -> None:
    conn_name = os.environ.get("CONNECTION_NAME", "default")
    # Uppercase to match oidc-token.sh, which mints the token into the
    # uppercased env-var name. Keep these two in sync or a lowercase
    # oidc-token-name silently skips connection setup even when OIDC succeeded.
    token_var = os.environ.get("OIDC_TOKEN_NAME", "SNOWFLAKE_TOKEN").upper()
    conn_file = Path.home() / ".snowflake" / "connections.toml"

    # Validate connection name (prevent TOML injection)
    if not re.match(r"^[a-zA-Z0-9_-]+$", conn_name):
        error(
            f"Invalid connection name '{conn_name}'. "
            "Only alphanumeric characters, hyphens, and underscores are allowed."
        )

    # Read existing connections once (empty dict if the file is absent).
    if conn_file.exists():
        try:
            existing = tomllib.loads(conn_file.read_text())
        except tomllib.TOMLDecodeError as exc:
            error(f"{conn_file} is not valid TOML: {exc}")
    else:
        existing = {}

    # Never overwrite a connection that already exists.
    if conn_name in existing:
        print(f"Connection [{conn_name}] already exists in {conn_file}. Skipping.")
        return

    # The parent action sets SF_CICD_AUTH_TYPE. A bash step may also export the
    # token. A caller-supplied token is a signal too. The token is not written
    # into the connection.
    #
    # Snowflake CLI merges SNOWFLAKE_TOKEN into every connection and, on 3.33,
    # mints only when token and token_file_path are both empty. The Python
    # connector does not read SNOWFLAKE_TOKEN into a named connection loaded
    # from this file; OIDC there requires the token on the connection. Cortex
    # Code 1.1.104 does: for authenticator WORKLOAD_IDENTITY it uses
    # SNOWFLAKE_TOKEN when the connection has no token. Set oidc-token-name
    # to SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN to supply only that named
    # connection for snow.
    token = env_optional(token_var)
    oidc_configured = env_optional("SF_CICD_AUTH_TYPE") == "oidc"
    if not token and not oidc_configured:
        # No token -- if the file already defines connections, leave them for
        # the user; otherwise there is nothing to do (install-only mode).
        if existing:
            print(
                f"No {token_var} found, but {conn_file} has existing connections. "
                f"Cortex CLI can use: cortex -c <name>"
            )
            return
        print(
            f"No {token_var} in environment and no connections.toml found. "
            "Skipping connection setup. To enable, set use-oidc: true on this action "
            "(or run snowflakedb/snowflake-actions@v3 with use-oidc: true before it)."
        )
        return

    # Validate required env vars for writing the connection
    account = env_optional("SNOWFLAKE_ACCOUNT")
    user = env_optional("SNOWFLAKE_USER")
    if not account or not user:
        error(
            "OIDC is configured but SNOWFLAKE_ACCOUNT and/or SNOWFLAKE_USER are missing. "
            "Set these as env vars in your workflow."
        )

    # Write connection block (append to preserve existing connections)
    conn_file.parent.mkdir(parents=True, exist_ok=True)

    with open(conn_file, "a") as f:
        # Blank line separator if file already has content
        if conn_file.exists() and conn_file.stat().st_size > 0:
            f.write("\n")

        f.write(f"[{conn_name}]\n")
        write_toml_value(f, "account", account)
        write_toml_value(f, "user", user)
        write_toml_value(f, "authenticator", "WORKLOAD_IDENTITY")
        write_toml_value(f, "workload_identity_provider", "OIDC")

        warehouse = env_optional("SNOWFLAKE_WAREHOUSE")
        if warehouse:
            write_toml_value(f, "warehouse", warehouse)

        role = env_optional("SNOWFLAKE_ROLE")
        if role:
            write_toml_value(f, "role", role)

        database = env_optional("SNOWFLAKE_DATABASE")
        if database:
            write_toml_value(f, "database", database)

    conn_file.chmod(0o600)
    print(f"Connection [{conn_name}] auto-configured in {conn_file}")


if __name__ == "__main__":
    main()
