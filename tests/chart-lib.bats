#!/usr/bin/env bats
# chart-lib.bats tests functions from hooks/lib/chart.sh

_setup_chart_yaml() {
  local version="${1:-1.2.3}"
  local app_version="${2:-}"
  local chart_dir="$TARGET_WORKDIR/charts/myapp"
  mkdir -p "$chart_dir"
  printf 'apiVersion: v2\nname: myapp\nversion: %s\n' "$version" > "$chart_dir/Chart.yaml"
  if [[ -n "$app_version" ]]; then
    printf 'appVersion: "%s"\n' "$app_version" >> "$chart_dir/Chart.yaml"
  fi
}

_read_chart_yaml() {
  cat "$TARGET_WORKDIR/charts/myapp/Chart.yaml"
}

setup() {
  _PLUGIN_ROOT="$PWD"

  export TARGET_WORKDIR="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET_WORKDIR"

  export _STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$_STUB_BIN"
  # Restrict PATH to stub dir plus essential system paths only, excluding
  # user/homebrew/go bin directories that may have task, helm-docs, or go
  export PATH="$_STUB_BIN:/usr/bin:/bin"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$_STUB_BIN/git"
  chmod +x "$_STUB_BIN/git"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$_STUB_BIN/task"
  chmod +x "$_STUB_BIN/task"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$_STUB_BIN/helm-docs"
  chmod +x "$_STUB_BIN/helm-docs"

  # Source libs before cd so relative paths resolve from plugin root
  source "$_PLUGIN_ROOT/hooks/lib/common.sh"
  source "$_PLUGIN_ROOT/hooks/lib/sync.sh"
  source "$_PLUGIN_ROOT/hooks/lib/chart.sh"

  cd "$TARGET_WORKDIR"

  export BUILDKITE_PLUGIN_GIT_PRESET=helm-sync
  export BUILDKITE_PLUGIN_GIT_CHART_NAME=myapp
  unset BUILDKITE_PLUGIN_GIT_TARGET_ROOT || true
  unset BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV || true
  unset BUILDKITE_PLUGIN_GIT_CHART_DOCS || true
}

# --- update_chart_version ---

@test "update_chart_version: no-op when chart-version-env is not set" {
  run update_chart_version

  [ "$status" -eq 0 ]
}

@test "update_chart_version: warns and skips when env var value is empty" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  unset MY_TAG || true

  run update_chart_version

  [ "$status" -eq 0 ]
  [[ "$output" == *"is empty, skipping chart version update"* ]]
}

@test "update_chart_version: fails when target-root cannot be determined" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v1.0.0
  unset BUILDKITE_PLUGIN_GIT_CHART_NAME || true
  export BUILDKITE_PLUGIN_GIT_PRESET=custom

  run update_chart_version

  [ "$status" -ne 0 ]
  [[ "$output" == *"chart-version-env requires chart-name or target-root"* ]]
}

@test "update_chart_version: fails when Chart.yaml not found" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v1.0.0
  mkdir -p "$TARGET_WORKDIR/charts/myapp"

  run update_chart_version

  [ "$status" -ne 0 ]
  [[ "$output" == *"Chart.yaml not found at"* ]]
}

@test "update_chart_version: strips v prefix for semver chart version" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v1.2.3
  _setup_chart_yaml 0.0.1

  update_chart_version

  [[ "$(_read_chart_yaml)" == *"version: 1.2.3"* ]]
}

@test "update_chart_version: sets appVersion verbatim for semver tag" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v1.2.3
  _setup_chart_yaml 0.0.1

  update_chart_version

  [[ "$(_read_chart_yaml)" == *'appVersion: "v1.2.3"'* ]]
}

@test "update_chart_version: increments patch version for non-semver tag" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=main-abc123
  _setup_chart_yaml 1.2.3

  update_chart_version

  [[ "$(_read_chart_yaml)" == *"version: 1.2.4"* ]]
}

@test "update_chart_version: sets appVersion verbatim for non-semver tag" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=main-abc123
  _setup_chart_yaml 1.2.3

  update_chart_version

  [[ "$(_read_chart_yaml)" == *'appVersion: "main-abc123"'* ]]
}

@test "update_chart_version: appends appVersion when absent from Chart.yaml" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v2.0.0
  _setup_chart_yaml 1.0.0

  ! grep -q 'appVersion' "$TARGET_WORKDIR/charts/myapp/Chart.yaml"

  update_chart_version

  grep -q 'appVersion' "$TARGET_WORKDIR/charts/myapp/Chart.yaml"
}

@test "update_chart_version: updates existing appVersion in Chart.yaml" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v2.0.0
  _setup_chart_yaml 1.0.0 v1.0.0

  update_chart_version

  [[ "$(_read_chart_yaml)" == *'appVersion: "v2.0.0"'* ]]
  ! [[ "$(_read_chart_yaml)" == *'appVersion: "v1.0.0"'* ]]
}

