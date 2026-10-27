# Snowflake Actions

GitHub Action that installs and configures the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) in a workflow, so you can deploy dbt, Streamlit, and DCM projects, ship Snowflake App Runtime apps, run SQL, and automate any Snowflake CLI task from CI/CD.

## How it works

The action installs the Snowflake CLI in your workflow and can configure authentication, so later steps can run `snow` commands against Snowflake.

1. Installs `uv`, unless `snow` is already on `PATH` or `cli-artifact` points at a local wheel (those paths do not download `uv`).
2. Installs the Snowflake CLI with `uv tool install --python 3.11` into an isolated tool environment. The `snow` command is available in later steps. A preinstalled `snow` is reused when `cli-version` is left empty.
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
      - uses: actions/checkout@v7

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
| `cli-version` | (omitted) | CLI version to install (e.g. `3.20.0`). An omitted value is empty. Empty reuses a `snow` already on `PATH` and does not download. That reuse exports `SNOWFLAKE_CLI_AIR_GAPPED=true` for later steps, unless the variable is already set or an earlier step installed the CLI from the network. If `snow` is not on `PATH`, empty installs the latest release from PyPI. The string `latest` always installs from PyPI. |
| `use-oidc` | `false` | Authenticate with a GitHub OIDC token. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var the OIDC token is exported as. |
| `oidc-audience` | (omitted) | `aud` claim for the OIDC token. An omitted value is empty. Empty uses `SNOWFLAKE_AUDIENCE` when that is already set. Otherwise the action requests `snowflakecomputing.com`, unless `SNOWFLAKE_CLI_AIR_GAPPED` is true, in which case `oidc-audience` or `SNOWFLAKE_AUDIENCE` must be set. |
| `default-config-file-path` | `./config.toml` | Path to your `config.toml`. |
| `custom-github-ref` | none | Install the CLI from a branch, tag, or commit. |
| `cli-artifact` | none | Local wheel, sdist, or directory of wheels. Installed offline, and exports `SNOWFLAKE_CLI_AIR_GAPPED=true` for later steps unless that variable is already set. |
| `cortex-binary` | none | Local Cortex Code executable. Skips the release-archive download. The download is also skipped when `cortex` is already on `PATH`. A pinned `cortex-version` fails in both cases. |

