#!/usr/bin/env bash
#
# Helpers for the Snowflake App Runtime (app/*) actions. These actions support
# serverless apps only: the resolved target must set compute_resource: SERVERLESS
# in an app.yml with version: 2.
#
# Source from a step's `run:` block:
#
#   . "$GITHUB_ACTION_PATH/../../scripts/app-lib.sh"
#
# Requires yq (mikefarah v4) and jq, which GitHub-hosted runners provide.

# shellcheck source=gh-actions-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/gh-actions-lib.sh"

APP_MANIFEST="${APP_MANIFEST:-app.yml}"

# Print one field of the resolved target: the target's value when it sets one,
# otherwise the top-level value. Prints an empty string when neither is set.
# Usage: app_field <target-or-empty> <field>
app_field() {
  local target="$1"
  local field="$2"
  local value=""
  if [ -n "$target" ]; then
    value="$(T="$target" F="$field" yq eval '.targets[strenv(T)][strenv(F)] // ""' "$APP_MANIFEST")"
  fi
  if [ -z "$value" ]; then
    value="$(F="$field" yq eval '.[strenv(F)] // ""' "$APP_MANIFEST")"
  fi
  printf '%s' "$value"
}

# Print the target the CLI will use: the explicit one, otherwise default_target.
# Usage: app_resolve_target <target-or-empty>
app_resolve_target() {
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    yq eval '.default_target // ""' "$APP_MANIFEST"
  fi
}

# Fail unless the manifest is app.yml v2 and the resolved target is serverless.
# Writes the reason to the step summary.
# Usage: app_check_manifest <target-or-empty>
app_check_manifest() {
  local target="$1"
  if [ ! -f "$APP_MANIFEST" ]; then
    gha_summary_line "### ❌ No ${APP_MANIFEST} found"
    gha_summary_line "These actions need an app.yml with version: 2. If the project uses snowflake.yml, migrate it first: https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/migrate-to-app-yml"
    return 1
  fi
  local version
  version="$(yq eval '.version // ""' "$APP_MANIFEST")"
  if [ "$version" != "2" ]; then
    gha_summary_line "### ❌ ${APP_MANIFEST} must set version: 2 (found '${version}')"
    return 1
  fi
  if [ -n "$target" ] && [ "$(T="$target" yq eval '.targets | has(strenv(T))' "$APP_MANIFEST")" != "true" ]; then
    gha_summary_line "### ❌ Target '${target}' is not defined in ${APP_MANIFEST}"
    return 1
  fi
  local compute
  compute="$(app_field "$target" compute_resource | tr '[:lower:]' '[:upper:]')"
  if [ "$compute" != "SERVERLESS" ]; then
    gha_summary_line "### ❌ This action supports serverless apps only"
    gha_summary_line "The resolved target has compute_resource '${compute:-MANAGED_COMPUTE_POOL (default)}'. Set compute_resource: SERVERLESS. An existing managed service can't be converted: deploy a new service. See https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/serverless"
    return 1
  fi
}

# Print the service's fully qualified name. A dotted name wins over database
# and schema. A USER$ database expands to the caller's personal database, as the
# CLI does; app/preflight warns about it because those apps can't be shared.
# Usage: app_service_fqn <target-or-empty>
app_service_fqn() {
  local name database schema
  name="$(app_field "$1" name)"
  if [[ "$name" == *.*.* ]]; then
    printf '%s' "$name"
    return
  fi
  database="$(app_field "$1" database)"
  schema="$(app_field "$1" schema)"
  if [ "$database" = 'USER$' ]; then
    database="USER\$$(snow sql -x --format JSON -q 'SELECT CURRENT_USER() AS U' | jq -r '.[0].U')"
  fi
  printf '%s.%s.%s' "$database" "$schema" "$name"
}

# Print the artifact repository FQN and package name, tab-separated, using the
# CLI defaults: <NAME>_REPO next to the service, and package = bare name.
# Usage: app_repo_and_package <target-or-empty>
app_repo_and_package() {
  local fqn repo package
  fqn="$(app_service_fqn "$1")"
  repo="$(app_field "$1" artifact_repo)"
  package="$(app_field "$1" package_name)"
  [ -n "$package" ] || package="${fqn##*.}"
  if [ -z "$repo" ]; then
    repo="${fqn}_REPO"
  elif [[ "$repo" != *.*.* ]]; then
    repo="${fqn%.*}.${repo}"
  fi
  printf '%s\t%s\n' "$repo" "$package"
}

