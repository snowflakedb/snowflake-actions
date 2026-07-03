# Snowflake Actions

GitHub Action that installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) and/or the [Cortex Code CLI](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli) in a workflow, so you can deploy dbt, Streamlit, and DCM projects, ship Snowflake App Runtime apps, run SQL, run agentic Cortex Code tasks, and automate any Snowflake CLI task from CI/CD.

## Choosing an entry point

Copy the `uses:` line for the tool you want:

```yaml
uses: snowflakedb/snowflake-actions@v3               # Snowflake CLI (default), optionally + Cortex Code
uses: snowflakedb/snowflake-actions/snowflake-cli@v3 # Snowflake CLI only
uses: snowflakedb/snowflake-actions/cortex-code@v3   # Cortex Code CLI only — public preview
```

| Entry point | When to use it | Docs |
|-------------|----------------|------|
| `snowflakedb/snowflake-actions` | The Snowflake CLI (default), optionally plus Cortex Code | this page |
| `…/snowflake-cli` | Only the Snowflake CLI, explicitly | [Snowflake CLI action](snowflake-cli/README.md) |
| `…/cortex-code` | Only the Cortex Code CLI **(public preview)** | [Cortex Code CLI action](cortex-code/README.md) |

> [!NOTE]
> The Cortex Code CLI (`cortex`, and the `cortex-code` option here) is in **public preview**. Its inputs and behavior may change before general availability.

The root action installs the Snowflake CLI by default. Set `cortex-code: true` to also install Cortex Code, or `snowflake-cli: false` to skip the Snowflake CLI. The two subpath actions are leaf forms for callers who want one tool and nothing else; each configures OIDC on its own, so neither requires the other to run first.

## Quick start

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
> This example uses [OIDC](#authentication-oidc). Configure a Snowflake service user with a matching workload identity before you run it.

To also install Cortex Code, set `cortex-code: true` — see the [Cortex Code CLI action](cortex-code/README.md) for its inputs, outputs, and examples.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `snowflake-cli` | `true` | Install the Snowflake CLI (`snow`). |
| `cortex-code` | `false` | Also install the Cortex Code CLI (`cortex`). |
| `cli-version` | latest | Snowflake CLI version to install (e.g. `3.20.0`). |
| `use-oidc` | `false` | Authenticate with a GitHub OIDC token (applies to whichever CLIs are installed). |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is exported as. |
| `default-config-file-path` | `./config.toml` | Path to your `config.toml` (Snowflake CLI). |
| `custom-github-ref` | none | Install the Snowflake CLI from a branch, tag, or commit. See [Install from a branch, tag, or commit](snowflake-cli/README.md#install-from-a-branch-tag-or-commit). |
| `cortex-channel` | `stable` | Cortex Code install channel: `stable` or `beta`. |
| `cortex-version` | `latest` | Cortex Code version to install (e.g. `1.5.2`). |
| `connection-name` | `default` | Connection name written to `connections.toml` for Cortex Code. |
| `cortex-prompt` | none | Optional **inline** prompt string to run after Cortex Code setup. Mutually exclusive with `cortex-prompt-file`. Applies only when `cortex-code: true`. |
| `cortex-prompt-file` | none | Optional path to a **file** containing the prompt to run after Cortex Code setup. Mutually exclusive with `cortex-prompt`. Applies only when `cortex-code: true`. |
| `cortex-prompt-args` | none | Extra args appended to `cortex exec` when running `cortex-prompt`/`cortex-prompt-file` (e.g. `--max-turns 4 --output-format stream-json`). Space-separated. |

- `cli-version` and `custom-github-ref` are mutually exclusive.
- `use-oidc` needs Snowflake CLI `3.11+` and `id-token: write`.
- `default-config-file-path` is skipped if the file is absent.
- `cortex-*` and `connection-name` apply only when `cortex-code: true`. **The standalone [`cortex-code`](cortex-code/README.md) action names these `cli-channel` / `cli-version` / `prompt` / `prompt-file` / `prompt-args`** — unknown `with:` keys are silently ignored by GitHub Actions, so use the right name for your entry point.
- `cortex-code: true` is supported on Linux runners only (the Cortex Code CLI is Linux-only), even though the Snowflake CLI itself runs on Linux, macOS, and Windows.

## Outputs

| Output | Description |
|--------|-------------|
| `snowflake-cli-version` | Installed Snowflake CLI version. Empty when `snowflake-cli: false`. |
| `cortex-version` | Installed Cortex Code CLI version. Empty when `cortex-code` is not set. |

## Authentication (OIDC)

Use OIDC. It stores no secrets and is the only method we recommend; both the Snowflake CLI and Cortex Code use it. Credential-based auth exists only as a fallback for the Snowflake CLI — see [Credential-based auth](snowflake-cli/README.md#credential-based-auth-fallback).

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

## Version pinning

Pin the action reference itself:

```yaml
- uses: snowflakedb/snowflake-actions@<sha>   # commit SHA (most secure)
- uses: snowflakedb/snowflake-actions@v3.0.0  # exact patch
- uses: snowflakedb/snowflake-actions@v3      # floating major
```

To pin the *installed CLI* versions instead, use `cli-version` (Snowflake CLI) and `cortex-version` (Cortex Code).

## Security

- **Prefer OIDC** over long-lived secrets, and pin the action to a commit SHA.
- **Least-privilege permissions:** OIDC needs `id-token: write`; most jobs need only `contents: read`.
- **Set `persist-credentials: false`** on `actions/checkout`.
- **Never commit credentials.** Inject them via GitHub Secrets at runtime.
- **Self-hosted runners** that persist between jobs: remove any credentials the action wrote — see the cleanup notes in the [Snowflake CLI](snowflake-cli/README.md#self-hosted-runners) and [Cortex Code](cortex-code/README.md#self-hosted-runners) action docs.

## Platform support

The Snowflake CLI runs on Linux, macOS, and Windows GitHub-hosted runners. Cortex Code is Linux-only. See each action's docs for details.

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
