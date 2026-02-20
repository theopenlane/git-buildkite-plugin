#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

HOOK="$PWD/hooks/post-command"

setup() {
  export BUILDKITE_BUILD_CHECKOUT_PATH="$PWD/tests/fixtures/source"
  export BUILDKITE_BUILD_NUMBER=99
  export BUILDKITE_BRANCH=feature-test
}

@test "skips when step command failed" {
  export BUILDKITE_COMMAND_EXIT_STATUS=1

  run "$HOOK"

  assert_success
  assert_output --partial "Skipping because step command failed"
}

@test "skips post-command when execute-phase is command" {
  export BUILDKITE_PLUGIN_GIT_EXECUTE_PHASE=command

  run "$HOOK"

  assert_success
  assert_output --partial "Skipping phase post-command; execute-phase is command"
}

@test "syncs files and pushes commit" {
  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH="main"
  export BUILDKITE_PLUGIN_GIT_BRANCH="sync-99"
  export BUILDKITE_PLUGIN_GIT_CLONE_PATH="$BATS_TEST_TMPDIR/target"
  export BUILDKITE_PLUGIN_GIT_CLEANUP=false
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SYNC_0_FROM="output.txt"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="config/output.txt"

  stub git \
    "clone \"$BUILDKITE_PLUGIN_GIT_REPOSITORY\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH\" : mkdir -p '$BUILDKITE_PLUGIN_GIT_CLONE_PATH'; echo clone" \
    "ls-remote --exit-code --heads origin sync-99 : exit 2" \
    "fetch origin main : echo fetch" \
    "show-ref --verify --quiet refs/remotes/origin/main : exit 1" \
    "show-ref --verify --quiet refs/heads/main : exit 1" \
    "checkout -b sync-99 : echo checkout" \
    "add -A config/output.txt : echo add-sync" \
    "add -A . : echo add-all" \
    "diff --cached --quiet : exit 1" \
    "diff --cached --name-only : echo config/output.txt" \
    "commit -m \"chore: automated update from Buildkite build #99\" : echo commit" \
    "push origin sync-99 : echo push"

  run "$HOOK"

  assert_success
  assert_output --partial "Synced output.txt -> config/output.txt (file)"
  assert_output --partial "Automation complete"
  unstub git
}

@test "merges yaml into configurable target path from env var" {
  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH="main"
  export BUILDKITE_PLUGIN_GIT_BRANCH="sync-99"
  export BUILDKITE_PLUGIN_GIT_CLONE_PATH="$BATS_TEST_TMPDIR/target-merge"
  export BUILDKITE_PLUGIN_GIT_CLEANUP=false
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false

  export MERGE_FRAGMENT=$'enabled: true\nreplicas: 2'
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="config/values.yaml"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TYPE="merge-yaml"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_MERGE_TARGET_PATH=".service.runtime"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_MERGE_SOURCE_ENV="MERGE_FRAGMENT"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_MERGE_DELETE_PATHS_0=".legacy"

  stub git \
    "clone \"$BUILDKITE_PLUGIN_GIT_REPOSITORY\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH\" : mkdir -p '$BUILDKITE_PLUGIN_GIT_CLONE_PATH'; echo clone" \
    "ls-remote --exit-code --heads origin sync-99 : exit 2" \
    "fetch origin main : echo fetch" \
    "show-ref --verify --quiet refs/remotes/origin/main : exit 1" \
    "show-ref --verify --quiet refs/heads/main : exit 1" \
    "checkout -b sync-99 : echo checkout" \
    "add -A config/values.yaml : echo add-sync" \
    "add -A . : echo add-all" \
    "diff --cached --quiet : exit 1" \
    "diff --cached --name-only : echo config/values.yaml" \
    "commit -m \"chore: automated update from Buildkite build #99\" : echo commit" \
    "push origin sync-99 : echo push"

  stub yq \
    "e -i \".service.runtime = load(\\\"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/.git-buildkite-plugin/merge-0.yaml\\\")\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/config/values.yaml\" : echo merged" \
    "e -i \"del(.legacy)\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/config/values.yaml\" : echo deleted"

  run "$HOOK"

  assert_success
  assert_output --partial "Synced <env:MERGE_FRAGMENT> -> config/values.yaml (merge-yaml)"
  assert_output --partial "Automation complete"

  unstub git
  unstub yq
}