# Print the newest version in the repository, or nothing when there is none.
# The CLI does not report the version a build creates, so this reads it back
# right after the build. Callers serialize builds with a concurrency group.
# Usage: app_latest_version <repo-fqn> <package>
app_latest_version() {
  snow sql -x --format JSON \
    -q "SHOW VERSIONS IN ARTIFACT REPOSITORY $1 FOR PACKAGE $2" 2>/dev/null \
    | jq -r 'map(select(.version | startswith("VERSION$")))
             | sort_by(.version | ltrimstr("VERSION$") | tonumber)
             | last | .version // empty'
}

# Print one DESCRIBE APPLICATION SERVICE column, or nothing when the service
# does not exist. For source fields, use app_live_version.
# Usage: app_describe_field <service-fqn> <column>
app_describe_field() {
  snow sql -x --format JSON -q "DESCRIBE APPLICATION SERVICE $1" 2>/dev/null \
    | C="$2" jq -r '.[0][env.C] // empty'
}

# Print the version the service is running now.
# Usage: app_live_version <service-fqn>
app_live_version() {
  app_describe_field "$1" source | jq -r '.version // empty' 2>/dev/null
}

# Rewrite the manifest in place so a PR gets its own service and URL.
# Service names and URL prefixes must be unique, and a prefix collision only
# fails after upload and build, so both carry the PR number.
# Usage: app_apply_preview <target-or-empty> <pr-number> <database> <schema>
app_apply_preview() {
  local target="$1" pr="$2" database="$3" schema="$4"
  local base_name base_prefix
  base_name="$(app_field "$target" name)"
  base_name="${base_name##*.}"
  base_prefix="$(app_field "$target" url_prefix)"
  [ -n "$base_prefix" ] || base_prefix="$(printf '%s' "$base_name" | tr '[:upper:]_' '[:lower:]-')"
  N="$(printf '%s_PR_%s' "$base_name" "$pr" | tr '[:lower:]' '[:upper:]')" \
  P="${base_prefix}-pr-${pr}" D="$database" S="$schema" \
    yq eval -i '
      del(.targets) | del(.default_target)
      | .name = strenv(N) | .url_prefix = strenv(P)
      | .database = strenv(D) | .schema = strenv(S)
      | .compute_resource = "SERVERLESS"' "$APP_MANIFEST"
}

# Run `snow app deploy` with the given flags and record the result. On success
# the CLI prints {"message": "App ready at <url>"}. On failure stdout is empty
# and the reason (for example a failed health check) is only on stderr, so both
# streams go to the summary. Returns the CLI's exit code.
# Usage: app_run_deploy <header> [snow app deploy flags...]
app_run_deploy() {
  local header="$1"
  shift
  local out="${RUNNER_TEMP:-/tmp}/sar-app-deploy.out"
  local err="${RUNNER_TEMP:-/tmp}/sar-app-deploy.err"
  local code=0
  snow app deploy "$@" -x --format JSON > "$out" 2> "$err" || code=$?
  cat "$out" "$err" > "${out}.all"
  if [ "$code" -eq 0 ]; then
    gha_emit_summary success "$header" "${out}.all"
  else
    gha_emit_summary failure "$header" "${out}.all"
    if grep -q 'did not become healthy' "$err"; then
      gha_summary_line "The new version failed its health check, so Snowflake kept the previous version. A rerun deploys the same build again; fix the app or pin a known-good version with app/promote."
    fi
  fi
  return "$code"
}

# Print a field from the JSON the last app_run_deploy printed, or nothing.
# CLIs with snowflake-eng/snowflake-cli#681 add version, live_version and url;
# older ones print only {"message": ...}.
# Usage: app_deploy_json_field <field>
app_deploy_json_field() {
  local out="${RUNNER_TEMP:-/tmp}/sar-app-deploy.out"
  [ -s "$out" ] || return 0
  F="$1" jq -r '.[env.F] // empty' "$out" 2>/dev/null || true
}

# Succeed when this CLI accepts `snow app deploy --promote-only --version`
# (snowflake-eng/snowflake-cli#681). Probe it with --help: an older CLI rejects
# the unknown option with exit code 2.
app_cli_supports_version() {
  snow app deploy --promote-only --version 'VERSION$1' --help > /dev/null 2>&1
}

# Copy the project to a scratch directory so manifest edits never touch the
# checkout. Prints the destination.
# Usage: app_copy_project <project-path>
app_copy_project() {
  local src dest
  if [ ! -d "$1" ]; then
    echo "::error::project-path is not a directory: $1" >&2
    return 1
  fi
  src="$(cd "$1" && pwd -P)"
  dest="${RUNNER_TEMP:-/tmp}/sar-app-project"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$src"/. "$dest"/
  printf '%s' "$dest"
}
