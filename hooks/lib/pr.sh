#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"

default_pr_body() {
  local template_file
  template_file="$(get_template_dir)/github/default-pr.md"
  render_template_file "$template_file" "pr"
}

# check_skip_existing_draft exits the hook early (exit 0) when a draft PR
# already exists for the current source PR. This prevents duplicate PRs and
# re-comments on the source PR when a PR build is retried.
check_skip_existing_draft() {
  local pr_enabled="${BUILDKITE_PLUGIN_GIT_PR_ENABLED:-true}"
  local pr_draft="${BUILDKITE_PLUGIN_GIT_PR_DRAFT:-false}"
  local skip_if_exists="${BUILDKITE_PLUGIN_GIT_PR_SKIP_IF_DRAFT_EXISTS:-false}"
  local pr_repo="${BUILDKITE_PLUGIN_GIT_PR_REPO:-$TARGET_REPOSITORY_SLUG}"
  local source_pr="${BUILDKITE_PULL_REQUEST:-}"
  local existing_pr=""

  if ! is_true "$pr_enabled" || ! is_true "$pr_draft" || ! is_true "$skip_if_exists"; then
    return 0
  fi

  if [[ -z "$source_pr" || "$source_pr" == "false" ]]; then
    return 0
  fi

  ensure_gh_installed

  existing_pr="$(gh pr list --repo "$pr_repo" --state open --head "$TARGET_BRANCH" --json number --jq '.[0].number // empty')"

  if [[ -n "$existing_pr" ]]; then
    log "Draft PR #${existing_pr} already exists for source PR #${source_pr}; skipping"
    exit 0
  fi
}

close_draft_prs() {
  local pr_repo="${BUILDKITE_PLUGIN_GIT_PR_REPO:-$TARGET_REPOSITORY_SLUG}"
  local branch_prefix="${BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX:-automation}"
  local source_repo
  local draft_prs=""
  local pr_num=""
  local branch_name=""
  local source_pr_number=""
  local source_pr_state=""
  local comment=""
  local close_template
  local close_without_merge_template
  local template_dir

  source_repo="$(parse_repo_slug "${BUILDKITE_REPO:-}")"
  template_dir="$(get_template_dir)"
  close_template="${template_dir}/github/pr-close-comment.md"
  close_without_merge_template="${template_dir}/github/pr-close-without-merge-comment.md"

  ensure_gh_installed

  draft_prs="$(gh pr list \
    --repo "$pr_repo" \
    --state open \
    --json isDraft,number,headRefName \
    --jq ".[] | select(.isDraft == true and (.headRefName | startswith(\"${branch_prefix}\"))) | \"\(.number):\(.headRefName)\"")"

  if [[ -z "$draft_prs" ]]; then
    log "No draft PRs found to close"
    return
  fi

  while IFS=':' read -r pr_num branch_name; do
    [[ -z "$pr_num" ]] && continue

    source_pr_number=""
    if [[ "$branch_name" =~ pr-([0-9]+) ]]; then
      source_pr_number="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$source_pr_number" && -n "$source_repo" ]]; then
      source_pr_state="$(gh pr view "$source_pr_number" --repo "$source_repo" --json state --jq '.state' 2>/dev/null || echo "")"

      if [[ "$source_pr_state" == "OPEN" ]]; then
        log "Source PR #${source_pr_number} is still open; keeping draft PR #${pr_num}"
        continue
      fi

      if [[ "$source_pr_state" == "MERGED" ]]; then
        comment="$(BUILDKITE_PULL_REQUEST="$source_pr_number" render_template_file "$close_template" "pr")"
      else
        comment="$(BUILDKITE_PULL_REQUEST="$source_pr_number" render_template_file "$close_without_merge_template" "pr")"
      fi
    else
      comment="$(render_template_file "$close_template" "pr")"
    fi

    gh pr comment "$pr_num" --repo "$pr_repo" --body "$comment"
    gh pr close "$pr_num" --repo "$pr_repo"
    gh api "repos/${pr_repo}/git/refs/heads/${branch_name}" --method DELETE 2>/dev/null \
      || warn "Could not delete branch ${branch_name} (may already be deleted)"
    log "Closed draft PR #${pr_num} (branch: ${branch_name})"
  done <<< "$draft_prs"
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

  if is_true "${BUILDKITE_PLUGIN_GIT_PR_CLOSE_DRAFTS:-false}"; then
    close_draft_prs
  fi

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