@test "helm-sync preset applies default roots and merge path inference" {
  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH="main"
  export BUILDKITE_PLUGIN_GIT_BRANCH="sync-99"
  export BUILDKITE_PLUGIN_GIT_CLONE_PATH="$BATS_TEST_TMPDIR/target-helm-preset"
  export BUILDKITE_PLUGIN_GIT_CLEANUP=false
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false

  export BUILDKITE_PLUGIN_GIT_PRESET="helm-sync"
  export BUILDKITE_PLUGIN_GIT_CHART_NAME="openlane"
  export BUILDKITE_PLUGIN_GIT_BASE_MERGE_TARGET_PATH=".openlane.coreConfiguration"
  export BUILDKITE_PLUGIN_GIT_BASE_MERGE_SOURCE_PATH=".openlane.coreConfiguration // .coreConfiguration"

  export BUILDKITE_PLUGIN_GIT_SYNC_0_FROM="helm-values.yaml"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="values.yaml"

  export BUILDKITE_PLUGIN_GIT_SYNC_1_FROM="helm-values.yaml"
  export BUILDKITE_PLUGIN_GIT_SYNC_1_TO="values.yaml"
  export BUILDKITE_PLUGIN_GIT_SYNC_1_MERGE_TARGET_SUFFIX=".externalSecrets"
  export BUILDKITE_PLUGIN_GIT_SYNC_1_REQUIRED=false
  export BUILDKITE_PLUGIN_GIT_SYNC_1_MERGE_DELETE_PATHS_0=".externalSecrets"

  mkdir -p "$BUILDKITE_BUILD_CHECKOUT_PATH/config"
  cat > "$BUILDKITE_BUILD_CHECKOUT_PATH/config/helm-values.yaml" <<'YAML'
openlane:
  coreConfiguration:
    enabled: true
externalSecrets:
  enabled: true
YAML

  stub git \
    "clone \"$BUILDKITE_PLUGIN_GIT_REPOSITORY\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH\" : mkdir -p '$BUILDKITE_PLUGIN_GIT_CLONE_PATH'; echo clone" \
    "ls-remote --exit-code --heads origin sync-99 : exit 2" \
    "fetch origin main : echo fetch" \
    "show-ref --verify --quiet refs/remotes/origin/main : exit 1" \
    "show-ref --verify --quiet refs/heads/main : exit 1" \
    "checkout -b sync-99 : echo checkout" \
    "add -A charts/openlane/values.yaml : echo add-sync-1" \
    "add -A charts/openlane/values.yaml : echo add-sync-2" \
    "add -A . : echo add-all" \
    "diff --cached --quiet : exit 1" \
    "diff --cached --name-only : echo charts/openlane/values.yaml" \
    "commit -m \"chore: automated update from Buildkite build #99\" : echo commit" \
    "push origin sync-99 : echo push"

  stub yq \
    "e \".openlane.coreConfiguration // .coreConfiguration // \\\"\\\"\" \"$BUILDKITE_BUILD_CHECKOUT_PATH/config/helm-values.yaml\" : echo root-merge" \
    "e -i \".openlane.coreConfiguration = load(\\\"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/.git-buildkite-plugin/merge-0.yaml\\\")\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/charts/openlane/values.yaml\" : echo merged-root" \
    "e \".externalSecrets // \\\"\\\"\" \"$BUILDKITE_BUILD_CHECKOUT_PATH/config/helm-values.yaml\" : echo secrets-merge" \
    "e -i \".openlane.coreConfiguration.externalSecrets = load(\\\"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/.git-buildkite-plugin/merge-1.yaml\\\")\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/charts/openlane/values.yaml\" : echo merged-secrets" \
    "e -i \"del(.externalSecrets)\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH/charts/openlane/values.yaml\" : echo deleted"

  run "$HOOK"

  assert_success
  assert_output --partial "Synced config/helm-values.yaml -> charts/openlane/values.yaml (merge-yaml)"
  assert_output --partial "Automation complete"

  unstub git
  unstub yq
}

