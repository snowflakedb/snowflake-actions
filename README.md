# Snowflake Actions

GitHub Action that installs the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) in your CI/CD workflows and configures it to connect to Snowflake. Use it to deploy and manage Snowflake projects — dbt, [DCM Projects](https://docs.snowflake.com/en/developer-guide/snowflake-cli/dcm/overview), [Snowflake Apps Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/about-snowflake-app-runtime), and Streamlit apps — run SQL, and automate any other Snowflake CLI task directly from GitHub Actions.

The CLI is installed in an isolated environment, so it won't conflict with your project's dependencies, and the action sets up your connection configuration under `~/.snowflake/` automatically.

## Quick start

Install the latest CLI and run a command:

```yaml
steps:
  - uses: snowflakedb/snowflake-actions@v2
  - run: snow --version
```

To actually connect to Snowflake you also need to configure authentication — see [Authentication](#authentication). OIDC is the recommended method.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `cli-version` | No | latest | Snowflake CLI version to install, e.g. `"3.20.0"`. Omit (or use `"latest"`) to install the newest release. Cannot be combined with `custom-github-ref`. |
| `custom-github-ref` | No | — | Branch, tag, or commit in [`snowflakedb/snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) to install from, instead of PyPI (for example, to test an unreleased fix). Cannot be combined with `cli-version`. Requires action `v2+`. |
| `use-oidc` | No | `false` | Configure [WIF OIDC authentication](#oidc-recommended) using GitHub's OIDC token, so no private keys are stored as secrets. Requires CLI `3.11+` and the `id-token: write` workflow permission. |
| `oidc-token-name` | No | `SNOWFLAKE_TOKEN` | Environment variable the OIDC token is written to. Defaults to the variable used by [temporary connections](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-a-temporary-connection). Set to `SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN` to target a named connection. Only used when `use-oidc` is `true`. |
| `default-config-file-path` | No | `./config.toml` | Path (relative to the repo root) to a `config.toml` to install into `~/.snowflake/`. If the file doesn't exist, the step is skipped with a notice. Not required for temporary connections. |

> **Note:** `cli-version` and `custom-github-ref` cannot be used together. Specify only one.

## Compatibility

| Feature | Action version | Snowflake CLI version |
|---------|----------------|-----------------------|
| Install a specific or latest CLI | `v1+` | any |
| WIF OIDC authentication (`use-oidc`) | `v2+` | `3.11+` |
| Install from GitHub (`custom-github-ref`) | `v2+` | any |

## Authentication

### OIDC (recommended)

_Requires Snowflake CLI version `3.11` or above._

WIF OIDC authentication is the secure, modern way to authenticate with Snowflake — it uses GitHub's OIDC (OpenID Connect) token instead of storing private keys as secrets.

1. **Configure OIDC authentication in Snowflake.**

   Create a service user with an OIDC workload identity:

   ```sql
   CREATE USER <username>
   TYPE = SERVICE
   WORKLOAD_IDENTITY = (
     TYPE = OIDC
     ISSUER = 'https://token.actions.githubusercontent.com'
     SUBJECT = '<your_subject>'
   )
   ```

   - For examples, see [Example subject claims](https://docs.github.com/en/actions/reference/security/oidc#example-subject-claims) on GitHub.
   - For more on customizing the subject, see the [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc) on GitHub.
   - For end-to-end setup, see the Snowflake [Workload Identity Federation documentation](https://docs.snowflake.com/en/user-guide/workload-identity-federation).

2. **Store your Snowflake account identifier in [GitHub Secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository).**

3. **Configure the action with OIDC.** The `id-token: write` permission is required for the workflow to mint an OIDC token.

   ```yaml
   name: Snowflake OIDC
   on: [push]

   permissions:
     id-token: write  # Required for OIDC token generation
     contents: read

   jobs:
     oidc-job:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
           with:
             persist-credentials: false
         - name: Set up Snowflake CLI
           uses: snowflakedb/snowflake-actions@v2
           with:
             use-oidc: true             
         - name: Test connection
           env:
             SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
           run: snow connection test -x
   ```

   To use OIDC with a named connection rather than a temporary one, set `oidc-token-name` to `SNOWFLAKE_CONNECTIONS_<NAME>_TOKEN`.

### Key-pair or password authentication

If you can't use OIDC, you can authenticate with a key pair or a password. Both require these prerequisites:

1. **Generate a key pair** for your Snowflake account, following the [key-pair authentication guide](https://docs.snowflake.com/en/user-guide/key-pair-auth). (Skip if using a password.)

2. **Store credentials in [GitHub Secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository)** — account, private key, and passphrase (or password).

You then expose those secrets to the CLI as environment variables. The recommended approach is a named connection defined in a `config.toml`; for quick, one-off steps you can skip the file and use a temporary connection instead.

#### Configuration file (recommended)

Use a `config.toml` to define a named connection. Credentials are still supplied via secrets at runtime — never commit them.

1. **Add a `config.toml` to your repository** with an empty connection block as a template:

   ```toml
   default_connection_name = "myconnection"

   [connections.myconnection]
   ```

2. **Map secrets to environment variables** using the format `SNOWFLAKE_CONNECTIONS_<connection-name>_<key>=<value>`. These override the values in `config.toml`:

   ```yaml
   env:
     SNOWFLAKE_CONNECTIONS_MYCONNECTION_PRIVATE_KEY_RAW: ${{ secrets.SNOWFLAKE_PRIVATE_KEY_RAW }}
     SNOWFLAKE_CONNECTIONS_MYCONNECTION_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
   ```

3. **Point the action at your config file** with `default-config-file-path`:

   ```yaml
   - uses: snowflakedb/snowflake-actions@v2
     with:
       cli-version: "3.20.0"
       default-config-file-path: "config.toml"
   ```

4. **[Optional] Provide a passphrase if your private key is encrypted:**

   ```yaml
   - name: Execute Snowflake CLI command
     env:
       PRIVATE_KEY_PASSPHRASE: ${{ secrets.PRIVATE_KEY_PASSPHRASE }}
     run: |
       snow --version
       snow connection test
   ```

5. **[Alternative] Use a password instead of a key pair.** Don't set `SNOWFLAKE_CONNECTIONS_MYCONNECTION_AUTHENTICATOR` to `SNOWFLAKE_JWT`; instead provide a password:

   ```yaml
   env:
     SNOWFLAKE_CONNECTIONS_MYCONNECTION_USER: ${{ secrets.SNOWFLAKE_USER }}
     SNOWFLAKE_CONNECTIONS_MYCONNECTION_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
     SNOWFLAKE_CONNECTIONS_MYCONNECTION_PASSWORD: ${{ secrets.SNOWFLAKE_PASSWORD }}
   ```

   > **Note:** When using a password with MFA, configure [MFA caching](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-multi-factor-authentication-mfa) to avoid repeated prompts.

#### Temporary connection

For quick, one-off steps you can skip the config file and pass everything through generic `SNOWFLAKE_<KEY>` environment variables, using the temporary-connection flag (`-x`):

```yaml
- uses: snowflakedb/snowflake-actions@v2

- name: Execute Snowflake CLI command
  env:
    SNOWFLAKE_AUTHENTICATOR: SNOWFLAKE_JWT
    SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
    SNOWFLAKE_PRIVATE_KEY_RAW: ${{ secrets.SNOWFLAKE_PRIVATE_KEY_RAW }}
    PRIVATE_KEY_PASSPHRASE: ${{ secrets.PRIVATE_KEY_PASSPHRASE }} # Only if the private key is encrypted.
  run: snow connection test -x
```

To use a password instead of a key pair, omit `SNOWFLAKE_AUTHENTICATOR` and set `SNOWFLAKE_PASSWORD`. With password + MFA, enable [MFA caching](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections#use-multi-factor-authentication-mfa).

For full guidance on configuring and managing connections — including the precedence rules between command-line parameters, `SNOWFLAKE_CONNECTIONS_<NAME>_<KEY>` variables, config files, and generic `SNOWFLAKE_<KEY>` variables — see [Configure Snowflake CLI connections](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections). For defining environment variables in a workflow, see the [GitHub Actions documentation](https://docs.github.com/en/actions/learn-github-actions/variables#defining-environment-variables-for-a-single-workflow).

## Examples

### Configuration file

`config.toml`:

```toml
default_connection_name = "myconnection"

[connections.myconnection]
```

Workflow:

```yaml
name: deploy
on: [push]
jobs:
  version:
    name: "Check Snowflake CLI version"
    runs-on: ubuntu-latest
    steps:
      # Checkout is required to read a config file from your repo
      - name: Checkout repo
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      # Install the Snowflake CLI
      - uses: snowflakedb/snowflake-actions@v2
        with:
          default-config-file-path: "config.toml"

      # Use the CLI
      - name: Execute Snowflake CLI command
        env:
          SNOWFLAKE_CONNECTIONS_MYCONNECTION_AUTHENTICATOR: SNOWFLAKE_JWT
          SNOWFLAKE_CONNECTIONS_MYCONNECTION_USER: ${{ secrets.SNOWFLAKE_USER }}
          SNOWFLAKE_CONNECTIONS_MYCONNECTION_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
          SNOWFLAKE_CONNECTIONS_MYCONNECTION_PRIVATE_KEY_RAW: ${{ secrets.SNOWFLAKE_PRIVATE_KEY_RAW }}
          PRIVATE_KEY_PASSPHRASE: ${{ secrets.PRIVATE_KEY_PASSPHRASE }} # Only needed if the private key is encrypted.
        run: |
          snow --help
          snow connection test
```

### Temporary connection

```yaml
name: deploy
on: [push]

jobs:
  version:
    name: "Check Snowflake CLI version"
    runs-on: ubuntu-latest
    steps:
      # Install the Snowflake CLI
      - uses: snowflakedb/snowflake-actions@v2

      # Use the CLI
      - name: Execute Snowflake CLI command
        env:
          SNOWFLAKE_AUTHENTICATOR: SNOWFLAKE_JWT
          SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
          SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
          SNOWFLAKE_PRIVATE_KEY_RAW: ${{ secrets.SNOWFLAKE_PRIVATE_KEY_RAW }}
          PRIVATE_KEY_PASSPHRASE: ${{ secrets.PRIVATE_KEY_PASSPHRASE }} # Only needed if the private key is encrypted.
        run: |
          snow --help
          snow connection test -x
```

### Install from a GitHub branch or tag

To install the Snowflake CLI from a specific branch, tag, or commit (for example, to test unreleased features or a fork), use `custom-github-ref`. Available in action `v2+`:

```yaml
- uses: snowflakedb/snowflake-actions@v2
  with:
    custom-github-ref: "feature/my-branch"   # or a tag or commit hash
```

You can combine this with other inputs as needed.

## Security best practices

- **Pin the action to a commit SHA** for the strongest supply-chain guarantee, e.g. `uses: snowflakedb/snowflake-actions@<sha>`. A major tag like `@v2` is convenient but mutable.
- **Prefer OIDC** over long-lived secrets — it avoids storing private keys or passwords entirely.
- **Scope workflow permissions** to the minimum. OIDC needs `id-token: write`; most jobs need only `contents: read`.
- **Set `persist-credentials: false`** on `actions/checkout` so the checkout token isn't left in the runner's git config.
- **Never commit credentials.** Keep `config.toml` free of secrets and inject them via GitHub Secrets at runtime.

## Support

Please report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
