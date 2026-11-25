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
(default `/`). If the new version doesn't pass in time, the deploy fails and the new version doesn't take effect. Snowflake doesn't restart the previous version: the app stays offline until a deploy passes its health check. `app/promote` then:

- puts the CLI's error in the step summary, for example `app did not become healthy within 1m0s (probe=readiness path=/ port=8080)`;
- sets `reverted` to `true`. It reads this from the CLI's error, not from `DESCRIBE APPLICATION SERVICE`. DESCRIBE still reports the previous version, because Snowflake records a version only once it deploys.

Rerunning the failed job won't help. The failed build is still the newest version, so a rerun deploys it again. Fix the app and push, or promote a known-good version.

### Recovering after a failed health check

After a failed health check, the app is left stopped, and requests return `503 app not available` instead of starting it. Snowflake engineering confirmed this is intended: the app stays offline until the next successful deploy. In testing, it stayed offline for at least 13 minutes.

To bring it back, deploy a fixed version, or promote the last version that passed. With a Snowflake CLI that supports `--promote-only --version` ([snowflake-cli#681](https://github.com/snowflake-eng/snowflake-cli/pull/681)), `snow app deploy --promote-only --version <previous>` restarted the app in about 17 seconds. `ALTER APPLICATION SERVICE ... UPGRADE TO VERSION <previous>` doesn't work in this state: Snowflake reports the service is already at that version.

`app/promote` does this by default, so a bad build doesn't leave the app offline. When its deploy fails the health check and `DESCRIBE` still reports the version from before the deploy, it starts that version again:

- With a CLI that supports `--promote-only --version`, it runs `snow app deploy --promote-only --version <previous>`. `CREATE OR ALTER` re-applies the whole service, which clears the failed state.
- Otherwise it runs `DISABLE` and then `ENABLE`, which recreates the app from the version Snowflake has recorded, and waits for it to run. That takes about 10 seconds and needs `OPERATE` on the service, which a role that can deploy already has.

The step still fails, the summary says which version is serving, and the `recovered` output is `true`. The check doesn't depend on DESCRIBE's `status`, which reads `SUSPENDED` or `UPGRADE_FAILED` depending on the Snowflake release.

To leave the app offline instead, set `recover-after-revert: "false"`. Do that when a new version changes data before it passes its health check, for example by running a migration on startup, and the previous version can't run against the changed data. If recovery is off or fails, the summary shows the commands to run by hand.

After a failed deploy, `app/promote` tries once to add the app's recent logs from the event table to the step summary. A serverless app that failed its health check is stopped, so live logs aren't available, and reading the event table needs a role with access to the account event table: `MONITOR` on the app isn't enough. Without that access, the summary says the logs couldn't be read, and the CLI error line is the only diagnostic.

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

When `version` is set, `app/promote` checks whether the installed Snowflake CLI supports `snow app deploy --promote-only --version` (added in [snowflake-cli#681](https://github.com/snowflake-eng/snowflake-cli/pull/681), not yet released):

- **Supported:** it promotes that exact version through the CLI. Service settings from `app.yml` are applied, and this also works when the service doesn't exist yet.
- **Older CLI:** the newest version goes through `--promote-only`. An older version goes through `ALTER APPLICATION SERVICE ... UPGRADE TO VERSION`, which changes only the code version and can't create a service. Service settings such as environment variables and integrations aren't reapplied on that path.

`app/package` reads the version from the build's JSON output when the CLI reports it, and otherwise from the artifact repository.

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
- With a CLI older than snowflake-cli#681, `app/package` finds the new version by reading the artifact repository after the build.
- The first serverless deploy in an account can wait up to three hours for a TLS certificate.
