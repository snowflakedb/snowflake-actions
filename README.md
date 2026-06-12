# Snowflake Actions

GitHub Action that installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) in a workflow, so you can deploy dbt, [DCM](https://docs.snowflake.com/en/developer-guide/snowflake-cli/dcm/overview), [Snowflake App Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/about-snowflake-app-runtime), and Streamlit projects, run SQL, and automate any Snowflake CLI task from CI/CD.

## How it works

The action:

1. Installs Python 3.11 and the `uv` package manager.
2. Installs the Snowflake CLI in an isolated environment.
3. Copies your `config.toml` into `~/.snowflake/` if present (skipped with a notice if the file doesn't exist).
4. With `use-oidc: true`, fetches a GitHub OIDC token and sets the workload-identity environment variables.

## Quick start

```yaml
steps:
  - uses: snowflakedb/snowflake-actions@v2
  - run: snow --version
```

Connecting to Snowflake also needs auth. See [Authentication](#authentication); **use OIDC.**

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-version` | latest | CLI version to install (e.g. `3.20.0`). |
| `use-oidc` | `false` | Authenticate with a GitHub OIDC token. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is exported as. |
| `default-config-file-path` | `./config.toml` | Path to a `config.toml` to install. |
| `custom-github-ref` | none | Install the CLI from a branch, tag, or commit. |

- `cli-version` and `custom-github-ref` are mutually exclusive.
- `use-oidc` needs CLI `3.11+` and `id-token: write`; for a named connection set `oidc-token-name` to `SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN`.
- `custom-github-ref` installs from [`snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) instead of PyPI, and requires action `v2+`.
- `default-config-file-path` is skipped if the file is absent.

## Authentication

OIDC is the recommended method because it stores no secrets. Use key-pair or password authentication only when OIDC isn't an option.

### OIDC / workload identity federation (recommended)

GitHub issues a short-lived OIDC token that Snowflake validates directly, so no private keys are stored as secrets. Requires CLI `3.11+`.

**1. Create a service user in Snowflake.** See [Workload Identity Federation](https://docs.snowflake.com/en/user-guide/workload-identity-federation) for subject formats.

```sql
CREATE USER <username>
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = '<your_subject>'
  );
```

**2. Add the workflow.** `id-token: write` is required to mint the token.

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: snowflakedb/snowflake-actions@v2
        with:
          use-oidc: true
      - env:
          SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
        run: snow connection test -x
```

> For a named connection instead of a temporary one, set `oidc-token-name: SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN`.

### Key pair

Store credentials in [GitHub Secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions) (first [generate a key pair](https://docs.snowflake.com/en/user-guide/key-pair-auth)), then use either a named or a temporary connection.

**Named connection**: commit a `config.toml` template (never the secrets) and override fields with `SNOWFLAKE_CONNECTIONS_<NAME>_<KEY>` env vars:

```toml
# config.toml
default_connection_name = "dev"

[connections.dev]
```

```yaml
steps:
  - uses: actions/checkout@v4   # to read config.toml
    with:
      persist-credentials: false
  - uses: snowflakedb/snowflake-actions@v2
    with:
      default-config-file-path: "config.toml"
  - env:
      SNOWFLAKE_CONNECTIONS_DEV_AUTHENTICATOR: SNOWFLAKE_JWT
      SNOWFLAKE_CONNECTIONS_DEV_ACCOUNT: ${{ secrets.ACCOUNT }}
      SNOWFLAKE_CONNECTIONS_DEV_USER: ${{ secrets.USER }}
      SNOWFLAKE_CONNECTIONS_DEV_PRIVATE_KEY_RAW: ${{ secrets.PRIVATE_KEY }}
    run: snow connection test
```

**Temporary connection**: skip `config.toml`, pass credentials via generic `SNOWFLAKE_<KEY>` env vars with `-x`. Best for quick, one-off steps:

```yaml
steps:
  - uses: snowflakedb/snowflake-actions@v2
  - env:
      SNOWFLAKE_AUTHENTICATOR: SNOWFLAKE_JWT
      SNOWFLAKE_ACCOUNT: ${{ secrets.ACCOUNT }}
      SNOWFLAKE_USER: ${{ secrets.USER }}
      SNOWFLAKE_PRIVATE_KEY_RAW: ${{ secrets.PRIVATE_KEY }}
    run: snow connection test -x
```

> Encrypted key? Add `PRIVATE_KEY_PASSPHRASE: ${{ secrets.PASSPHRASE }}`.

### Password

Not recommended for production CI/CD. Drop the `AUTHENTICATOR` line from either key-pair example above and pass a password instead (`SNOWFLAKE_PASSWORD` or `SNOWFLAKE_CONNECTIONS_<NAME>_PASSWORD`). With MFA, enable [MFA caching](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-multi-factor-authentication-mfa).

> Full connection options and env-var precedence: [Configure Snowflake CLI connections](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections).

## Version pinning

```yaml
- uses: snowflakedb/snowflake-actions@<sha>   # commit SHA (most secure)
- uses: snowflakedb/snowflake-actions@v2.0.4  # exact patch
- uses: snowflakedb/snowflake-actions@v2      # floating major
```

## Install from a branch, tag, or commit

Install the CLI from source (for example, to test an unreleased fix). `v2+`.

```yaml
- uses: snowflakedb/snowflake-actions@v2
  with:
    custom-github-ref: "feature/my-branch"   # branch, tag, or commit
```

## Platform support

Runs on Linux, macOS, and Windows GitHub-hosted runners.

## Security

- **Prefer OIDC** over long-lived secrets, and pin the action to a commit SHA.
- **Least-privilege permissions:** OIDC needs `id-token: write`; most jobs need only `contents: read`.
- **Set `persist-credentials: false`** on `actions/checkout`.
- **Never commit credentials.** Keep `config.toml` secret-free and inject via GitHub Secrets.

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
