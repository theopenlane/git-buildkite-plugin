#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export PATH="$TEST_TEMP_DIR:$PATH"
  unset SLACK_WEBHOOK_URL
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "send_slack_notification_from_template returns success when slack not configured" {
  run bash -c 'source hooks/lib/slack-utils.sh && send_slack_notification_from_template nonexistent.json'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack not configured"* ]]
}

@test "send_slack_notification_from_template fails when template missing" {
  export SLACK_WEBHOOK_URL="https://example.com/webhook"

  run bash -c 'source hooks/lib/slack-utils.sh && send_slack_notification_from_template "$TEST_TEMP_DIR/missing.json"'

  [ "$status" -ne 0 ]
  [[ "$output" == *"Slack template file not found"* ]]
}

@test "send_slack_notification_from_template sends payload with substitutions" {
  export SLACK_WEBHOOK_URL="https://example.com/webhook"

  cat > "$TEST_TEMP_DIR/template.json" <<'JSON'
{"text":"hello {{NAME}}"}
JSON

  cat > "$TEST_TEMP_DIR/curl" <<'SCRIPT'
#!/bin/bash
for ((i=1;i<=$#;i++)); do
  if [[ ${!i} == "-d" ]]; then
    next=$((i+1))
    echo "${!next}" > "${TEST_TEMP_DIR}/payload"
  fi
done
exit 0
SCRIPT
  chmod +x "$TEST_TEMP_DIR/curl"

  run bash -c "source hooks/lib/slack-utils.sh && send_slack_notification_from_template \"$TEST_TEMP_DIR/template.json\" NAME=World"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack notification sent successfully"* ]]
  grep -q 'hello World' "$TEST_TEMP_DIR/payload"
}

@test "format_summary replaces literal newlines" {
  source hooks/lib/slack-utils.sh

  input="\\n- Updated values.yaml\\n- Fixed config"
  expected=$'\n- Updated values.yaml\n- Fixed config'

  run format_summary "$input"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
