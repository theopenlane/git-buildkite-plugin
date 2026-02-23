#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"

# update_chart_version updates version and appVersion in Chart.yaml when
# chart-version-env is configured. version is derived from the env var value
# by stripping a leading 'v' and treating the result as the chart version when
# it matches semver (major.minor.patch). appVersion is set to the verbatim env
# var value. Falls back to incrementing the current patch segment when the env
# var value does not match semver.
update_chart_version() {
  local env_var="${BUILDKITE_PLUGIN_GIT_CHART_VERSION_ENV:-}"
  local new_tag=""
  local chart_path=""
  local target_root=""
  local current_version=""
  local new_chart_version=""

  if [[ -z "$env_var" ]]; then
    return 0
  fi

  new_tag="${!env_var:-}"
  if [[ -z "$new_tag" ]]; then
    warn "chart-version-env '${env_var}' is empty, skipping chart version update"
    return 0
  fi

  target_root="$(sync_target_root)"
  if [[ -z "$target_root" ]]; then
    fail "chart-version-env requires chart-name or target-root to be set"
  fi

  chart_path="${TARGET_WORKDIR%/}/${target_root}/Chart.yaml"
  if [[ ! -f "$chart_path" ]]; then
    fail "Chart.yaml not found at: ${chart_path}"
  fi

  if [[ "$new_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    new_chart_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  else
    current_version="$(grep '^version:' "$chart_path" | awk '{print $2}')"
    IFS='.' read -r maj min pat <<< "$current_version"
    new_chart_version="${maj}.${min}.$((pat + 1))"
  fi

  log "Updating Chart.yaml version to ${new_chart_version}"
  sed -i -E "s/^version:.*/version: ${new_chart_version}/" "$chart_path"

  log "Updating Chart.yaml appVersion to ${new_tag}"
  if grep -q '^appVersion:' "$chart_path"; then
    sed -i -E "s/^appVersion:.*/appVersion: \"${new_tag}\"/" "$chart_path"
  else
    printf 'appVersion: "%s"\n' "$new_tag" >> "$chart_path"
  fi

  git add "${target_root}/Chart.yaml"
}

# _ensure_task_installed installs the task CLI if it is not already on PATH.
_ensure_task_installed() {
  if command -v task >/dev/null 2>&1; then
    return 0
  fi

  log "Installing task (latest)"
  curl --location https://taskfile.dev/install.sh \
    | sh -s -- -d -b /usr/local/bin
}

# _ensure_helm_docs_installed installs helm-docs via go install if it is not
# already on PATH. Returns 1 if go is not available.
_ensure_helm_docs_installed() {
  if command -v helm-docs >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v go >/dev/null 2>&1; then
    warn "go not found, cannot install helm-docs"
    return 1
  fi

  log "Installing helm-docs via go install"
  go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest
}

# generate_chart_docs generates Helm documentation by running "task docs" in
# the chart directory when chart-docs is enabled. Installs task and helm-docs
# if missing. Failure is non-fatal.
generate_chart_docs() {
  if ! is_true "${BUILDKITE_PLUGIN_GIT_CHART_DOCS:-false}"; then
    return 0
  fi

  local target_root=""
  target_root="$(sync_target_root)"
  if [[ -z "$target_root" ]]; then
    warn "chart-docs requires chart-name or target-root to be set, skipping docs generation"
    return 0
  fi

  local chart_dir="${TARGET_WORKDIR%/}/${target_root}"

  _ensure_task_installed

  if ! _ensure_helm_docs_installed; then
    warn "helm-docs not available, skipping docs generation"
    return 0
  fi

  log "Generating chart documentation in ${chart_dir}"
  if (cd "$chart_dir" && task docs); then
    git add .
    log "Chart documentation generated"
  else
    warn "Documentation generation failed, continuing without docs"
  fi
}
