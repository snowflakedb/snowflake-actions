# Snowflake Actions

GitHub Action that installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) and/or the [Cortex Code CLI](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli) in a workflow, so you can deploy dbt, Streamlit, and DCM projects, ship Snowflake App Runtime apps, run SQL, run agentic Cortex Code tasks, and automate any Snowflake CLI task from CI/CD.

## Choosing an entry point

| You want… | Use |
|-----------|-----|
| The Snowflake CLI (default), optionally plus Cortex Code | `snowflakedb/snowflake-actions@v3` |
| Only the Snowflake CLI, explicitly | `snowflakedb/snowflake-actions/snowflake-cli@v3` |
| Only the Cortex Code CLI | `snowflakedb/snowflake-actions/cortex-code@v3` |

The root action installs the Snowflake CLI by default. Set `cortex-code: true` to also install Cortex Code, or `snowflake-cli: false` to skip the Snowflake CLI. The two subpath actions are leaf forms for callers who want one tool and nothing else; each configures OIDC on its own, so neither requires the other to run first.

## How it works

The action installs the requested CLIs in your workflow and can configure authentication, so later steps can run `snow` and/or `cortex` commands against Snowflake.

When `snowflake-cli` is enabled (the default):

1. Installs `uv`.
2. Installs the Snowflake CLI with `uv tool install --python 3.11` into an isolated tool environment. The `snow` command is available in later steps.
3. Copies your `config.toml` to `~/.snowflake/` if present (skipped if the file doesn't exist).
4. With `use-oidc: true`, reads a GitHub OIDC token and sets the workload-identity environment variables the CLI expects.

When `cortex-code` is enabled, see [Cortex Code CLI](#cortex-code-cli).

## Example workflow

Install the Snowflake CLI and run commands against Snowflake from GitHub Actions:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: snowflakedb/snowflake-actions@v3
        with:
          use-oidc: true

      - env:
          SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
        run: snow connection test -x
      # snow dbt deploy, snow streamlit deploy, snow dcm deploy, snow sql -f migration.sql, etc.
```

> [!IMPORTANT]
> This example uses [OIDC](#oidc-recommended). Configure a Snowflake service user with a matching workload identity before you run it.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `snowflake-cli` | `true` | Install the Snowflake CLI (`snow`). |
| `cortex-code` | `false` | Also install the Cortex Code CLI (`cortex`). |
| `cli-version` | latest | Snowflake CLI version to install (e.g. `3.20.0`). |
| `use-oidc` | `false` | Authenticate with a GitHub OIDC token (applies to whichever CLIs are installed). |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is exported as. |
| `default-config-file-path` | `./config.toml` | Path to your `config.toml` (Snowflake CLI). |
| `custom-github-ref` | none | Install the Snowflake CLI from a branch, tag, or commit. |
| `cortex-channel` | `stable` | Cortex Code install channel: `stable` or `beta`. |
| `cortex-version` | `latest` | Cortex Code version to install (e.g. `1.5.2`). |
| `connection-name` | `default` | Connection name written to `connections.toml` for Cortex Code. |

- `cli-version` and `custom-github-ref` are mutually exclusive.
- `use-oidc` needs Snowflake CLI `3.11+` and `id-token: write`.
- `custom-github-ref` installs the Snowflake CLI from [`snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) instead of PyPI, and requires action `v2+`.
- `default-config-file-path` is skipped if the file is absent.
- `cortex-*` and `connection-name` apply only when `cortex-code: true`.
- `cortex-code: true` is supported on Linux runners only (the Cortex Code CLI is Linux-only), even though the Snowflake CLI itself runs on Linux, macOS, and Windows.

## Authentication

Use OIDC. It stores no secrets and is the only method we recommend. Key-pair and password auth exist only as fallbacks for environments where OIDC isn't available.

### OIDC (recommended)

GitHub issues a short-lived OIDC token that Snowflake validates directly, so no private keys are stored as secrets. Requires CLI `3.11+`.

**1. Create a service user in Snowflake** whose workload identity trusts your repo's GitHub OIDC tokens:

```sql
CREATE USER <username>
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = '<your_subject>'
  );
```

`SUBJECT` must match the claim GitHub emits for the workflow. Use one of these formats:

| Subject format | Matches | Workflow requirement |
|----------------|---------|----------------------|
| `repo:<owner>/<repo>:ref:refs/heads/<branch>` | Push to the specified branch | `on: push`, without `environment:` on the job |
| `repo:<owner>/<repo>:pull_request` | Any pull request event | `on: pull_request`, without `environment:` on the job |
| `repo:<owner>/<repo>:environment:<name>` | Job targets a named GitHub environment | Job sets `environment: <name>` (must exist in repository settings) |

See [GitHub's OIDC subject claims](https://docs.github.com/en/actions/reference/security/oidc#example-subject-claims) for the full list.

**2. Add the workflow.** `id-token: write` is required to mint the token.

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: snowflakedb/snowflake-actions@v3
        with:
          use-oidc: true
      - env:
          SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
        run: snow connection test -x
```

### Credential-based auth (fallback)

Use this only when [OIDC](#oidc-recommended) isn't available. You can either:

- Pass credentials as [environment variables](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-environment-variables-for-snowflake-credentials) and use `-x` so the CLI reads them without a `config.toml`.
- Define a connection in [`config.toml`](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#define-connections).

```yaml
# Option 1: env vars + temporary connection
- uses: snowflakedb/snowflake-actions@v3
- env:
    SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    # ...other SNOWFLAKE_* vars — see docs above
  run: snow connection test -x

# Option 2: config.toml
- uses: snowflakedb/snowflake-actions@v3
  with:
    default-config-file-path: ./config.toml
- run: snow connection test
```

## Version pinning

```yaml
- uses: snowflakedb/snowflake-actions@<sha>   # commit SHA (most secure)
- uses: snowflakedb/snowflake-actions@v3.0.0  # exact patch
- uses: snowflakedb/snowflake-actions@v3      # floating major
```

## Install from a branch, tag, or commit

Install the CLI from source (for example, to test an unreleased fix). `v2+`.

```yaml
- uses: snowflakedb/snowflake-actions@v3
  with:
    custom-github-ref: "feature/my-branch"   # branch, tag, or commit
```

## Platform support

Runs on Linux, macOS, and Windows GitHub-hosted runners.

## Security

- **Prefer OIDC** over long-lived secrets, and pin the action to a commit SHA.
- **Least-privilege permissions:** OIDC needs `id-token: write`; most jobs need only `contents: read`.
- **Set `persist-credentials: false`** on `actions/checkout`.
- **Never commit credentials.** Inject them via GitHub Secrets at runtime.

## Cortex Code CLI

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

**2. Alongside the Snowflake CLI** — from the root action in one step:

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

### How it works

1. Installs the Cortex Code CLI from the specified channel.
2. Pins a specific version if `cli-version` is set.
3. With `use-oidc: true`, mints a GitHub OIDC token (no Snowflake CLI needed). If a prior step already exported the token, it's reused.
4. Writes `connections.toml` (account, user, and workload-identity settings) so `cortex -c <name>` resolves. The OIDC token itself is read from the `SNOWFLAKE_TOKEN` environment variable at run time, not persisted to the file. If a connection with that name already exists, it skips (no overwrite).

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-channel` | `stable` | Install channel: `stable` or `beta`. |
| `cli-version` | `latest` | Version to install (e.g. `1.5.2`). Requires the version to be available in the channel. |
| `use-oidc` | `false` | Mint a GitHub OIDC token and write a workload-identity connection. Needs `id-token: write`. Leave `false` if a parent step already set the token. |
| `connection-name` | `default` | Connection name written to `connections.toml`. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var name holding the OIDC token. Must match the token env var set by `use-oidc` (or by a parent action). |

### Outputs

| Output | Description |
|--------|-------------|
| `cortex-version` | Installed Cortex Code CLI version string. |

### Example: Cortex Code agent workflow

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

      - run: cortex exec --file .cortex/prompts/scan.md -c default --bypass --no-history
```

### Platform support

Runs on Linux (ubuntu) GitHub-hosted runners. Requires Python 3.11+ on PATH (satisfied by all GitHub-hosted runners).

### Self-hosted runners

On self-hosted runners that persist between jobs, add a cleanup step to remove credentials:

```yaml
- name: Clean up credentials
  if: always()
  run: rm -f ~/.snowflake/connections.toml
```

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
