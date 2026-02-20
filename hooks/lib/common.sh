#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"

log() {
  echo "--- [git-automation] $*"
}

warn() {
  echo "+++ [git-automation] $*" >&2
}

fail() {
  echo "!!! [git-automation] $*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|on|ON|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "Required command not found: ${cmd}"
  fi
}

apply_defaults() {
  : "${BUILDKITE_PLUGIN_GIT_ENABLED:=true}"
  : "${BUILDKITE_PLUGIN_GIT_DEBUG:=false}"
  : "${BUILDKITE_PLUGIN_GIT_EXECUTE_PHASE:=post-command}"
  : "${BUILDKITE_PLUGIN_GIT_SKIP_ON_COMMAND_FAILURE:=true}"
  : "${BUILDKITE_PLUGIN_GIT_CLEANUP:=true}"

  : "${BUILDKITE_PLUGIN_GIT_AUTH_MODE:=ssh}"
  : "${BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_ENV:=GITHUB_TOKEN}"
  : "${BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_USER:=x-access-token}"

  : "${BUILDKITE_PLUGIN_GIT_BASE_BRANCH:=main}"

  : "${BUILDKITE_PLUGIN_GIT_PR_ENABLED:=true}"
  : "${BUILDKITE_PLUGIN_GIT_PR_UPDATE_EXISTING:=true}"

  : "${BUILDKITE_PLUGIN_GIT_SLACK_ENABLED:=false}"
  : "${BUILDKITE_PLUGIN_GIT_SLACK_NOTIFY_ON_NO_CHANGES:=false}"
  : "${BUILDKITE_PLUGIN_GIT_SLACK_FAIL_ON_ERROR:=false}"

  : "${BUILDKITE_PLUGIN_GIT_FAIL_ON_NO_CHANGES:=false}"
  : "${BUILDKITE_PLUGIN_GIT_COMMIT_SIGNOFF:=false}"
  : "${BUILDKITE_PLUGIN_GIT_COMMIT_GPG_SIGN:=false}"
  : "${BUILDKITE_PLUGIN_GIT_PUSH_FORCE_WITH_LEASE:=false}"

  export BUILDKITE_PLUGIN_GIT_ENABLED
  export BUILDKITE_PLUGIN_GIT_DEBUG
  export BUILDKITE_PLUGIN_GIT_EXECUTE_PHASE
  export BUILDKITE_PLUGIN_GIT_SKIP_ON_COMMAND_FAILURE
  export BUILDKITE_PLUGIN_GIT_CLEANUP
  export BUILDKITE_PLUGIN_GIT_AUTH_MODE
  export BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_ENV
  export BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_USER
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED
  export BUILDKITE_PLUGIN_GIT_PR_UPDATE_EXISTING
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED
  export BUILDKITE_PLUGIN_GIT_SLACK_NOTIFY_ON_NO_CHANGES
  export BUILDKITE_PLUGIN_GIT_SLACK_FAIL_ON_ERROR
  export BUILDKITE_PLUGIN_GIT_FAIL_ON_NO_CHANGES
  export BUILDKITE_PLUGIN_GIT_COMMIT_SIGNOFF
  export BUILDKITE_PLUGIN_GIT_COMMIT_GPG_SIGN
  export BUILDKITE_PLUGIN_GIT_PUSH_FORCE_WITH_LEASE
}

enable_debug_if_needed() {
  if is_true "${BUILDKITE_PLUGIN_GIT_DEBUG:-false}"; then
    set -x
  fi
}

