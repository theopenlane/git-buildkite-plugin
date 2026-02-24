#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"

default_pr_body() {
  local template_file
  template_file="$(get_template_dir)/github/default-pr.md"
  render_template_file "$template_file" "pr"
}

create_or_update_pr() {
  local pr_enabled="${BUILDKITE_PLUGIN_GIT_PR_ENABLED:-true}"
  local pr_repo="${BUILDKITE_PLUGIN_GIT_PR_REPO:-$TARGET_REPOSITORY_SLUG}"
  local pr_base="${BUILDKITE_PLUGIN_GIT_PR_BASE:-$TARGET_BASE_BRANCH}"
  local pr_title="${BUILDKITE_PLUGIN_GIT_PR_TITLE:-Automated update from Buildkite build #${BUILDKITE_BUILD_NUMBER:-unknown}}"
  local pr_body="${BUILDKITE_PLUGIN_GIT_PR_BODY:-}"
  local pr_body_file="${BUILDKITE_PLUGIN_GIT_PR_BODY_FILE:-}"
  local pr_draft="${BUILDKITE_PLUGIN_GIT_PR_DRAFT:-false}"
  local pr_update_existing="${BUILDKITE_PLUGIN_GIT_PR_UPDATE_EXISTING:-true}"
  local existing_pr=""
  local pr_number=""
  local created_output=""
  local idx=""
  local var_name=""
  local value=""
  local args=()

  if ! is_true "$pr_enabled"; then
    log "PR creation disabled"
    return
  fi

  ensure_gh_installed

  if [[ -n "$pr_body_file" ]]; then
    pr_body="$(render_template_file "$(resolve_workspace_path "$pr_body_file")" "pr")"
  elif [[ -n "$pr_body" ]]; then
    pr_body="$(render_template_inline "$pr_body" "pr")"
  else
    pr_body="$(default_pr_body)"
  fi

  pr_title="$(render_template_inline "$pr_title" "pr")"

  existing_pr="$(gh pr list --repo "$pr_repo" --state open --head "$TARGET_BRANCH" --json number --jq '.[0].number // empty')"

  if [[ -n "$existing_pr" ]]; then
    TARGET_PR_URL="$(gh pr view "$existing_pr" --repo "$pr_repo" --json url --jq '.url')"
    if is_true "$pr_update_existing"; then
      gh pr edit "$existing_pr" --repo "$pr_repo" --title "$pr_title" --body "$pr_body"
      log "Updated existing PR #${existing_pr}"
    else
      log "Reusing existing PR #${existing_pr}"
    fi
    return
  fi

  args=(pr create --repo "$pr_repo" --base "$pr_base" --head "$TARGET_BRANCH" --title "$pr_title" --body "$pr_body")

  if is_true "$pr_draft"; then
    args+=(--draft)
  fi

  for idx in $(list_scalar_indexes "${PLUGIN_PREFIX}PR_LABELS"); do
    var_name="${PLUGIN_PREFIX}PR_LABELS_${idx}"
    value="${!var_name:-}"
    if [[ -n "$value" ]]; then
      args+=(--label "$value")
    fi
  done

  for idx in $(list_scalar_indexes "${PLUGIN_PREFIX}PR_REVIEWERS"); do
    var_name="${PLUGIN_PREFIX}PR_REVIEWERS_${idx}"
    value="${!var_name:-}"
    if [[ -n "$value" ]]; then
      args+=(--reviewer "$value")
    fi
  done

  for idx in $(list_scalar_indexes "${PLUGIN_PREFIX}PR_ASSIGNEES"); do
    var_name="${PLUGIN_PREFIX}PR_ASSIGNEES_${idx}"
    value="${!var_name:-}"
    if [[ -n "$value" ]]; then
      args+=(--assignee "$value")
    fi
  done

  created_output="$(gh "${args[@]}")"
  pr_number="$(echo "$created_output" | grep -Eo '[0-9]+$' | tail -1 || true)"

  if [[ -n "$pr_number" ]]; then
    TARGET_PR_URL="$(gh pr view "$pr_number" --repo "$pr_repo" --json url --jq '.url')"
  else
    TARGET_PR_URL="$(gh pr view "$TARGET_BRANCH" --repo "$pr_repo" --json url --jq '.url')"
  fi

  log "Created PR: ${TARGET_PR_URL}"
}

comment_on_source_pr_if_configured() {
  local enabled="${BUILDKITE_PLUGIN_GIT_PR_COMMENT_ON_SOURCE_PR:-false}"
  local source_repo="${BUILDKITE_PLUGIN_GIT_PR_SOURCE_REPO:-$(parse_repo_slug "${BUILDKITE_REPO:-}")}"
  local source_pr_number="${BUILDKITE_PLUGIN_GIT_PR_SOURCE_PR_NUMBER:-${BUILDKITE_PULL_REQUEST:-}}"
  local comment_body="${BUILDKITE_PLUGIN_GIT_PR_SOURCE_COMMENT:-}"
  local comment_file="${BUILDKITE_PLUGIN_GIT_PR_SOURCE_COMMENT_FILE:-}"

  if ! is_true "$enabled"; then
    return
  fi

  ensure_gh_installed

  if [[ -z "$TARGET_PR_URL" ]]; then
    warn "source PR comment requested but no target PR URL is available"
    return
  fi

  if [[ -z "$source_pr_number" || "$source_pr_number" == "false" ]]; then
    warn "source PR comment requested but source PR number is unavailable"
    return
  fi

  if [[ -n "$comment_file" ]]; then
    comment_body="$(render_template_file "$(resolve_workspace_path "$comment_file")" "pr")"
  fi

  if [[ -z "$comment_body" ]]; then
    comment_body="Automated downstream PR created: {{TARGET_PR_URL}}"
  fi

  comment_body="$(render_template_inline "$comment_body" "pr")"

  gh pr comment "$source_pr_number" --repo "$source_repo" --body "$comment_body"
  log "Commented on source PR #${source_pr_number}"
}
