#!/usr/bin/env bash
#
# Generic helpers for GitHub Actions composite actions. No project-specific
# assumptions — safe to source from any action.
#
# Source from a step's `run:` block:
#
#   . "$GITHUB_ACTION_PATH/../../scripts/gh-actions-lib.sh"
#
# The functions read from and write to the standard GitHub Actions files
# ($GITHUB_STEP_SUMMARY) via their env vars.

# Write one line to $GITHUB_STEP_SUMMARY and, when set, to $GHA_SUMMARY_FILE
# (a copy the caller can later post as a PR comment).
gha_summary_line() {
  printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${GHA_SUMMARY_FILE:-}" ]; then
    printf '%s\n' "$1" >> "$GHA_SUMMARY_FILE"
  fi
}

# Render a command-output summary block (status icon + header + fenced output)
# to the step summary and, when set, the PR-comment file.
#
# Usage: gha_emit_summary <success|failure> <header> <output-file>
gha_emit_summary() {
  local status="$1"
  local header="$2"
  local output_file="$3"

  if [ "$status" = "success" ]; then
    gha_summary_line "### ✅ ${header}"
  else
    gha_summary_line "### ❌ ${header}"
  fi

  gha_summary_line '```'
  if [ -s "$output_file" ]; then
    while IFS= read -r line; do
      gha_summary_line "$line"
    done < "$output_file"
  else
    gha_summary_line "No output captured. Check the Actions log for details."
  fi
  gha_summary_line '```'
}

# Write a value to a result file, creating the parent directory if needed.
# Usage: gha_write_result <file-path> <value>
gha_write_result() {
  local file_path="$1"
  local value="$2"
  mkdir -p "$(dirname "$file_path")"
  echo "$value" > "$file_path"
}