parse_repo_slug() {
  local input="$1"

  input="${input%.git}"

  if [[ "$input" =~ ^git@[^:]+:(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$input" =~ ^ssh://git@[^/]+/(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$input" =~ ^https?://[^/]+/(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi

  printf '%s' "$input"
}

to_https_url() {
  local input="$1"

  input="${input%.git}"

  if [[ "$input" =~ ^https?:// ]]; then
    printf '%s' "$input"
    return
  fi

  if [[ "$input" =~ ^git@([^:]+):(.+)$ ]]; then
    printf 'https://%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return
  fi

  if [[ "$input" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    printf 'https://%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return
  fi

  if [[ "$input" == */* ]]; then
    printf 'https://github.com/%s' "$input"
    return
  fi

  printf '%s' "$input"
}

inject_token_url() {
  local url="$1"
  local token_user="$2"
  local token="$3"
  local https_url=""

  https_url=$(to_https_url "$url")
  printf '%s' "${https_url/https:\/\//https://${token_user}:${token}@}"
}

sanitize_branch_component() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:space:]' '-')"
  value="$(printf '%s' "$value" | tr -cd '[:alnum:]_./-')"
  value="$(printf '%s' "$value" | sed 's#//*#/#g')"
  value="${value#-}"
  value="${value%-}"

  printf '%s' "$value"
}

list_scalar_indexes() {
  local prefix="$1"
  env | sed -n "s/^${prefix}_\([0-9][0-9]*\)=.*/\1/p" | sort -n | uniq
}

list_object_indexes() {
  local prefix="$1"
  local field="$2"
  env | sed -n "s/^${prefix}_\([0-9][0-9]*\)_${field}=.*/\1/p" | sort -n | uniq
}

list_entry_indexes() {
  local prefix="$1"
  env | sed -n "s/^${prefix}_\([0-9][0-9]*\)_.*/\1/p" | sort -n | uniq
}

plugin_preset() {
  local preset="${BUILDKITE_PLUGIN_GIT_PRESET:-custom}"
  printf '%s' "$preset"
}

default_sync_type() {
  if [[ "$(plugin_preset)" == "helm-sync" ]]; then
    printf 'merge-yaml'
    return
  fi

  printf 'auto'
}

sync_uses_merge_yaml() {
  local idx=""
  local type_var=""
  local entry_type=""

  for idx in $(list_entry_indexes "${PLUGIN_PREFIX}SYNC"); do
    type_var="${PLUGIN_PREFIX}SYNC_${idx}_TYPE"
    entry_type="${!type_var:-$(default_sync_type)}"
    if [[ "$entry_type" == "merge-yaml" ]]; then
      return 0
    fi
  done

  return 1
}

has_artifact_downloads() {
  local count
  count="$(list_entry_indexes "${PLUGIN_PREFIX}ARTIFACT_DOWNLOAD" | wc -l | tr -d ' ')"
  [[ "$count" -gt 0 ]]
}

resolve_workspace_path() {
  local path="$1"
  local workspace="${SOURCE_WORKSPACE:-${BUILDKITE_BUILD_CHECKOUT_PATH:-$PWD}}"

  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
    return
  fi

  printf '%s/%s' "${workspace%/}" "$path"
}

resolve_source_path() {
  local path="$1"
  local workspace="${SOURCE_WORKSPACE:-${BUILDKITE_BUILD_CHECKOUT_PATH:-$PWD}}"

  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
    return
  fi

  if [[ -n "${SOURCE_DIRECTORY:-}" ]]; then
    printf '%s/%s' "${SOURCE_DIRECTORY%/}" "$path"
    return
  fi

  printf '%s/%s' "${workspace%/}" "$path"
}

run_indexed_commands() {
  local prefix="$1"
  local cwd="$2"
  local label="$3"
  local idx=""
  local var_name=""
  local cmd=""

  for idx in $(list_scalar_indexes "$prefix"); do
    var_name="${prefix}_${idx}"
    cmd="${!var_name:-}"

    if [[ -z "$cmd" ]]; then
      continue
    fi

    log "Running ${label} command #${idx}"
    (
      cd "$cwd" || exit 1
      bash -lc "$cmd"
    )
  done
}

ensure_safe_target_path() {
  local path="$1"

  if [[ -z "$path" ]]; then
    fail "sync.to cannot be empty"
  fi

  if [[ "$path" == /* ]]; then
    fail "sync.to must be repository-relative, got absolute path: $path"
  fi

  if [[ "$path" == ".." || "$path" == ../* || "$path" == */../* ]]; then
    fail "sync.to cannot escape repository root: $path"
  fi
}

download_configured_artifacts() {
  local idx=""
  local pattern_var=""
  local dest_var=""
  local step_var=""
  local pattern=""
  local dest=""
  local step=""
  local args=()

  if ! has_artifact_downloads; then
    return
  fi

  require_command buildkite-agent

  for idx in $(list_entry_indexes "${PLUGIN_PREFIX}ARTIFACT_DOWNLOAD"); do
    pattern_var="${PLUGIN_PREFIX}ARTIFACT_DOWNLOAD_${idx}_PATTERN"
    dest_var="${PLUGIN_PREFIX}ARTIFACT_DOWNLOAD_${idx}_DESTINATION"
    step_var="${PLUGIN_PREFIX}ARTIFACT_DOWNLOAD_${idx}_STEP"

    pattern="${!pattern_var:-}"
    dest="${!dest_var:-.}"
    step="${!step_var:-}"

    if [[ -z "$pattern" ]]; then
      fail "artifact-download entry #${idx} requires pattern"
    fi

    args=(artifact download "$pattern" "$(resolve_workspace_path "$dest")")
    if [[ -n "$step" ]]; then
      args+=(--step "$step")
    fi

    log "Downloading artifact pattern '${pattern}' to '${dest}'"
    buildkite-agent "${args[@]}"
  done
}
