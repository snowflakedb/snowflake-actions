# Snowflake App Runtime GitHub Actions

> **Prototype.** These actions support **serverless** apps only
> (`compute_resource: SERVERLESS` in an `app.yml` with `version: 2`). Serverless
> compute is in Public Preview.

Composite actions for deploying [Snowflake App Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/about-snowflake-app-runtime)
apps from GitHub. Each one handles one step, and you combine them in your own workflows.

```yaml
- uses: snowflakedb/snowflake-actions/app/<action>@v3
```

| Action | What it does |
|---|---|
| [`app/preflight`](preflight/action.yml) | Checks the manifest, that the target and any existing service are serverless, and that `url_prefix` is free |
| [`app/package`](package/action.yml) | Uploads and builds a new version without touching the running app. Outputs `version` |
| [`app/promote`](promote/action.yml) | Deploys a version to a target. Outputs `url`, `live-version`, and `reverted` |
| [`app/preview`](preview/action.yml) | Deploys a pull request to its own app and comments the URL |
| [`app/cleanup`](cleanup/action.yml) | Removes a pull request's preview app |

Authentication uses OIDC through the root action, the same as the [DCM actions](../dcm/README.md#authentication).

## What a failed deploy looks like

A serverless deploy waits up to one minute for the app to pass its
[`health_check`](https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/app-yml#label-snowflake-app-runtime-app-yml-serverless-health-check)
(default `/`). If the new version doesn't pass in time, Snowflake keeps the previous version and the step fails. `app/promote` then:

- puts the CLI's error in the step summary, for example `app did not become healthy within 1m0s (probe=readiness path=/ port=8080)`;
- sets `reverted` to `true` and `live-version` to the version that stayed live.

Rerunning the failed job won't help. The failed build is still the newest version, so a rerun deploys it again. Fix the app and push, or promote a known-good version.

## Build once, promote the same version

The CLI always deploys the newest version, so a build that lands between your stage and prod deploys could reach prod untested. `app/package` records the version it created, and `app/promote` deploys exactly that version. Use a `concurrency` group so two builds of the same app can't overlap.

```yaml
name: Deploy app

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

concurrency:
  group: sar-${{ github.repository }}
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    environment: stage
    outputs:
      version: ${{ steps.build.outputs.version }}
    env:
      SNOWFLAKE_ACCOUNT: myorg-myaccount
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: snowflakedb/snowflake-actions/app/preflight@v3
        with:
          target: stage
      - uses: snowflakedb/snowflake-actions/app/package@v3
        id: build
        with:
          target: stage
      - uses: snowflakedb/snowflake-actions/app/promote@v3
        with:
          target: stage
          version: ${{ steps.build.outputs.version }}

  prod:
    needs: build
    runs-on: ubuntu-latest
    environment: prod # add required reviewers in the repository settings
    env:
      SNOWFLAKE_ACCOUNT: myorg-myaccount
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: snowflakedb/snowflake-actions/app/promote@v3
        with:
          target: prod
          version: ${{ needs.build.outputs.version }}
```

This assumes `stage` and `prod` share one artifact repository (set the same `artifact_repo` and `package_name` on both targets). Otherwise prod has no copy of the stage build.

When `version` isn't the newest version, `app/promote` runs `ALTER APPLICATION SERVICE ... UPGRADE TO VERSION`. That changes only the code version. Service settings from `app.yml`, such as environment variables and integrations, aren't reapplied on that path.

## Pull request previews

```yaml
name: Preview

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  preview:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    concurrency: sar-preview-${{ github.event.pull_request.number }}
    env:
      SNOWFLAKE_ACCOUNT: myorg-myaccount
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: snowflakedb/snowflake-actions/app/preview@v3
        with:
          database: APPS
          schema: PREVIEWS
          reviewer-role: APP_REVIEWERS

  cleanup:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    env:
      SNOWFLAKE_ACCOUNT: myorg-myaccount
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: snowflakedb/snowflake-actions/app/cleanup@v3
        with:
          database: APPS
          schema: PREVIEWS
```

Each PR gets the service `<NAME>_PR_<number>` with URL prefix `<prefix>-pr-<number>`. URL prefixes must be unique in the account and region. Previews can't go in a personal database (`USER$`), because other roles can't be granted access to apps there. A preview is billed for at least one idle hour after its last request.

## Limitations

- Managed compute pool apps and `snowflake.yml` projects aren't supported.
- Event-table metrics and lifecycle events aren't available for serverless apps, so there's no post-deploy health report beyond the health check.
- `app/package` finds the new version by reading the artifact repository after the build, because the CLI doesn't report it.
- The first serverless deploy in an account can wait up to three hours for a TLS certificate.
