# Snowflake CLI action

Installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) (`snow`) for CI/CD workflows, so later steps can deploy dbt, Streamlit, and DCM projects, run SQL, and automate any `snow` task.

```yaml
- uses: snowflakedb/snowflake-actions/snowflake-cli@v3
```

This is the leaf form of the [root action](../README.md)'s Snowflake CLI path. Use it when you want an unambiguous, CLI-only entry point. The root action installs the Snowflake CLI by default and can additionally install Cortex Code; use this leaf when you want the Snowflake CLI and nothing else. It configures OIDC on its own and does not require any other action to run first.

## How it works

1. Installs `uv`.
2. Installs the Snowflake CLI with `uv tool install --python 3.11` into an isolated tool environment. The `snow` command is available in later steps.
3. Copies your `config.toml` to `~/.snowflake/` if present (skipped if the file doesn't exist).
4. With `use-oidc: true`, reads a GitHub OIDC token and sets the workload-identity environment variables the CLI expects.

## Example

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: snowflakedb/snowflake-actions/snowflake-cli@v3
        with:
          use-oidc: true

      - env:
          SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
        run: snow connection test -x
```

See [Authentication (OIDC)](../README.md#authentication-oidc) in the root docs for how to set up the Snowflake service user.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-version` | latest | Snowflake CLI version to install (e.g. `3.20.0`). |
| `default-config-file-path` | `./config.toml` | Path to your `config.toml`. Skipped if the file is absent. |
| `custom-github-ref` | none | Install from a branch, tag, or commit instead of PyPI. |
| `use-oidc` | `false` | Authenticate with a GitHub OIDC token. Needs CLI `3.11+` and `id-token: write`. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is exported as. Change to `SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN` to work with named connections. |

- `cli-version` and `custom-github-ref` are mutually exclusive.

## Outputs

| Output | Description |
|--------|-------------|
| `snowflake-cli-version` | Installed Snowflake CLI version. |

## Install from a branch, tag, or commit

Install the CLI from source (for example, to test an unreleased fix). Requires action `v2+`. Installs from [`snowflakedb/snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) instead of PyPI.

```yaml
- uses: snowflakedb/snowflake-actions/snowflake-cli@v3
  with:
    custom-github-ref: "feature/my-branch"   # branch, tag, or commit
```

## Credential-based auth (fallback)

Use this only when [OIDC](../README.md#authentication-oidc) isn't available. You can either:

- Pass credentials as [environment variables](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-environment-variables-for-snowflake-credentials) and use `-x` so the CLI reads them without a `config.toml`.
- Define a connection in [`config.toml`](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#define-connections).

```yaml
# Option 1: env vars + temporary connection
- uses: snowflakedb/snowflake-actions/snowflake-cli@v3
- env:
    SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    # ...other SNOWFLAKE_* vars — see docs above
  run: snow connection test -x

# Option 2: config.toml
- uses: snowflakedb/snowflake-actions/snowflake-cli@v3
  with:
    default-config-file-path: ./config.toml
- run: snow connection test
```

## Platform support

Runs on Linux, macOS, and Windows GitHub-hosted runners.

## Self-hosted runners

On self-hosted runners that persist between jobs, add a cleanup step to remove any `config.toml` this action copied into place:

```yaml
- name: Clean up credentials
  if: always()
  run: rm -f ~/.snowflake/config.toml
```