- `cli-version`, `custom-github-ref`, and `cli-artifact` are mutually exclusive.
- `use-oidc` needs CLI `3.11+` and `id-token: write`.
- `custom-github-ref` installs from [`snowflake-cli`](https://github.com/snowflakedb/snowflake-cli) instead of PyPI, and requires action `v2+`.
- `default-config-file-path` is skipped if the file is absent.

## Air-gapped runners and AWS ISO

GitHub-hosted runners are unchanged: the action downloads `uv` and installs the CLI from PyPI.

On a runner with no route to `pypi.org`, `github.com`, or `sfc-repo.snowflakecomputing.com`:

- Preinstall `snow` on `PATH` and leave `cli-version`, `custom-github-ref`, and `cli-artifact` empty. The action reuses that binary and does not download `uv`. It exports `SNOWFLAKE_CLI_AIR_GAPPED=true` for later steps.
- Or set `cli-artifact` to a wheel, sdist, or a directory of wheels. `uv` and `python3` must already be on the runner. The install is `uv tool install --offline` and does not contact PyPI. Put dependency wheels next to the CLI wheel (or in that directory) so `--find-links` can resolve them. This path exports `SNOWFLAKE_CLI_AIR_GAPPED=true` as well.
- For Cortex Code, set `cortex-binary` to a local `cortex` executable, or preinstall `cortex` on `PATH` and leave `cortex-version` at `latest`. The action does not download a release archive. A `cortex-version` other than `latest` fails in both of those cases, because pinning reaches the network. `cortex-binary` cannot be combined with a pinned `cortex-version`. Setting root `cli-version` to `latest` still installs the Snowflake CLI from PyPI.

Either offline path exports `SNOWFLAKE_CLI_AIR_GAPPED=true` into the job environment, so later `snow` commands run air-gapped without a separate flag: no auto-upgrade, no public template download, and no commercial OIDC audience default. An explicit `SNOWFLAKE_CLI_AIR_GAPPED` is left unchanged, so set it to `false` to reuse a preinstalled binary without that mode. A CLI this job already installed from PyPI or GitHub is not flipped when a later step only reuses it.

An omitted `oidc-audience` stays empty. Empty uses `SNOWFLAKE_AUDIENCE` when the job already set it, and otherwise requests `snowflakecomputing.com`. With `SNOWFLAKE_CLI_AIR_GAPPED=true` — set by you, or exported by an offline setup above — that commercial default is refused: the step fails until `oidc-audience` or `SNOWFLAKE_AUDIENCE` is set to the audience on the Snowflake OIDC security integration. These packages have no governance-zone signal, so the audience is not rewritten automatically.

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

`@v3` tracks the latest 3.x.x release. Each release moves that tag, so `snowflakedb/snowflake-actions@v3` runs the new release with no workflow edit. The same tag covers this action, `cortex-code`, and the DCM actions.

```yaml
- uses: snowflakedb/snowflake-actions@<sha>   # commit SHA (most secure)
- uses: snowflakedb/snowflake-actions@v3.0.0  # exact patch
- uses: snowflakedb/snowflake-actions@v3      # latest 3.x.x
```

### Workflow dependency lockfiles

[Workflow dependency lockfiles](https://docs.github.com/en/actions/concepts/security/workflow-dependency-lockfiles) are a GitHub Actions public preview. A workflow that is not locked behaves as it does today: inputs and OIDC are unchanged, and `uses: snowflakedb/snowflake-actions@v3` still tracks new 3.x.x releases. You opt in by creating `.github/workflows/actions.lock` with [`gh actions-lock`](https://github.com/github/gh-actions-lock). If an admin requires a lockfile, a workflow without one fails until you create it.

Creating the lockfile stops `@v3` from tracking. The command rewrites `@v3` to the release it resolved, for example `@v3.3.2`, and records that commit. Later runs use the recorded commit, including actions this action calls, even after `@v3` moves. A newer 3.x.x release is used only when the lockfile is updated. If Dependabot manages GitHub Actions in your repository, it opens one pull request that bumps the version and updates the lockfile. Otherwise, change the `uses:` line and run `gh actions-lock` again.

The lockfile pins this action. It does not pin the Snowflake CLI installed from PyPI. An empty `cli-version`, or `latest`, still installs the current CLI on each run.

> [!NOTE]
> An allowlist entry for `snowflakedb/snowflake-actions@v3` does not match a locked workflow. GitHub checks the locked commit, not the tag. A tag entry cannot match that commit: the tag can move, and its history includes every earlier 3.x release. Allow `snowflakedb/snowflake-actions@*` or the full commit SHA. `@*` allows every ref in this repository, including a future major. An allowlist cannot say "only 3.x commits."

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

- **Prefer OIDC** over long-lived secrets, and pin the action to a commit SHA or a [workflow lockfile](#workflow-dependency-lockfiles).
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
2. Installs the channel's Cortex Code release archive and checks it against the release manifest, unless `cortex-binary` is set or `cortex` is already on `PATH`.
3. Pins a specific version when `cli-version` is not `latest` and Cortex was just downloaded. A published archive is installed from that archive. Otherwise the installed CLI updates to that version. Fails before either step when `cortex-binary` is set or `cortex` was already on `PATH`.
4. Auto-detects `SNOWFLAKE_TOKEN` in the environment (set by parent action's OIDC flow) and writes `connections.toml` so `cortex -c <name>` works. If a connection with that name already exists, it skips (no overwrite).

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `cli-channel` | `stable` | Install channel: `stable` or `beta`. |
| `cli-version` | `latest` | Version to install (e.g. `1.5.2`). Requires the version to be available in the channel. A value other than `latest` installs that version's release archive when one is published, and otherwise runs `cortex update`. It fails when `cortex-binary` is set or `cortex` is already on `PATH`. |
| `cortex-binary` | none | Local Cortex Code executable. Skips the release-archive download. The download is also skipped when `cortex` is already on `PATH`. Cannot be combined with a pinned `cli-version`. |
| `connection-name` | `default` | Connection name written to `connections.toml`. |
| `oidc-token-name` | `SNOWFLAKE_TOKEN` | Env var name containing the OIDC token. Must match parent action's `oidc-token-name` if overridden. |
| `oidc-audience` | (omitted) | `aud` claim when this action mints the OIDC token. An omitted value is empty. Empty uses `SNOWFLAKE_AUDIENCE` when that is already set, otherwise `snowflakecomputing.com`, unless `SNOWFLAKE_CLI_AIR_GAPPED` is true. |

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
      - uses: actions/checkout@v7

      - uses: snowflakedb/snowflake-actions@v3
        with:
          use-oidc: true

      - uses: snowflakedb/snowflake-actions/cortex-code@v3
        with:
          cli-channel: beta

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

---

## GitHub actions for DCM Projects

> **Public Preview** — Features and interfaces may change before general availability.

Four composite actions for automating [Snowflake DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-overview) CI/CD pipelines. Each action handles one step of the lifecycle; compose them to build end-to-end workflows.

| Action                                                     | Description                                                                                                                                                                      |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[dcm/parse-manifest](dcm/README.md#dcm-parse-manifest)`   | Parse `manifest.yml` and output target names as a JSON array for matrix strategies                                                                                               |
| `[dcm/connection-test](dcm/README.md#dcm-connection-test)` | Test Snowflake connectivity, validate that the connection role matches the manifest `project_owner`, and check whether the project already exists                                |
| `[dcm/plan](dcm/README.md#dcm-plan)`                       | Run `snow dcm plan`, write a color-coded changeset summary (🟩 CREATE 🟨 ALTER 🟥 DROP) to the Step Summary and optionally post it as a PR comment, and upload the plan artifact |
| `[dcm/deploy](dcm/README.md#dcm-deploy)`                   | Run `snow dcm plan` then `snow dcm deploy` with optional drop detection and post-deploy SQL scripts; optionally post a deploy summary as a PR comment                            |

```yaml
permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: DCM_STAGE
    env:
      SNOWFLAKE_USER: ${{ vars.SNOWFLAKE_USER }}
    steps:
      - uses: actions/checkout@v7

      - uses: snowflakedb/snowflake-actions/dcm/connection-test@v3
        with:
          target: DCM_STAGE
          project-path: my-dcm-project/
          snowflake-user: ${{ env.SNOWFLAKE_USER }}

      - uses: snowflakedb/snowflake-actions/dcm/plan@v3
        with:
          target: DCM_STAGE
          project-path: my-dcm-project/
          snowflake-user: ${{ env.SNOWFLAKE_USER }}
          comment-on-pr: "true"

      - uses: snowflakedb/snowflake-actions/dcm/deploy@v3
        with:
          target: DCM_STAGE
          project-path: my-dcm-project/
          snowflake-user: ${{ env.SNOWFLAKE_USER }}
          comment-on-pr: "true"
```

See the [DCM actions README](dcm/README.md) for full input/output references, authentication setup, and a complete multi-environment pipeline example.

---

## Support

Report issues or request features via [GitHub Issues](https://github.com/snowflakedb/snowflake-actions/issues).
