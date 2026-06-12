# Snowflake Actions

GitHub Action that installs the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) and connects it to Snowflake — so you can deploy dbt, [DCM](https://docs.snowflake.com/en/developer-guide/snowflake-cli/dcm/overview), [Snowflake App Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/about-snowflake-app-runtime), and Streamlit projects, run SQL, and automate any Snowflake CLI task from CI/CD. The CLI runs in an isolated environment and writes your connection config to `~/.snowflake/` automatically.

## Quick start

```yaml
steps:
  - uses: snowflakedb/snowflake-actions@v2
  - run: snow --version
```

Connecting to Snowflake also needs auth — see [Authentication](#authentication). **Use OIDC.**

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-version` | latest | CLI version to install, e.g. `"3.20.0"`. Mutually exclusive with `custom-github-ref`. |
| `use-oidc` | `false` | Authenticate with GitHub's OIDC token — no stored secrets. Needs CLI `3.11+` and `id-token: write`. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is written to. Use `SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN` for a named connection. |
| `default-config-file-path` | `./config.toml` | `config.toml` to install into `~/.snowflake/`. Skipped if the file is absent. |
| `custom-github-ref` | — | Install from a branch/tag/commit of [`snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) instead of PyPI. Mutually exclusive with `cli-version`. `v2+`. |

## Compatibility

| Feature | Action | CLI |
|---------|--------|-----|
| Install a specific or latest CLI | `v1+` | any |
| OIDC authentication (`use-oidc`) | `v2+` | `3.11+` |
| Install from GitHub (`custom-github-ref`) | `v2+` | any |

## Authentication

Pick one. OIDC is recommended — it stores no secrets.

### OIDC (recommended)

**1. Create a service user in Snowflake.** See [Workload Identity Federation](https://docs.snowflake.com/en/user-guide/workload-identity-federation) for subject formats.

```sql
CREATE USER <username>
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (TYPE = OIDC ISSUER = 'https://token.actions.githubusercontent.com' SUBJECT = '<your_subject>');
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

### Key pair or password — named connection

Define a connection in `config.toml` (commit the template, never the secrets) and inject credentials as `SNOWFLAKE_CONNECTIONS_<NAME>_<KEY>` env vars.

```toml
# config.toml
default_connection_name = "myconnection"

[connections.myconnection]
```

```yaml
steps:
  - uses: actions/checkout@v4        # required to read config.toml from your repo
    with:
      persist-credentials: false
  - uses: snowflakedb/snowflake-actions@v2
    with:
      default-config-file-path: "config.toml"
  - env:
      SNOWFLAKE_CONNECTIONS_MYCONNECTION_AUTHENTICATOR: SNOWFLAKE_JWT
      SNOWFLAKE_CONNECTIONS_MYCONNECTION_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
      SNOWFLAKE_CONNECTIONS_MYCONNECTION_USER: ${{ secrets.SNOWFLAKE_USER }}
      SNOWFLAKE_CONNECTIONS_MYCONNECTION_PRIVATE_KEY_RAW: ${{ secrets.SNOWFLAKE_PRIVATE_KEY_RAW }}
    run: snow connection test
```

- **Encrypted key?** Add `PRIVATE_KEY_PASSPHRASE: ${{ secrets.PRIVATE_KEY_PASSPHRASE }}`.
- **Password instead?** Drop the `_AUTHENTICATOR` line, set `_PASSWORD`; with MFA, enable [MFA caching](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-multi-factor-authentication-mfa).
- First [generate a key pair](https://docs.snowflake.com/en/user-guide/key-pair-auth) and store credentials in [GitHub Secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions).

### Temporary connection

Skip the config file; pass credentials via generic `SNOWFLAKE_<KEY>` env vars with `-x`. Best for quick, one-off steps.

```yaml
steps:
  - uses: snowflakedb/snowflake-actions@v2
  - env:
      SNOWFLAKE_AUTHENTICATOR: SNOWFLAKE_JWT
      SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
      SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
      SNOWFLAKE_PRIVATE_KEY_RAW: ${{ secrets.SNOWFLAKE_PRIVATE_KEY_RAW }}
    run: snow connection test -x
```

> Full connection options and env-var precedence: [Configure Snowflake CLI connections](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections).

## Install from a branch or tag

```yaml
- uses: snowflakedb/snowflake-actions@v2
  with:
    custom-github-ref: "feature/my-branch"   # branch, tag, or commit
```

## Security

- **Pin to a commit SHA** (`@<sha>`) for supply-chain safety; `@v2` is convenient but mutable.
- **Prefer OIDC** over long-lived secrets.
- **Least-privilege permissions:** OIDC needs `id-token: write`; most jobs need only `contents: read`.
- **Set `persist-credentials: false`** on `actions/checkout`.
- **Never commit credentials** — keep `config.toml` secret-free and inject via GitHub Secrets.

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