@test "handles no changes without failing" {
  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH="main"
  export BUILDKITE_PLUGIN_GIT_BRANCH="sync-99"
  export BUILDKITE_PLUGIN_GIT_CLONE_PATH="$BATS_TEST_TMPDIR/target-no-change"
  export BUILDKITE_PLUGIN_GIT_CLEANUP=false
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=false
  export BUILDKITE_PLUGIN_GIT_SYNC_0_FROM="output.txt"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="config/output.txt"

  stub git \
    "clone \"$BUILDKITE_PLUGIN_GIT_REPOSITORY\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH\" : mkdir -p '$BUILDKITE_PLUGIN_GIT_CLONE_PATH'; echo clone" \
    "ls-remote --exit-code --heads origin sync-99 : exit 2" \
    "fetch origin main : echo fetch" \
    "show-ref --verify --quiet refs/remotes/origin/main : exit 1" \
    "show-ref --verify --quiet refs/heads/main : exit 1" \
    "checkout -b sync-99 : echo checkout" \
    "add -A config/output.txt : echo add-sync" \
    "add -A . : echo add-all" \
    "diff --cached --quiet : exit 0"

  run "$HOOK"

  assert_success
  assert_output --partial "No staged changes detected"

  unstub git
}

@test "creates PR and comments on source PR when configured" {
  export BUILDKITE_PLUGIN_GIT_REPOSITORY="git@github.com:theopenlane/openlane-infra.git"
  export BUILDKITE_PLUGIN_GIT_BASE_BRANCH="main"
  export BUILDKITE_PLUGIN_GIT_BRANCH="sync-99"
  export BUILDKITE_PLUGIN_GIT_CLONE_PATH="$BATS_TEST_TMPDIR/target-pr"
  export BUILDKITE_PLUGIN_GIT_CLEANUP=false
  export BUILDKITE_PLUGIN_GIT_SYNC_0_FROM="output.txt"
  export BUILDKITE_PLUGIN_GIT_SYNC_0_TO="config/output.txt"
  export BUILDKITE_PLUGIN_GIT_PR_ENABLED=true
  export BUILDKITE_PLUGIN_GIT_PR_REPO="theopenlane/openlane-infra"
  export BUILDKITE_PLUGIN_GIT_PR_TITLE="Automated PR {{BUILD_NUMBER}}"
  export BUILDKITE_PLUGIN_GIT_PR_BODY="Automated from {{SOURCE_BRANCH}}"
  export BUILDKITE_PLUGIN_GIT_PR_COMMENT_ON_SOURCE_PR=true
  export BUILDKITE_PLUGIN_GIT_PR_SOURCE_REPO="theopenlane/core"
  export BUILDKITE_PLUGIN_GIT_PR_SOURCE_PR_NUMBER="456"
  export BUILDKITE_PLUGIN_GIT_PR_SOURCE_COMMENT="Downstream: {{TARGET_PR_URL}}"
  export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls.log"

  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/gh" <<'SCRIPT'
#!/bin/sh
echo "$*" >> "$GH_CALLS_FILE"

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/theopenlane/openlane-infra/pull/123"
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "https://github.com/theopenlane/openlane-infra/pull/123"
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  echo "commented"
  exit 0
fi

exit 1
SCRIPT
  chmod +x "$fake_bin/gh"
  export PATH="$fake_bin:$PATH"

  stub git \
    "clone \"$BUILDKITE_PLUGIN_GIT_REPOSITORY\" \"$BUILDKITE_PLUGIN_GIT_CLONE_PATH\" : mkdir -p '$BUILDKITE_PLUGIN_GIT_CLONE_PATH'; echo clone" \
    "ls-remote --exit-code --heads origin sync-99 : exit 2" \
    "fetch origin main : echo fetch" \
    "show-ref --verify --quiet refs/remotes/origin/main : exit 1" \
    "show-ref --verify --quiet refs/heads/main : exit 1" \
    "checkout -b sync-99 : echo checkout" \
    "add -A config/output.txt : echo add-sync" \
    "add -A . : echo add-all" \
    "diff --cached --quiet : exit 1" \
    "diff --cached --name-only : echo config/output.txt" \
    "commit -m \"chore: automated update from Buildkite build #99\" : echo commit" \
    "push origin sync-99 : echo push"

  run "$HOOK"

  assert_success
  assert_output --partial "Created PR: https://github.com/theopenlane/openlane-infra/pull/123"
  assert_output --partial "Commented on source PR #456"
  grep -q "pr comment 456 --repo theopenlane/core" "$GH_CALLS_FILE"

  unstub git
}
