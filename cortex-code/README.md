# Cortex Code CLI action

> [!NOTE]
> The Cortex Code CLI action is in **public preview**. Its inputs and behavior may change before general availability.

Installs and configures the [Cortex Code CLI](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli) (`cortex`) for CI/CD workflows. It configures OIDC on its own and does **not** require the Snowflake CLI to be installed first.

There are three ways to get it:

**1. Standalone** — the leaf action, no Snowflake CLI:

```yaml
permissions:
  id-token: write
  contents: read

- uses: snowflakedb/snowflake-actions/cortex-code@v3
  with:
    use-oidc: true
  env:
    SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
```

**2. Alongside the Snowflake CLI** — from the [root action](../README.md) in one step:

```yaml
- uses: snowflakedb/snowflake-actions@v3
  with:
    cortex-code: true
    use-oidc: true
```

**3. After the Snowflake CLI** — the leaf reuses the OIDC token the parent already set, so `use-oidc` can be omitted:

```yaml
- uses: snowflakedb/snowflake-actions@v3
  with:
    use-oidc: true

- uses: snowflakedb/snowflake-actions/cortex-code@v3
  env:
    SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
```

## How it works

1. Installs the Cortex Code CLI from the specified channel.
2. Pins a specific version when `cli-version` is anything other than `latest`.
3. With `use-oidc: true`, mints a GitHub OIDC token (no Snowflake CLI needed). If a prior step already exported the token, it's reused.
4. Writes `connections.toml` (account, user, and workload-identity settings) so `cortex -c <name>` resolves. The OIDC token itself is read from the `SNOWFLAKE_TOKEN` environment variable at run time, not persisted to the file. If a connection with that name already exists, it skips (no overwrite).
5. If `prompt` or `prompt-file` is set, runs it with `cortex exec ... -c <connection-name> --bypass --no-history` (plus any `prompt-args`). `prompt` is sent as an inline string; `prompt-file` is sent as `--file <path>`. Setting both is an error. If the target connection isn't configured, the step fails early with a clear message rather than deep inside `cortex`. A non-zero exit from `cortex` fails the step.

See [Authentication (OIDC)](../README.md#authentication-oidc) in the root docs for how to set up the Snowflake service user.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-channel` | `stable` | Install channel: `stable` or `beta`. |
| `cli-version` | `latest` | Version to install (e.g. `1.5.2`). Requires the version to be available in the channel. |
| `use-oidc` | `false` | Mint a GitHub OIDC token and write a workload-identity connection. Needs `id-token: write`. Leave `false` if a parent step already set the token. |
| `connection-name` | `default` | Connection name written to `connections.toml`. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var name holding the OIDC token. Must match the token env var set by `use-oidc` (or by a parent action). |
| `prompt` | none | Optional **inline** prompt string to run after setup. Mutually exclusive with `prompt-file`. Leave both empty to install and configure only. |
| `prompt-file` | none | Optional path to a **file** containing the prompt to run after setup. Mutually exclusive with `prompt`. |
| `prompt-args` | none | Extra arguments appended to `cortex exec` when running `prompt`/`prompt-file` (e.g. `--max-turns 4 --output-format stream-json`). Space-separated; quoted arguments containing spaces are not supported. |

> When installed via the [root action](../README.md), these inputs are named `cortex-channel` / `cortex-version` (to disambiguate from the Snowflake CLI's own `cli-version`).

## Outputs

| Output | Description |
|--------|-------------|
| `cortex-version` | Installed Cortex Code CLI version string. |

## Example: Cortex Code agent workflow

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  scan:
    runs-on: ubuntu-latest
    env:
      SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
      SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
      SNOWFLAKE_ROLE: ${{ secrets.SNOWFLAKE_ROLE }}
      SNOWFLAKE_WAREHOUSE: ${{ secrets.SNOWFLAKE_WAREHOUSE }}
    steps:
      - uses: actions/checkout@v4

      - uses: snowflakedb/snowflake-actions/cortex-code@v3
        with:
          cli-channel: beta
          use-oidc: true
          # Use prompt-file for a file, or prompt: "..." for an inline string.
          prompt-file: .cortex/prompts/scan.md
          prompt-args: "--max-turns 4"
```

Omit `prompt`/`prompt-file` to install and configure only, then invoke `cortex` yourself in a later step:

```yaml
      - uses: snowflakedb/snowflake-actions/cortex-code@v3
        with:
          use-oidc: true

      - run: cortex exec --file .cortex/prompts/scan.md -c default --bypass --no-history
```

## Platform support

Runs on Linux (ubuntu) GitHub-hosted runners. Requires Python 3.11+ on PATH (satisfied by all GitHub-hosted runners).

## Self-hosted runners

On self-hosted runners that persist between jobs, add a cleanup step to remove credentials:

```yaml
- name: Clean up credentials
  if: always()
  run: rm -f ~/.snowflake/connections.toml
```
