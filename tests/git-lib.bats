#!/usr/bin/env bats

setup() {
  source hooks/lib/common.sh
  source hooks/lib/templates.sh
  source hooks/lib/git.sh
  export TARGET_REPOSITORY_SLUG="theopenlane/openlane-infra"
}

@test "init_target_branch uses pr-{N} suffix on PR builds" {
  export BUILDKITE_PULL_REQUEST="42"
  export BUILDKITE_BRANCH="feature-myfeature"
  export BUILDKITE_BUILD_NUMBER="99"
  unset BUILDKITE_PLUGIN_GIT_BRANCH
  unset BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX
  unset BUILDKITE_PLUGIN_GIT_BRANCH_SUFFIX

  init_target_branch

  [[ "$TARGET_BRANCH" == "automation-pr-42" ]]
}

@test "init_target_branch uses branch-buildnumber suffix on non-PR builds" {
  export BUILDKITE_PULL_REQUEST="false"
  export BUILDKITE_BRANCH="main"
  export BUILDKITE_BUILD_NUMBER="77"
  unset BUILDKITE_PLUGIN_GIT_BRANCH
  unset BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX
  unset BUILDKITE_PLUGIN_GIT_BRANCH_SUFFIX

  init_target_branch

  [[ "$TARGET_BRANCH" == "automation-main-77" ]]
}

@test "init_target_branch uses branch-buildnumber suffix when BUILDKITE_PULL_REQUEST is unset" {
  unset BUILDKITE_PULL_REQUEST
  export BUILDKITE_BRANCH="feat-something"
  export BUILDKITE_BUILD_NUMBER="5"
  unset BUILDKITE_PLUGIN_GIT_BRANCH
  unset BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX
  unset BUILDKITE_PLUGIN_GIT_BRANCH_SUFFIX

  init_target_branch

  [[ "$TARGET_BRANCH" == "automation-feat-something-5" ]]
}

@test "init_target_branch respects explicit branch override on PR builds" {
  export BUILDKITE_PULL_REQUEST="42"
  export BUILDKITE_PLUGIN_GIT_BRANCH="my-custom-branch"
  unset BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX
  unset BUILDKITE_PLUGIN_GIT_BRANCH_SUFFIX

  init_target_branch

  [[ "$TARGET_BRANCH" == "my-custom-branch" ]]
}

@test "init_target_branch respects explicit branch-suffix override on PR builds" {
  export BUILDKITE_PULL_REQUEST="42"
  export BUILDKITE_BRANCH="feature-test"
  export BUILDKITE_BUILD_NUMBER="99"
  unset BUILDKITE_PLUGIN_GIT_BRANCH
  unset BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX
  export BUILDKITE_PLUGIN_GIT_BRANCH_SUFFIX="custom-suffix"

  init_target_branch

  [[ "$TARGET_BRANCH" == "automation-custom-suffix" ]]
}

@test "init_target_branch uses custom prefix on PR builds" {
  export BUILDKITE_PULL_REQUEST="10"
  export BUILDKITE_BRANCH="feature-x"
  export BUILDKITE_BUILD_NUMBER="1"
  unset BUILDKITE_PLUGIN_GIT_BRANCH
  export BUILDKITE_PLUGIN_GIT_BRANCH_PREFIX="infra"
  unset BUILDKITE_PLUGIN_GIT_BRANCH_SUFFIX

  init_target_branch

  [[ "$TARGET_BRANCH" == "infra-pr-10" ]]
}
