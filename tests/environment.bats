#!/usr/bin/env bats

@test "environment hook sets default values" {
  run bash -c 'source hooks/environment >/dev/null; echo "${BUILDKITE_PLUGIN_GIT_EXECUTE_PHASE}|${BUILDKITE_PLUGIN_GIT_PR_ENABLED}|${BUILDKITE_PLUGIN_GIT_SLACK_ENABLED}"'

  [ "$status" -eq 0 ]
  [ "$output" = "post-command|true|false" ]
}