@test "update_chart_version: calls git add with chart-relative path" {
  export BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV=MY_TAG
  export MY_TAG=v1.0.0
  _setup_chart_yaml 0.5.0

  printf '#!/usr/bin/env bash\necho "$@" >> "%s/git_calls"\n' "$BATS_TEST_TMPDIR" > "$_STUB_BIN/git"
  chmod +x "$_STUB_BIN/git"

  update_chart_version

  grep -q 'add charts/myapp/Chart.yaml' "$BATS_TEST_TMPDIR/git_calls"
}

# --- generate_chart_docs ---

@test "generate_chart_docs: no-op when chart-docs is not set" {
  run generate_chart_docs

  [ "$status" -eq 0 ]
}

@test "generate_chart_docs: no-op when chart-docs is false" {
  export BUILDKITE_PLUGIN_GIT_CHART_DOCS=false

  run generate_chart_docs

  [ "$status" -eq 0 ]
}

@test "generate_chart_docs: warns and returns when no target-root" {
  export BUILDKITE_PLUGIN_GIT_CHART_DOCS=true
  unset BUILDKITE_PLUGIN_GIT_CHART_NAME || true
  export BUILDKITE_PLUGIN_GIT_PRESET=custom

  run generate_chart_docs

  [ "$status" -eq 0 ]
  [[ "$output" == *"chart-docs requires chart-name or target-root to be set"* ]]
}

@test "generate_chart_docs: runs task docs in chart directory" {
  export BUILDKITE_PLUGIN_GIT_CHART_DOCS=true
  mkdir -p "$TARGET_WORKDIR/charts/myapp"

  printf '#!/usr/bin/env bash\necho "$PWD" > "%s/task_cwd"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$_STUB_BIN/task"
  chmod +x "$_STUB_BIN/task"

  generate_chart_docs

  [[ "$(cat "$BATS_TEST_TMPDIR/task_cwd")" == "$TARGET_WORKDIR/charts/myapp" ]]
}

@test "generate_chart_docs: non-fatal when task docs fails" {
  export BUILDKITE_PLUGIN_GIT_CHART_DOCS=true
  mkdir -p "$TARGET_WORKDIR/charts/myapp"

  printf '#!/usr/bin/env bash\nexit 1\n' > "$_STUB_BIN/task"
  chmod +x "$_STUB_BIN/task"

  run generate_chart_docs

  [ "$status" -eq 0 ]
  [[ "$output" == *"Documentation generation failed, continuing without docs"* ]]
}

@test "generate_chart_docs: calls git add after successful task docs" {
  export BUILDKITE_PLUGIN_GIT_CHART_DOCS=true
  mkdir -p "$TARGET_WORKDIR/charts/myapp"

  printf '#!/usr/bin/env bash\necho "$@" >> "%s/git_calls"\n' "$BATS_TEST_TMPDIR" > "$_STUB_BIN/git"
  chmod +x "$_STUB_BIN/git"

  generate_chart_docs

  grep -q '^add \.$' "$BATS_TEST_TMPDIR/git_calls"
}

@test "generate_chart_docs: skips docs when helm-docs not installable" {
  export BUILDKITE_PLUGIN_GIT_CHART_DOCS=true
  mkdir -p "$TARGET_WORKDIR/charts/myapp"

  rm -f "$_STUB_BIN/helm-docs"

  run generate_chart_docs

  [ "$status" -eq 0 ]
  [[ "$output" == *"helm-docs not available, skipping docs generation"* ]]
}

# --- _ensure_task_installed ---

@test "_ensure_task_installed: no-op when task is already on PATH" {
  run _ensure_task_installed

  [ "$status" -eq 0 ]
  ! [[ "$output" == *"Installing task"* ]]
}

@test "_ensure_task_installed: installs task when not on PATH" {
  rm -f "$_STUB_BIN/task"

  # curl stub outputs a minimal shell script that sh -s will execute successfully
  printf '#!/usr/bin/env bash\necho "exit 0"\n' > "$_STUB_BIN/curl"
  chmod +x "$_STUB_BIN/curl"

  run _ensure_task_installed

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing task (latest)"* ]]
}

# --- _ensure_helm_docs_installed ---

@test "_ensure_helm_docs_installed: no-op when helm-docs is already on PATH" {
  run _ensure_helm_docs_installed

  [ "$status" -eq 0 ]
  ! [[ "$output" == *"Installing helm-docs"* ]]
}

@test "_ensure_helm_docs_installed: installs via go install when go is available" {
  rm -f "$_STUB_BIN/helm-docs"

  printf '#!/usr/bin/env bash\necho "go $*"\nexit 0\n' > "$_STUB_BIN/go"
  chmod +x "$_STUB_BIN/go"

  run _ensure_helm_docs_installed

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing helm-docs via go install"* ]]
}

@test "_ensure_helm_docs_installed: returns failure when go is not available" {
  rm -f "$_STUB_BIN/helm-docs"

  run _ensure_helm_docs_installed

  [ "$status" -ne 0 ]
  [[ "$output" == *"go not found"* ]]
}
