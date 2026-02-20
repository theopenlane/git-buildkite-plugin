#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

HOOK="$PWD/hooks/command"

setup() {
  export BUILDKITE_BUILD_CHECKOUT_PATH="$PWD/tests/fixtures/source"
  export BUILDKITE_BUILD_NUMBER=77
  export BUILDKITE_BRANCH=feature-command
}

@test "skips when execute-phase is post-command" {
  export BUILDKITE_PLUGIN_GIT_EXECUTE_PHASE=post-command

  run "$HOOK"

  assert_success
  assert_output --partial "Skipping phase command; execute-phase is post-command"
}

@test "runs workflow in command phase and downloads artifacts" {
  export BUILDKITE_PLUGIN_GIT_EXECUTE_PHASE=command
  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH="main"
  export BUILDKITE_PLUGIN_GIT_BRANCH="sync-77"
  export BUILDKITE_PLUGIN_GIT_CLONE_PATH="$BATS_TEST_TMPDIR/target-command"
  export BUILDKITE_PLUGIN_GIT_CLEANUP=false
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SYNC_0_FROM="output.txt"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="config/output.txt"
  export BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_PATTERN="generated.yaml"
  export BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_DESTINATION="downloads"
  export BUILDKITE_PLUGIN_GIT_ARTIFACT_DOWNLOAD_0_STEP="build"

  stub buildkite-agent \
    "artifact download generated.yaml \"$BUILDKITE_BUILD_CHECKOUT_PATH/downloads\" --step build : echo artifact"

  stub git \
    "clone \"$BUILDKITE_PLUGIN_GIT_REPOSITORY\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH\" : mkdir -p '$BUILDKITE_PLUGIN_GIT_CLONE_PATH'; echo clone" \
    "ls-remote --exit-code --heads origin sync-77 : exit 2" \
    "fetch origin main : echo fetch" \
    "show-ref --verify --quiet refs/remotes/origin/main : exit 1" \
    "show-ref --verify --quiet refs/heads/main : exit 1" \
    "checkout -b sync-77 : echo checkout" \
    "add -A config/output.txt : echo add-sync" \
    "add -A . : echo add-all" \
    "diff --cached --quiet : exit 1" \
    "diff --cached --name-only : echo config/output.txt" \
    "commit -m \"chore: automated update from Buildkite build #77\" : echo commit" \
    "push origin sync-77 : echo push"

  run "$HOOK"

  assert_success
  assert_output --partial "Downloading artifact pattern 'generated.yaml' to 'downloads'"
  assert_output --partial "Automation complete"

  unstub buildkite-agent
  unstub git
}
