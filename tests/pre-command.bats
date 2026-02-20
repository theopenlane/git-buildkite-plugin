#!/usr/bin/env bats

HOOK="$PWD/hooks/pre-command"
ORIGINAL_PATH="$PATH"

reset_plugin_env() {
  local var=""
  for var in ${!BUILDKITE_PLUGIN_GIT_@}; do
    unset "$var"
  done
}

setup() {
  ORIGINAL_PATH="$PATH"
  reset_plugin_env
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  reset_plugin_env
}

create_success_cmd() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
  chmod +x "$path"
}

link_system_cmd() {
  local cmd="$1"
  local target="$2"
  local resolved=""

  resolved="$(command -v "$cmd")"
  ln -sf "$resolved" "$target/$cmd"
}

setup_isolated_path() {
  local fake_bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$fake_bin"

  link_system_cmd dirname "$fake_bin"
  link_system_cmd env "$fake_bin"
  link_system_cmd sort "$fake_bin"
  link_system_cmd tr "$fake_bin"
  link_system_cmd uniq "$fake_bin"
  link_system_cmd wc "$fake_bin"
  create_success_cmd "$fake_bin/git"
  link_system_cmd sed "$fake_bin"

  for cmd in "$@"; do
    create_success_cmd "$fake_bin/$cmd"
  done

  export PATH="$fake_bin"
}

run_hook() {
  run /bin/bash "$HOOK"
}

@test "fails when repository is missing" {
  unset BUILDKITE_PLUGIN_GIT_REPOSITORY

  run_hook

  [ "$status" -ne 0 ]
  [[ "$output" == *"repository is required"* ]]
}

@test "passes dependency checks when optional features are disabled" {
  setup_isolated_path

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=false
  unset BUILDKITE_PLUGIN_GIT_SYNC_0_TYPE
  unset BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_PATTERN
  unset BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_DESTINATION
  unset BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_STEP
  unset BUILDKITE_PLUGIN_GIT_AUTH_MODE

  run_hook

  [ "$status" -eq 0 ]
  [[ "$output" == *"Pre-command checks passed"* ]]
}

@test "fails when merge-yaml is configured and yq is missing" {
  setup_isolated_path

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TYPE="merge-yaml"

  run_hook

  [ "$status" -ne 0 ]
  [[ "$output" == *"Required command not found: yq"* ]]
}

@test "fails when helm-sync preset defaults sync entries to merge-yaml and yq is missing" {
  setup_isolated_path

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_PRESET="helm-sync"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_FROM="helm-values.yaml"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="values.yaml"

  run_hook

  [ "$status" -ne 0 ]
  [[ "$output" == *"Required command not found: yq"* ]]
}

@test "fails when PR is enabled and gh is missing" {
  setup_isolated_path

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=true
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=false
  unset BUILDKITE_PLUGIN_GIT_SYNC_0_TYPE

  run_hook

  [ "$status" -ne 0 ]
  [[ "$output" == *"Required command not found: gh"* ]]
}

@test "fails when Slack is enabled and curl is missing" {
  setup_isolated_path gh

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=true
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=true
  unset BUILDKITE_PLUGIN_GIT_SYNC_0_TYPE

  run_hook

  [ "$status" -ne 0 ]
  [[ "$output" == *"Required command not found: curl"* ]]
}

@test "allows artifact download config without pre-command buildkite-agent check" {
  setup_isolated_path gh curl

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=true
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=true
  export BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_PATTERN="*.yaml"

  run_hook

  [ "$status" -eq 0 ]
  [[ "$output" == *"Pre-command checks passed"* ]]
}

@test "fails for https-token auth when token env is unset" {
  setup_isolated_path

  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SLACK_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_AUTH_MODE="https-token"
  export BUILDKITE_PLUGIN_GIT_AUTH_TOKEN_ENV="MISSING_TOKEN_ENV"
  unset MISSING_TOKEN_ENV

  run_hook

  [ "$status" -ne 0 ]
  [[ "$output" == *"auth.mode is https-token but env var MISSING_TOKEN_ENV is not set"* ]]
}
