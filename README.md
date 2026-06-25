# Snowflake Actions

GitHub Action that installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) in a workflow, so you can deploy dbt, Streamlit, and DCM projects, ship Snowflake App Runtime apps, run SQL, and automate any Snowflake CLI task from CI/CD.

## How it works

The action installs the Snowflake CLI in your workflow and can configure authentication, so later steps can run `snow` commands against Snowflake.

1. Installs `uv`.
2. Installs the Snowflake CLI with `uv tool install --python 3.11` into an isolated tool environment. The `snow` command is available in later steps.
3. Copies your `config.toml` to `~/.snowflake/` if present (skipped if the file doesn't exist).
4. With `use-oidc: true`, reads a GitHub OIDC token and sets the workload-identity environment variables the CLI expects.

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
| `cli-version` | latest | CLI version to install (e.g. `3.20.0`). |
| `use-oidc` | `false` | Authenticate with a GitHub OIDC token. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is exported as. |
| `default-config-file-path` | `./config.toml` | Path to your `config.toml`. |
| `custom-github-ref` | none | Install the CLI from a branch, tag, or commit. |

- `cli-version` and `custom-github-ref` are mutually exclusive.
- `use-oidc` needs CLI `3.11+` and `id-token: write`.
- `custom-github-ref` installs from [`snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) instead of PyPI, and requires action `v2+`.
- `default-config-file-path` is skipped if the file is absent.

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

## Cortex Code CLI action

A companion action that installs and configures the [Cortex Code CLI](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli) (`cortex`) for CI/CD workflows. Requires `snowflakedb/snowflake-actions@v3` to run first (provides `snow` CLI and OIDC auth).

```yaml
- uses: snowflakedb/snowflake-actions@v3
  with:
    use-oidc: true

- uses: snowflakedb/snowflake-actions/cortex-code@v3
```

### How it works

1. Verifies `snow` CLI is on PATH (fails fast if parent action wasn't used).
2. Installs CoCo CLI from the specified channel.
3. Pins a specific version if `cli-version` is set.
4. Auto-detects `SNOWFLAKE_TOKEN` in the environment (set by parent action's OIDC flow) and writes `connections.toml` so `cortex -c <name>` works. If a connection with that name already exists, it skips (no overwrite).

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-channel` | `stable` | Install channel: `stable` or `beta`. |
| `cli-version` | `latest` | Version to pin (e.g. `1.5.2`). Runs `cortex update <version>` after install. |
| `connection-name` | `default` | Connection name written to `connections.toml`. |

### Outputs

| Output | Description |
|--------|-------------|
| `cortex-version` | Installed CoCo CLI version string. |

### Example: CoCo agent workflow

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

      - uses: snowflakedb/snowflake-actions@v3
        with:
          use-oidc: true

      - uses: snowflakedb/snowflake-actions/cortex-code@v3
        with:
          cli-channel: beta

      - run: cortex exec --file .cortex/prompts/scan.md -c default --bypass --no-history
```

### Platform support

The Cortex Code CLI action supports Linux and macOS runners. Windows support is planned.

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
