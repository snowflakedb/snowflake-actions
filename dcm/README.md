# Snowflake DCM GitHub Actions

> **Preview — Available to all accounts.** These actions are in Preview. Features and interfaces may change before general availability.

A set of **reusable composite GitHub Actions** for automating [Snowflake DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-overview) pipelines. Each action handles one step of the lifecycle, and you can compose them in your own workflows to build end-to-end CI/CD pipelines.

To use an action in your workflow, reference it with:

```yaml
- uses: snowflakedb/snowflake-actions/dcm/<action-name>@v3
```

## Actions

| Action | Description |
|--------|-------------|
| [`dcm-parse-manifest`](#dcm-parse-manifest) | Parse `manifest.yml` and output target names as a JSON array for matrix strategies |
| [`dcm-connection-test`](#dcm-connection-test) | Test Snowflake connectivity, validate role match, check project status |
| [`dcm-plan`](#dcm-plan) | Run `snow dcm plan`, summarize the changeset, upload artifacts |
| [`dcm-deploy`](#dcm-deploy) | Deploy with optional drop detection |

## Authentication

All actions authenticate to Snowflake using OIDC (OpenID Connect) via [`snowflakedb/snowflake-cli-action`](https://github.com/snowflakedb/snowflake-cli-action). Each action handles this internally — you do not need a separate authentication step in your workflow. OIDC uses GitHub's built-in identity tokens so no passwords or private keys are stored as secrets.

To set up OIDC:

1. Create a Snowflake service user with OIDC workload identity. The `SUBJECT` must match exactly what GitHub sends — case-sensitive, no wildcards. Since these actions use GitHub Environments, use the environment-based subject format:

   ```sql
   CREATE USER SVC_GITHUB_ACTIONS
     TYPE = SERVICE
     DEFAULT_ROLE = 'PUBLIC'
     COMMENT = 'GitHub Actions service user for CI/CD via OIDC'
     WORKLOAD_IDENTITY = (
       TYPE = OIDC
       ISSUER = 'https://token.actions.githubusercontent.com'
       SUBJECT = 'repo:<owner>/<repo>:environment:<env_name>'
     );
   ```

   Replace `<owner>/<repo>` with your GitHub repository and `<env_name>` with the GitHub Environment name (e.g. `DCM_STAGE`). If you have multiple environments, you will need a separate service user per environment or use [subject claim customization](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect#customizing-the-subject-claims).

2. Grant the service user the role specified as `project_owner` in your manifest:

   ```sql
   GRANT ROLE MY_DEPLOYER_ROLE TO USER SVC_GITHUB_ACTIONS;
   ```

3. Create a GitHub Environment for each DCM target (e.g. `DCM_STAGE`, `DCM_PROD_US`) — the environment name must match the `SUBJECT` claim
4. Set `SNOWFLAKE_USER` in the workflow `env` block to the service user name
5. Grant the workflow `id-token: write` and `contents: read` permissions (see [Prerequisites](#prerequisites) for the full block)

## Prerequisites

All actions require:

- A **GitHub Environment** matching the DCM target name (e.g. `DCM_STAGE`, `DCM_PROD_US`)
- **Workflow permissions**:

```yaml
permissions:
  id-token: write
  contents: read
```

When using `comment-on-pr: "true"` on `dcm-plan` or `dcm-deploy`, also add:

```yaml
permissions:
  id-token: write
  contents: read
  pull-requests: write
```

---

## Step summaries and PR comments

`dcm-plan` and `dcm-deploy` both write the captured CLI output to the GitHub Step
Summary, and post the same content as a pull request comment when
`comment-on-pr: "true"`. The two views are byte-identical; only the size limit
described below applies to the comment alone.

**What both views leave out.** The CLI renders per-step progress live, so in a
non-interactive log every step is printed twice: once as `Running...` while it is
in flight, and again as its completed or failed line. Only the transient repaint
is dropped. Completed and failed step lines, their detail lines and the uploaded
file tree are kept, as is any changeset row whose object text happens to mention
`Running...`. The raw Actions log is written straight from the CLI and keeps
everything, so step timings remain available when a step hangs.

**The changeset sits in a collapsible section**, whose summary line reads
`collapse/expand` to signal that it is interactive. The processing steps stay above
it and the closing totals line (`Planned 416 entities (...)` or `Deployed 2 entities
(...)`) below it, so the outcome is readable whether or not the section is expanded:

````markdown
### ✅ DCM Plan to DCM_DEV successful
```
❯ Step 1/4 - UPLOAD - ✓ Completed (1s)
❯ Step 4/4 - PLAN - ✓ Completed (2s)
```

<details open><summary>collapse/expand</summary>

```
🟨 ALTER    DATABASE    DCM_ENV_DEMO_VAR
└─ changed COMMENT: Build 5 → Build 6
```

</details>

```
Planned 2 entities (0 to create, 2 to alter, 0 to drop).
```
````

**Plan expands the section, deploy collapses it.** Both actions render the changeset
identically, including the colour coding. The plan output is where a reviewer reads
what will change, so its section is open on load. By the time the deploy output is
read those same rows have been reviewed already, so its section starts collapsed and
the outcome line leads. Either can be toggled by the reader.

Changeset rows are colour-coded so the change type is visible at a glance: 🟩 `CREATE`,
🟨 `ALTER`, 🟥 `DROP`. Emoji is used because GitHub strips HTML and CSS from comment
bodies. Output with no changeset rows, such as a failure before the plan ran or a plan
with no changes, is emitted as one flat block with no section.

**One comment per target and project.** Each comment carries a hidden marker built
from the action, the target and the project name, so a later run updates the
comment it wrote before instead of adding another. Plans and deploys, and different
targets or projects in the same pull request, keep separate comments.

**Size limit.** GitHub rejects comment bodies longer than 65536 characters, which a
plan of a few hundred entities can exceed. A body over the limit is truncated at a
line boundary, closing the changeset section if the cut landed inside it, with a
notice pointing at the run log and the uploaded artifact. This is the one difference
between the two views: the step summary is not subject to the limit and keeps the
full output.

---

## dcm-parse-manifest

Reads a DCM `manifest.yml` and outputs the list of target names as a JSON array, ready to feed into a GitHub Actions matrix strategy. This is useful for dynamically running jobs across all targets without hardcoding them.

```yaml
- uses: snowflakedb/snowflake-actions/dcm/parse-manifest@v3
  id: manifest
  with:
    project-path: my-dcm-project/
```

### Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `project-path` | yes | Path to the DCM project directory (containing `manifest.yml`) |

### Outputs

| Output | Description |
|--------|-------------|
| `targets` | JSON array of target names (e.g. `["DCM_STAGE","DCM_PROD_US"]`) |

### Example: Dynamic matrix strategy

```yaml
jobs:
  parse:
    runs-on: ubuntu-latest
    outputs:
      targets: ${{ steps.manifest.outputs.targets }}
    steps:
      - uses: actions/checkout@v7
      - uses: snowflakedb/snowflake-actions/dcm/parse-manifest@v3
        id: manifest
        with:
          project-path: my-dcm-project/

  deploy:
    needs: parse
    strategy:
      matrix:
        target: ${{ fromJson(needs.parse.outputs.targets) }}
    runs-on: ubuntu-latest
    environment: ${{ matrix.target }}
    steps:
      - uses: actions/checkout@v7
      # ... use other dcm actions with target: ${{ matrix.target }}
```

---

## dcm-connection-test

Tests the Snowflake connection for a target, validates that the connection role matches the manifest `project_owner`, and checks whether the DCM project already exists.

```yaml
- uses: snowflakedb/snowflake-actions/dcm/connection-test@v3
  with:
    target: DCM_STAGE
    project-path: my-dcm-project/
    snowflake-user: ${{ env.SNOWFLAKE_USER }}
```

### Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `target` | yes | DCM target name from `manifest.yml` |
| `project-path` | yes | Path to the DCM project directory |
| `snowflake-user` | yes | Snowflake username for authentication |

### Outputs

| Output | Description |
|--------|-------------|
| `result` | `success` or `failure` |
| `connection-account` | Snowflake account from the connection test |
| `connection-role` | Role used by the connection |
| `project-exists` | `true` or `false` |

---

## dcm-plan

Runs `snow dcm plan` against a target, writes the plan output to the GitHub Step Summary, and uploads the plan result as an artifact. See [Step summaries and PR comments](#step-summaries-and-pr-comments) for what the summary and the comment contain.

Setting `plan-delta: "true"` runs [`snow dcm plan --delta`](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-use#plan-only-changed-definitions-plan-delta), which evaluates only the definitions changed since the last deployment plus any definitions that depend on them. This is faster for incremental changes, but because it skips unchanged definitions it does not detect changes made outside DCM Projects since the last deployment. Run a full plan before deploying. When `plan-delta` is enabled, the summary includes a note that the plan was partial.

```yaml
- uses: snowflakedb/snowflake-actions/dcm/plan@v3
  with:
    target: DCM_STAGE
    project-path: my-dcm-project/
    snowflake-user: ${{ env.SNOWFLAKE_USER }}
    comment-on-pr: "true"
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `target` | yes | | DCM target name from `manifest.yml` |
| `project-path` | yes | | Path to the DCM project directory |
| `snowflake-user` | yes | | Snowflake username for authentication |
| `create-if-not-exists` | no | `true` | Run `snow dcm create --if-not-exists` before planning |
| `comment-on-pr` | no | `false` | Post the plan summary as a comment on the associated PR. See [Step summaries and PR comments](#step-summaries-and-pr-comments) |
| `plan-delta` | no | `false` | Run `snow dcm plan --delta` instead of a full plan |

### Outputs

| Output | Description |
|--------|-------------|
| `result` | `success` or `failure` |
| `plan-file` | Path to `plan_result.json` |

---

## dcm-deploy

Deploys the DCM project to a target. Optionally checks for destructive DROP operations before deploying.

The `dcm-plan` action **must** run before this action in the same job -- it produces the `out/plan_result.json` file used for drop detection.

⚠️ If the preceding `dcm-plan` step ran with `plan-delta: "true"`, the changeset in `plan_result.json` is partial and drop detection only covers the changed definitions and their dependents. Use a full plan when drop detection needs to be complete.

The deployment alias passed to `snow dcm deploy --alias` is set automatically to the source branch of the associated pull request (resolved from `pull_request` events directly, or via the merge commit on `push` events). When no PR branch can be found, no alias is passed.

The deploy output is written to the GitHub Step Summary and, when enabled, posted as a PR comment. See [Step summaries and PR comments](#step-summaries-and-pr-comments).

```yaml
- uses: snowflakedb/snowflake-actions/dcm/deploy@v3
  with:
    target: DCM_STAGE
    project-path: my-dcm-project/
    snowflake-user: ${{ env.SNOWFLAKE_USER }}
    allow-drops: "false"
    comment-on-pr: "true"
```

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `target` | yes | | DCM target name from `manifest.yml` |
| `project-path` | yes | | Path to the DCM project directory |
| `snowflake-user` | yes | | Snowflake username for authentication |
| `allow-drops` | no | `false` | Set to `true` to skip destructive drop detection |
| `comment-on-pr` | no | `false` | Post a deploy summary as a comment on the associated PR. See [Step summaries and PR comments](#step-summaries-and-pr-comments) |
| `post-scripts-path` | no | `""` | Relative path (from project-path) to a directory of `.sql` files to run after deploy. Files are executed alphabetically with Jinja templating using manifest variables. |

### Outputs

| Output | Description |
|--------|-------------|
| `deploy-result` | `success` or `failure` |

---

## Full Example Workflow

A complete STAGE + PROD pipeline with PR comments:

```yaml
name: DCM Deploy

on:
  push:
    branches: [main]
    paths: ['my-dcm-project/**']

env:
  DCM_PROJECT_PATH: my-dcm-project/
  SNOWFLAKE_USER: SVC_GITHUB_ACTIONS

jobs:
  # ---- STAGE ----
  stage:
    runs-on: ubuntu-latest
    environment: DCM_STAGE
    permissions:
      id-token: write
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v7

      - uses: snowflakedb/snowflake-actions/dcm/connection-test@v3
        with:
          target: DCM_STAGE
          project-path: ${{ env.DCM_PROJECT_PATH }}
          snowflake-user: ${{ env.SNOWFLAKE_USER }}

      - uses: snowflakedb/snowflake-actions/dcm/plan@v3
        with:
          target: DCM_STAGE
          project-path: ${{ env.DCM_PROJECT_PATH }}
          snowflake-user: ${{ env.SNOWFLAKE_USER }}
          comment-on-pr: "true"

      - uses: snowflakedb/snowflake-actions/dcm/deploy@v3
        with:
          target: DCM_STAGE
          project-path: ${{ env.DCM_PROJECT_PATH }}
          snowflake-user: ${{ env.SNOWFLAKE_USER }}
          comment-on-pr: "true"

  # ---- PROD ----
  prod:
    needs: stage
    runs-on: ubuntu-latest
    environment: DCM_PROD_US
    permissions:
      id-token: write
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v7

      - uses: snowflakedb/snowflake-actions/dcm/plan@v3
        with:
          target: DCM_PROD_US
          project-path: ${{ env.DCM_PROJECT_PATH }}
          snowflake-user: ${{ env.SNOWFLAKE_USER }}
          comment-on-pr: "true"

      - uses: snowflakedb/snowflake-actions/dcm/deploy@v3
        with:
          target: DCM_PROD_US
          project-path: ${{ env.DCM_PROJECT_PATH }}
          snowflake-user: ${{ env.SNOWFLAKE_USER }}
          comment-on-pr: "true"
```

