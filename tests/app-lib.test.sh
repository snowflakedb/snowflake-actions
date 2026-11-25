#!/usr/bin/env bash
#
# Offline tests for scripts/app-lib.sh: target resolution, the serverless-only
# check, repository defaults, and the per-PR preview rewrite.
#
# Usage: bash tests/app-lib.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/app-lib.sh
source "${REPO_ROOT}/scripts/app-lib.sh"

fail() { echo "FAIL: $1"; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
cd "$ROOT"
export GITHUB_STEP_SUMMARY="$ROOT/summary.md"

cat > app.yml <<'YAML'
version: 2
name: SALES
database: APPS
schema: PUBLIC
query_warehouse: WH
compute_resource: SERVERLESS
url_prefix: sales
default_target: dev
targets:
  dev:
    name: SALES_DEV
  prod:
    name: PROD_DB.APPS.SALES_PROD
    url_prefix: sales-prod
  managed:
    name: SALES_MANAGED
    compute_resource: MANAGED_COMPUTE_POOL
YAML

eq "$(app_resolve_target "")" "dev" "empty target uses default_target"
eq "$(app_resolve_target prod)" "prod" "explicit target wins"
eq "$(app_field dev url_prefix)" "sales" "unset field inherits the top level"
eq "$(app_field prod url_prefix)" "sales-prod" "target field overrides"
eq "$(app_service_fqn dev)" "APPS.PUBLIC.SALES_DEV" "bare name takes database and schema"
eq "$(app_service_fqn prod)" "PROD_DB.APPS.SALES_PROD" "dotted name wins"
eq "$(app_repo_and_package dev)" "APPS.PUBLIC.SALES_DEV_REPO	SALES_DEV" "default repository and package"

app_check_manifest dev || fail "a serverless target should pass"
: > "$GITHUB_STEP_SUMMARY"
if app_check_manifest managed; then fail "a managed target should be rejected"; fi
grep -q "serverless apps only" "$GITHUB_STEP_SUMMARY" || fail "the managed rejection should explain why"
if app_check_manifest nope; then fail "an unknown target should be rejected"; fi

printf 'version: 1\nname: X\n' > old.yml
if APP_MANIFEST=old.yml app_check_manifest ""; then fail "version 1 should be rejected"; fi
if APP_MANIFEST=missing.yml app_check_manifest ""; then fail "a missing manifest should be rejected"; fi

printf 'version: 2\nname: X\ndatabase: D\nschema: S\nartifact_repo: SHARED_REPO\npackage_name: PKG\ncompute_resource: serverless\n' > custom.yml
eq "$(APP_MANIFEST=custom.yml app_repo_and_package "")" "D.S.SHARED_REPO	PKG" "bare artifact_repo is qualified"
APP_MANIFEST=custom.yml app_check_manifest "" || fail "compute_resource is case-insensitive"

cp app.yml preview.yml
APP_MANIFEST=preview.yml app_apply_preview dev 42 PREVIEW_DB PREVIEWS
eq "$(APP_MANIFEST=preview.yml app_service_fqn "")" "PREVIEW_DB.PREVIEWS.SALES_DEV_PR_42" "preview service name"
eq "$(APP_MANIFEST=preview.yml app_field "" url_prefix)" "sales-pr-42" "preview url_prefix"
eq "$(yq eval 'has("targets")' preview.yml)" "false" "preview drops targets"
eq "$(yq eval '.query_warehouse' preview.yml)" "WH" "preview keeps other settings"

printf 'version: 2\nname: My_App\ndatabase: D\nschema: S\ncompute_resource: SERVERLESS\n' > noprefix.yml
APP_MANIFEST=noprefix.yml app_apply_preview "" 7 D S
eq "$(APP_MANIFEST=noprefix.yml app_field "" url_prefix)" "my-app-pr-7" "prefix derived from the name"

# app_summarize_failure_logs: stub `snow` to return each kind of answer.
export RUNNER_TEMP="$ROOT/rt"
mkdir -p "$RUNNER_TEMP"
snow() { printf '%s' "$SNOW_OUT"; return "${SNOW_CODE:-0}"; }

: > "$GITHUB_STEP_SUMMARY"
SNOW_OUT='[{"LOGS": "[{\"VALUE\": \"Traceback: boom\"}, {\"VALUE\": \"sh: python: not found\"}]"}]' \
  app_summarize_failure_logs "D.S.APP"
grep -q "sh: python: not found" "$GITHUB_STEP_SUMMARY" || fail "log lines should reach the summary"
grep -q "<details>" "$GITHUB_STEP_SUMMARY" || fail "logs should be collapsed"

: > "$GITHUB_STEP_SUMMARY"
SNOW_OUT='[{"LOGS": "[]"}]' app_summarize_failure_logs "D.S.APP"
grep -q "No log rows" "$GITHUB_STEP_SUMMARY" || fail "an empty result should say there are no rows yet"

: > "$GITHUB_STEP_SUMMARY"
SNOW_OUT='Schema does not exist or not authorized' SNOW_CODE=1 app_summarize_failure_logs "D.S.APP" \
  || fail "a permission error must not fail the step"
grep -q "can't read the account event table" "$GITHUB_STEP_SUMMARY" || fail "a permission error should name the missing access"
unset -f snow

# app_recover_after_revert: stub `snow`. DESCRIBE reports DESC_VERSION (default
# VERSION$1) with status DESC_STATUS. CLI_VERSION=1 makes the CLI support
# --promote-only --version; DEPLOY_FAILS=1 makes that redeploy fail;
# ALTER_FAILS=1 makes DISABLE/ENABLE fail. Calls are logged to $STATE.calls.
STATE="$ROOT/state"
snow() {
  local q="${*}"
  echo "$q" >> "$STATE.calls"
  case "$q" in
    *"DESCRIBE APPLICATION SERVICE"*)
      local status="${DESC_STATUS:-SUSPENDED}"
      [ -f "$STATE.enabled" ] && status=RUNNING
      printf '[{"status":"%s","source":"{\\"version\\":\\"%s\\"}"}]' "$status" "${DESC_VERSION:-VERSION\$1}" ;;
    *"--help"*) [ -n "${CLI_VERSION:-}" ] ;;
    "app deploy"*) [ -z "${DEPLOY_FAILS:-}" ] ;;
    *DISABLE*) [ -z "${ALTER_FAILS:-}" ] ;;
    *ENABLE*) [ -z "${ALTER_FAILS:-}" ] && touch "$STATE.enabled" ;;
  esac
}
export APP_RECOVER_POLLS=2 APP_RECOVER_POLL_SECS=0
ERR="$RUNNER_TEMP/sar-app-deploy.err"
reset() { rm -f "$STATE.enabled" "$STATE.calls"; touch "$STATE.calls"; }

