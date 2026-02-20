#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"

AUTO_WORKDIR="false"
CLEANUP_WORKDIR="true"

init_target_branch() {
  local branch_setting="${PLUGIN_PREFIX}BRANCH"
  local prefix_setting="${PLUGIN_PREFIX}BRANCH_PREFIX"
  local suffix_setting="${PLUGIN_PREFIX}BRANCH_SUFFIX"
  local remote_branch=""

  TARGET_BASE_BRANCH="${BUILDKITE_PLUGIN_GIT_BASE_BRANCH:-main}"

  if [[ -n "${!branch_setting:-}" ]]; then
    TARGET_BRANCH="${!branch_setting}"
    return
  fi

  remote_branch="$(sanitize_branch_component "${BUILDKITE_BRANCH:-source}")"
  TARGET_BRANCH="$(sanitize_branch_component "${!prefix_setting:-automation}-${!suffix_setting:-${remote_branch}-${BUILDKITE_BUILD_NUMBER:-local}}")"

  if [[ -z "$TARGET_BRANCH" ]]; then
    TARGET_BRANCH="automation-${BUILDKITE_BUILD_NUMBER:-local}"
  fi
}

create_temp_workspace() {
  local requested_path="${PLUGIN_PREFIX}CLONE_PATH"

  if [[ -n "${!requested_path:-}" ]]; then
    TARGET_WORKDIR="${!requested_path}"
    mkdir -p "$TARGET_WORKDIR"
    AUTO_WORKDIR="false"
    return
  fi

  TARGET_WORKDIR="$(mktemp -d /tmp/git-buildkite-plugin.XXXXXX)"
  AUTO_WORKDIR="true"
}

cleanup_workspace() {
  if ! is_true "${CLEANUP_WORKDIR:-true}"; then
    return
  fi

  if is_true "${AUTO_WORKDIR:-false}" && [[ -n "${TARGET_WORKDIR:-}" && -d "${TARGET_WORKDIR:-}" ]]; then
    rm -rf "$TARGET_WORKDIR"
  fi
}

prepare_repository_url_for_clone() {
  local auth_mode="${BUILDKITE_PLUGIN_GIT_AUTH_MODE:-ssh}"
  local token_env="${BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_ENV:-GITHUB_TOKEN}"
  local token_user="${BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_USER:-x-access-token}"
  local token="${!token_env:-}"

  if [[ "$auth_mode" != "https-token" ]]; then
    printf '%s' "$TARGET_REPOSITORY"
    return
  fi

  if [[ -z "$token" ]]; then
    fail "auth.mode is https-token but env var ${token_env} is not set"
  fi

  inject_token_url "$TARGET_REPOSITORY" "$token_user" "$token"
}

configure_git_user() {
  local user_name="${BUILDKITE_PLUGIN_GIT_USER_NAME:-}"
  local user_email="${BUILDKITE_PLUGIN_GIT_USER_EMAIL:-}"

  if [[ -n "$user_name" ]]; then
    git config --local user.name "$user_name"
  fi

  if [[ -n "$user_email" ]]; then
    git config --local user.email "$user_email"
  fi
}

clone_and_checkout() {
  local clone_url=""

  require_command git
  clone_url="$(prepare_repository_url_for_clone)"

  log "Cloning target repository"
  git clone "$clone_url" "$TARGET_WORKDIR"

  cd "$TARGET_WORKDIR" || return 1

  REMOTE_NAME="${BUILDKITE_PLUGIN_GIT_REMOTE:-origin}"

  if git ls-remote --exit-code --heads "$REMOTE_NAME" "$TARGET_BRANCH" >/dev/null 2>&1; then
    log "Checking out existing branch ${TARGET_BRANCH}"
    git fetch "$REMOTE_NAME" "$TARGET_BRANCH:$TARGET_BRANCH"
    git checkout "$TARGET_BRANCH"
  else
    git fetch "$REMOTE_NAME" "$TARGET_BASE_BRANCH" || true

    if git show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${TARGET_BASE_BRANCH}"; then
      git checkout -b "$TARGET_BRANCH" "refs/remotes/${REMOTE_NAME}/${TARGET_BASE_BRANCH}"
    elif git show-ref --verify --quiet "refs/heads/${TARGET_BASE_BRANCH}"; then
      git checkout -b "$TARGET_BRANCH" "$TARGET_BASE_BRANCH"
    else
      git checkout -b "$TARGET_BRANCH"
    fi
  fi

  configure_git_user
}

stage_changes() {
  local add_prefix="${PLUGIN_PREFIX}ADD"
  local add_count=0
  local idx=""
  local add_var=""
  local add_path=""

  for idx in $(list_scalar_indexes "$add_prefix"); do
    add_var="${add_prefix}_${idx}"
    add_path="${!add_var:-}"

    if [[ -z "$add_path" ]]; then
      continue
    fi

    git add -A "$add_path"
    add_count=$((add_count + 1))
  done

  if [[ "$add_count" -eq 0 ]]; then
    git add -A .
  fi
}

collect_change_summary() {
  local changed_files=""
  local summary=""

  changed_files="$(git diff --cached --name-only)"
  export GIT_AUTOMATION_CHANGED_FILES="$changed_files"

  if [[ -z "$changed_files" ]]; then
    export GIT_AUTOMATION_CHANGE_SUMMARY=""
    return
  fi

  summary="$(printf '%s\n' "$changed_files" | sed 's/^/- /')"
  export GIT_AUTOMATION_CHANGE_SUMMARY="$summary"
}

commit_changes() {
  local message="${BUILDKITE_PLUGIN_GIT_COMMIT_MESSAGE:-chore: automated update from Buildkite build #${BUILDKITE_BUILD_NUMBER:-unknown}}"
  local signoff="${BUILDKITE_PLUGIN_GIT_COMMIT_SIGNOFF:-false}"
  local gpg_sign="${BUILDKITE_PLUGIN_GIT_COMMIT_GPG_SIGN:-false}"
  local args=()

  message="$(render_template_inline "$message" "pr")"

  args=(commit -m "$message")
  if is_true "$signoff"; then
    args=(commit --signoff -m "$message")
  fi

  if is_true "$gpg_sign"; then
    if is_true "$signoff"; then
      args=(commit --signoff --gpg-sign -m "$message")
    else
      args=(commit --gpg-sign -m "$message")
    fi
  fi

  git "${args[@]}"
}

push_changes() {
  local auth_mode="${BUILDKITE_PLUGIN_GIT_AUTH_MODE:-ssh}"
  local token_env="${BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_ENV:-GITHUB_TOKEN}"
  local token_user="${BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_USER:-x-access-token}"
  local token="${!token_env:-}"
  local push_force="${BUILDKITE_PLUGIN_GIT_PUSH_FORCE_WITH_LEASE:-false}"

  if [[ "$auth_mode" == "https-token" ]]; then
    if [[ -z "$token" ]]; then
      fail "auth.mode is https-token but env var ${token_env} is not set"
    fi

    git remote set-url "$REMOTE_NAME" "$(inject_token_url "$(git remote get-url "$REMOTE_NAME")" "$token_user" "$token")"
  fi

  if is_true "$push_force"; then
    git push --force-with-lease "$REMOTE_NAME" "$TARGET_BRANCH"
  else
    git push "$REMOTE_NAME" "$TARGET_BRANCH"
  fi
}
