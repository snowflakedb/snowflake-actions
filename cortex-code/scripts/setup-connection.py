#!/usr/bin/env python3
"""Auto-configure connections.toml for Cortex Code CLI.

Detection logic:
1. If connection already exists in connections.toml -> skip (no overwrite).
2. If OIDC token is set in env (parent action configured OIDC) -> write connection using env vars.
3. If neither token nor existing connection -> skip gracefully (install-only mode).

Requires Python 3.11+ (tomllib in stdlib).
"""

import json
import os
import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("::error::Python 3.11+ required (tomllib not available).")


def error(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def env_optional(name: str) -> str:
    return os.environ.get(name, "").strip()


def write_toml_value(f, key: str, value: str) -> None:
    # json.dumps gives correct TOML basic string quoting (handles " and \ safely)
    f.write(f"{key:<27}= {json.dumps(value)}\n")


def main() -> None:
    conn_name = os.environ.get("CONNECTION_NAME", "default")
    token_var = os.environ.get("OIDC_TOKEN_NAME", "SNOWFLAKE_TOKEN")
    conn_file = Path.home() / ".snowflake" / "connections.toml"

    # Validate connection name (prevent TOML injection)
    if not re.match(r"^[a-zA-Z0-9_-]+$", conn_name):
        error(
            f"Invalid connection name '{conn_name}'. "
            "Only alphanumeric characters, hyphens, and underscores are allowed."
        )

    # Check if connection already exists
    if conn_file.exists():
        existing = tomllib.loads(conn_file.read_text())
        if conn_name in existing:
            print(f"Connection [{conn_name}] already exists in {conn_file}. Skipping.")
            return

    # Auto-detect: look for OIDC token from parent action
    token = env_optional(token_var)
    if not token:
        # No token -- check if file has ANY connection already
        if conn_file.exists():
            existing = tomllib.loads(conn_file.read_text())
            if existing:
                print(
                    f"No {token_var} found, but {conn_file} has existing connections. "
                    f"Cortex CLI can use: cortex -c <name>"
                )
                return
        # No token, no file -- not an error, just skip (install-only mode)
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
            f"{token_var} is set but SNOWFLAKE_ACCOUNT and/or SNOWFLAKE_USER are missing. "
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
