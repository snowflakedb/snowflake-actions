# Snowflake Actions

GitHub Action that installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) in a workflow, so you can deploy dbt and Streamlit projects, apply DCM changes, ship Snowflake App Runtime apps, run SQL, and automate any Snowflake CLI task from CI/CD.

## How it works

The action:

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
      # snow dbt deploy, snow streamlit deploy, snow sql -f migration.sql, etc.
```

This example uses [OIDC](#oidc-recommended). Configure a Snowflake service user with a matching workload identity before you run it.

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

### Key pair or password (fallback)

Use this only when OIDC isn't available. Store credentials in [GitHub Secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions) (first [generate a key pair](https://docs.snowflake.com/en/user-guide/key-pair-auth)) and pass them as `SNOWFLAKE_*` environment variables:

```yaml
steps:
  - uses: snowflakedb/snowflake-actions@v3
  - env:
      SNOWFLAKE_AUTHENTICATOR: SNOWFLAKE_JWT
      SNOWFLAKE_ACCOUNT: ${{ secrets.ACCOUNT }}
      SNOWFLAKE_USER: ${{ secrets.USER }}
      SNOWFLAKE_PRIVATE_KEY_RAW: ${{ secrets.PRIVATE_KEY }}
    run: snow connection test -x
```

> Set warehouse, database, role, etc. the same way: `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_ROLE`, `SNOWFLAKE_SCHEMA`.
>
> If your private key is encrypted, also set `PRIVATE_KEY_PASSPHRASE: ${{ secrets.PASSPHRASE }}`.
>
> To use a password instead (not recommended), drop `SNOWFLAKE_AUTHENTICATOR` and set `SNOWFLAKE_PASSWORD`.

See [Configure Snowflake CLI connections](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections) for all options.

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

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
