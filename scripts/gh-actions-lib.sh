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

# Write one line to $GITHUB_STEP_SUMMARY only, leaving the PR-comment copy out.
gha_summary_line_step_only() {
  printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# Arm the anchor filter for one command-output block.
#
# When GHA_COMMENT_ANCHOR_REGEX is set and the output file contains a line
# matching it, gha_summary_output_line sends every line before that first match
# to the step summary only. Progress and other preamble stay in the job summary
# and the Actions log while the PR comment starts at the payload. When no line
# matches, the filter stays off so nothing is dropped.
# Usage: gha_arm_anchor_filter <output-file>
gha_arm_anchor_filter() {
  local output_file="$1"
  _GHA_ANCHOR_ACTIVE=0
  _GHA_ANCHOR_SEEN=0
  if [ -n "${GHA_COMMENT_ANCHOR_REGEX:-}" ] && [ -s "$output_file" ]; then
    if grep -Eq "$GHA_COMMENT_ANCHOR_REGEX" "$output_file"; then
      _GHA_ANCHOR_ACTIVE=1
    fi
  fi
}

# Write one line of captured command output, honouring the anchor filter.
# Usage: gha_summary_output_line <text> [raw-line-for-matching]
# Pass the raw line when <text> carries a prefix (e.g. a status emoji) that would
# otherwise keep the anchor from matching.
gha_summary_output_line() {
  if [ "${_GHA_ANCHOR_ACTIVE:-0}" = "1" ] && [ "${_GHA_ANCHOR_SEEN:-0}" = "0" ]; then
    if [[ ${2-$1} =~ $GHA_COMMENT_ANCHOR_REGEX ]]; then
      _GHA_ANCHOR_SEEN=1
    else
      gha_summary_line_step_only "$1"
      return
    fi
  fi
  gha_summary_line "$1"
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
    gha_arm_anchor_filter "$output_file"
    while IFS= read -r line; do
      gha_summary_output_line "$line"
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
