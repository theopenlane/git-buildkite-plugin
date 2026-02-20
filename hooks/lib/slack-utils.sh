#!/usr/bin/env bash

send_slack_notification_from_template() {
  local template_file="$1"
  shift

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "ℹ️  Slack not configured (SLACK_WEBHOOK_URL missing), skipping notification"
    return 0
  fi

  if [[ ! -f "$template_file" ]]; then
    echo "⚠️  Slack template file not found: $template_file"
    return 1
  fi

  echo "📨 Sending slack notification from template: $(basename "$template_file")"

  local message_content
  message_content=$(cat "$template_file")

  for arg in "$@"; do
    if [[ "$arg" == *"="* ]]; then
      local key
      local value
      key="${arg%%=*}"
      value="${arg#*=}"
      value=$(echo "$value" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
      message_content="${message_content//\{\{${key}\}\}/$value}"
    fi
  done

  local json_response
  if json_response=$(curl -sL -X POST -H "Content-Type: application/json" -d "$message_content" "${SLACK_WEBHOOK_URL}"); then
    echo "✅ Slack notification sent successfully"
    return 0
  fi

  echo "⚠️  Failed to send slack notification"
  echo "Response: $json_response"
  return 1
}

format_summary() {
  local summary="$1"
  printf "%b" "$summary" | sed 's/\\n/\n/g'
}

send_slack_notification() {
  local enabled="${BUILDKITE_PLUGIN_GIT_SLACK_ENABLED:-false}"
  local webhook_env="${BUILDKITE_PLUGIN_GIT_SLACK_WEBHOOK_ENV:-SLACK_WEBHOOK_URL}"
  local webhook="${!webhook_env:-}"
  local configured_template_file="${BUILDKITE_PLUGIN_GIT_SLACK_TEMPLATE_FILE:-}"
  local template_inline="${BUILDKITE_PLUGIN_GIT_SLACK_TEMPLATE_INLINE:-}"
  local fail_on_error="${BUILDKITE_PLUGIN_GIT_SLACK_FAIL_ON_ERROR:-false}"
  local template_file=""
  local temp_inline_file=""
  local formatted_summary=""

  if ! is_true "$enabled"; then
    return
  fi

  if [[ -z "$webhook" ]]; then
    warn "Slack enabled but webhook env var ${webhook_env} is not set"
    if is_true "$fail_on_error"; then
      fail "Slack webhook is required"
    fi
    return
  fi

  require_command curl

  export SLACK_WEBHOOK_URL="$webhook"

  if [[ -n "$template_inline" ]]; then
    temp_inline_file="$(mktemp)"
    printf '%s' "$template_inline" > "$temp_inline_file"
    template_file="$temp_inline_file"
  elif [[ -n "$configured_template_file" ]]; then
    template_file="$(resolve_workspace_path "$configured_template_file")"
  else
    template_file="$(get_template_dir)/slack/default-notification.json"
  fi

  build_template_args "slack"
  formatted_summary="$(format_summary "${GIT_AUTOMATION_CHANGE_SUMMARY:-}")"
  TEMPLATE_ARGS+=("CHANGE_SUMMARY=${formatted_summary}")

  if ! send_slack_notification_from_template "$template_file" "${TEMPLATE_ARGS[@]}"; then
    if [[ -n "$temp_inline_file" ]]; then
      rm -f "$temp_inline_file"
    fi

    if is_true "$fail_on_error"; then
      fail "Slack notification failed"
    fi

    warn "Slack notification failed"
    return
  fi

  if [[ -n "$temp_inline_file" ]]; then
    rm -f "$temp_inline_file"
  fi

  log "Slack notification sent"
}