# app_failed_health_check reads the CLI error, so it doesn't depend on which
# version DESCRIBE reports after the failure.
echo "some other deploy error" > "$ERR"
! app_failed_health_check || fail "an unrelated deploy error isn't a failed health check"
echo "094547 (55000): app did not become healthy within 1m0s" > "$ERR"
app_failed_health_check || fail "094547 is a failed health check"
rm -f "$ERR"
! app_failed_health_check || fail "no error file means no failed health check"

reset; echo "some other deploy error" > "$ERR"
eq "$(app_recover_after_revert D.S.APP 'VERSION$2' 'VERSION$1')" "not-needed" "no health-check failure, no recovery"

echo "094547 (55000): app did not become healthy within 1m0s" > "$ERR"
eq "$(app_recover_after_revert D.S.APP 'VERSION$2' '')" "not-needed" "a first deploy has nothing to go back to"
eq "$(app_recover_after_revert D.S.APP 'VERSION$1' 'VERSION$1')" "not-needed" "redeploying the same version has nothing to go back to"
eq "$(DESC_VERSION='VERSION$2' app_recover_after_revert D.S.APP 'VERSION$2' 'VERSION$1')" "not-needed" "never restart the failed version"
! grep -q -e DISABLE -e ENABLE -e "app deploy" "$STATE.calls" || fail "no recovery should run when it isn't needed"

for st in SUSPENDED UPGRADE_FAILED; do
  reset
  eq "$(DESC_STATUS=$st app_recover_after_revert D.S.APP 'VERSION$2' 'VERSION$1')" "recovered-sql" "DISABLE/ENABLE recovers whatever the status ($st)"
  [ -f "$STATE.enabled" ] || fail "recovery should run ENABLE ($st)"
done

reset
eq "$(CLI_VERSION=1 app_recover_after_revert D.S.APP 'VERSION$2' 'VERSION$1' prod)" "recovered-cli" "a CLI with --version redeploys the previous version"
grep -q -- 'app deploy --promote-only --version VERSION$1 --target prod' "$STATE.calls" || fail "the redeploy should pin the previous version and target"
! grep -q -e DISABLE -e ENABLE "$STATE.calls" || fail "the CLI path shouldn't run DISABLE/ENABLE"
eq "$(CLI_VERSION=1 DEPLOY_FAILS=1 app_recover_after_revert D.S.APP 'VERSION$2' 'VERSION$1')" "failed" "a failed redeploy is reported"
grep -q '094547' "$ERR" || fail "recovery must not overwrite the deploy's error output"

reset
eq "$(ALTER_FAILS=1 app_recover_after_revert D.S.APP 'VERSION$2' 'VERSION$1')" "failed" "a failed ALTER is reported"
unset -f snow

echo "PASS: app-lib"
