#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"
TEMPLATE_ARGS=()

load_template() {
  local template_file="$1"
  shift

  if [[ ! -f "$template_file" ]]; then
    echo "⚠️  Template file not found: $template_file" >&2
    return 1
  fi

  local content
  content=$(cat "$template_file")

  for arg in "$@"; do
    if [[ "$arg" == *"="* ]]; then
      local key
      local value
      key="${arg%%=*}"
      value="${arg#*=}"
      value=$(printf '%b' "$value")
      content="${content//\{\{${key}\}\}/$value}"
    fi
  done

  echo "$content"
}

get_template_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "${script_dir}/../../templates"
}

build_template_args() {
  local scope="$1"
  local key=""
  local value=""
  local source_commit="${BUILDKITE_COMMIT:-}"
  local source_commit_short=""
  local source_repo_slug=""
  local source_pr="${BUILDKITE_PULL_REQUEST:-}"
  local source_pr_url=""
  local source_commit_url=""
  local source_link=""

  source_commit_short="${source_commit:0:8}"
  source_repo_slug="$(parse_repo_slug "${BUILDKITE_REPO:-}")"

  if [[ -n "$source_pr" && "$source_pr" != "false" ]]; then
    source_pr_url="https://github.com/${source_repo_slug}/pull/${source_pr}"
    source_link="[PR #${source_pr}](${source_pr_url})"
  fi

  if [[ -n "$source_commit" ]]; then
    source_commit_url="https://github.com/${source_repo_slug}/commit/${source_commit}"
    if [[ -z "$source_link" ]]; then
      source_link="[${source_commit_short}](${source_commit_url})"
    fi
  fi

  TEMPLATE_ARGS=(
    "BUILD_ID=${BUILDKITE_BUILD_ID:-}"
    "BUILD_NUMBER=${BUILDKITE_BUILD_NUMBER:-}"
    "BUILD_URL=${BUILDKITE_BUILD_URL:-}"
    "PIPELINE_NAME=${BUILDKITE_PIPELINE_NAME:-}"
    "PIPELINE_SLUG=${BUILDKITE_PIPELINE_SLUG:-}"
    "BUILD_CREATOR=${BUILDKITE_BUILD_CREATOR:-}"
    "SOURCE_REPO_URL=${BUILDKITE_REPO:-}"
    "SOURCE_REPO=${source_repo_slug}"
    "SOURCE_BRANCH=${BUILDKITE_BRANCH:-}"
    "SOURCE_COMMIT=${source_commit}"
    "SOURCE_COMMIT_SHORT=${source_commit_short}"
    "SOURCE_COMMIT_FULL=${source_commit}"
    "SOURCE_PR_NUMBER=${source_pr}"
    "SOURCE_PR_URL=${source_pr_url}"
    "SOURCE_COMMIT_URL=${source_commit_url}"
    "SOURCE_LINK=${source_link}"
    "TARGET_REPOSITORY=${TARGET_REPOSITORY:-}"
    "TARGET_REPO=${TARGET_REPOSITORY_SLUG:-}"
    "TARGET_BASE_BRANCH=${TARGET_BASE_BRANCH:-}"
    "TARGET_BRANCH=${TARGET_BRANCH:-}"
    "TARGET_PR_URL=${TARGET_PR_URL:-}"
    "CHANGED_FILES=${GIT_AUTOMATION_CHANGED_FILES:-}"
    "CHANGE_SUMMARY=${GIT_AUTOMATION_CHANGE_SUMMARY:-}"
  )

  while IFS='=' read -r key value; do
    key="${key#"${PLUGIN_PREFIX}TEMPLATE_VARS_"}"
    TEMPLATE_ARGS+=("${key}=${value}")
  done < <(env | grep "^${PLUGIN_PREFIX}TEMPLATE_VARS_" || true)

  if [[ "$scope" == "pr" ]]; then
    while IFS='=' read -r key value; do
      key="${key#"${PLUGIN_PREFIX}PR_VARS_"}"
      TEMPLATE_ARGS+=("${key}=${value}")
    done < <(env | grep "^${PLUGIN_PREFIX}PR_VARS_" || true)
  fi

  if [[ "$scope" == "slack" ]]; then
    while IFS='=' read -r key value; do
      key="${key#"${PLUGIN_PREFIX}SLACK_VARS_"}"
      TEMPLATE_ARGS+=("${key}=${value}")
    done < <(env | grep "^${PLUGIN_PREFIX}SLACK_VARS_" || true)
  fi
}

render_template_file() {
  local template_file="$1"
  local scope="${2:-generic}"

  build_template_args "$scope"
  load_template "$template_file" "${TEMPLATE_ARGS[@]}"
}

render_template_inline() {
  local template_content="$1"
  local scope="${2:-generic}"
  local temp_file=""
  local rendered=""

  temp_file="$(mktemp)"
  printf '%s' "$template_content" > "$temp_file"
  rendered="$(render_template_file "$temp_file" "$scope")"
  rm -f "$temp_file"

  printf '%s' "$rendered"
}
