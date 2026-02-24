#!/usr/bin/env bash

PLUGIN_PREFIX="${PLUGIN_PREFIX:-BUILDKITE_PLUGIN_GIT_}"

strip_leading_dot_slash() {
  local path="$1"

  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done

  printf '%s' "$path"
}

apply_root_prefix() {
  local root="$1"
  local path="$2"
  local normalized_root=""
  local normalized_path=""

  if [[ -z "$path" || -z "$root" || "$path" == /* ]]; then
    printf '%s' "$path"
    return
  fi

  normalized_root="$(strip_leading_dot_slash "${root%/}")"
  normalized_path="$(strip_leading_dot_slash "$path")"

  if [[ -z "$normalized_root" ]]; then
    printf '%s' "$normalized_path"
    return
  fi

  if [[ "$normalized_path" == "$normalized_root" || "$normalized_path" == "$normalized_root/"* ]]; then
    printf '%s' "$normalized_path"
    return
  fi

  printf '%s/%s' "$normalized_root" "$normalized_path"
}

sync_source_root() {
  if [[ -n "${BUILDKITE_PLUGIN_GIT_SOURCE_ROOT:-}" ]]; then
    printf '%s' "${BUILDKITE_PLUGIN_GIT_SOURCE_ROOT}"
    return
  fi

  if [[ "$(plugin_preset)" == "helm-sync" ]]; then
    printf 'config'
  fi
}

sync_target_root() {
  local chart_name=""

  if [[ -n "${BUILDKITE_PLUGIN_GIT_TARGET_ROOT:-}" ]]; then
    printf '%s' "${BUILDKITE_PLUGIN_GIT_TARGET_ROOT}"
    return
  fi

  if [[ "$(plugin_preset)" != "helm-sync" ]]; then
    return
  fi

  chart_name="$(strip_leading_dot_slash "${BUILDKITE_PLUGIN_GIT_CHART_NAME:-}")"
  if [[ -n "$chart_name" ]]; then
    printf 'charts/%s' "$chart_name"
    return
  fi

  printf 'charts'
}

normalize_merge_suffix() {
  local suffix="$1"

  if [[ -z "$suffix" ]]; then
    printf ''
    return
  fi

  if [[ "$suffix" == .* || "$suffix" == \[* ]]; then
    printf '%s' "$suffix"
    return
  fi

  printf '.%s' "$suffix"
}

copy_file() {
  local src="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
}

copy_dir() {
  local src="$1"
  local dest="$2"
  local delete_mode="$3"

  mkdir -p "$dest"

  if command -v rsync >/dev/null 2>&1; then
    if is_true "$delete_mode"; then
      rsync -a --delete "${src%/}/" "${dest%/}/"
    else
      rsync -a "${src%/}/" "${dest%/}/"
    fi
    return
  fi

  if is_true "$delete_mode"; then
    rm -rf "$dest"
    mkdir -p "$dest"
  fi

  cp -R "${src%/}/." "$dest"
}

file_has_value() {
  local file="$1"
  local compact=""

  compact="$(tr -d '[:space:]' < "$file")"
  [[ -n "$compact" && "$compact" != "null" && "$compact" != "\"\"" ]]
}

prepare_merge_fragment() {
  local sync_idx="$1"
  local src="$2"
  local merge_source_path="$3"
  local merge_source_env="$4"
  local required_mode="$5"
  local fragment_file="$6"
  local merge_value=""

  if [[ -n "$merge_source_env" ]]; then
    merge_value="${!merge_source_env:-}"
    if [[ -z "$merge_value" ]]; then
      if is_true "$required_mode"; then
        fail "sync entry #${sync_idx} merge-source-env '${merge_source_env}' is empty"
      fi

      warn "sync entry #${sync_idx} merge-source-env '${merge_source_env}' is empty, skipping"
      return 1
    fi

    printf '%s\n' "$merge_value" > "$fragment_file"
  else
    if [[ -z "$src" ]]; then
      fail "sync entry #${sync_idx} requires from when merge-source-env is not set"
    fi

    if [[ ! -f "$src" ]]; then
      if is_true "$required_mode"; then
        fail "sync entry #${sync_idx} merge source path does not exist: ${src}"
      fi

      warn "Skipping optional merge source that does not exist: ${src}"
      return 1
    fi

    if [[ -z "$merge_source_path" || "$merge_source_path" == "." ]]; then
      cp "$src" "$fragment_file"
    else
      ensure_yq_installed
      yq e "${merge_source_path} // \"\"" "$src" > "$fragment_file"
    fi
  fi

  if ! file_has_value "$fragment_file"; then
    if is_true "$required_mode"; then
      fail "sync entry #${sync_idx} merge fragment resolved to an empty value"
    fi

    warn "sync entry #${sync_idx} merge fragment is empty, skipping"
    return 1
  fi

  return 0
}

merge_yaml_entry() {
  local sync_idx="$1"
  local src="$2"
  local dest="$3"
  local merge_target_path="$4"
  local merge_source_path="$5"
  local merge_source_env="$6"
  local required_mode="$7"
  local delete_prefix="${PLUGIN_PREFIX}SYNC_${sync_idx}_MERGE_DELETE_PATHS"
  local delete_idx=""
  local delete_var=""
  local delete_path=""
  local work_tmp="${TARGET_WORKDIR%/}/.git-buildkite-plugin"
  local fragment_file="${work_tmp}/merge-${sync_idx}.yaml"

  ensure_yq_installed

  if [[ -z "$merge_target_path" ]]; then
    fail "sync entry #${sync_idx} type merge-yaml requires merge-target-path"
  fi

  mkdir -p "$(dirname "$dest")" "$work_tmp"

  if [[ ! -f "$dest" ]]; then
    printf '{}\n' > "$dest"
  fi

  if ! prepare_merge_fragment "$sync_idx" "$src" "$merge_source_path" "$merge_source_env" "$required_mode" "$fragment_file"; then
    return 1
  fi

  yq e -i "${merge_target_path} = load(\"${fragment_file}\")" "$dest"

  for delete_idx in $(list_scalar_indexes "$delete_prefix"); do
    delete_var="${delete_prefix}_${delete_idx}"
    delete_path="${!delete_var:-}"

    if [[ -n "$delete_path" ]]; then
      yq e -i "del(${delete_path})" "$dest"
    fi
  done

  return 0
}

sync_entries() {
  local prefix="${PLUGIN_PREFIX}SYNC"
  local source_root=""
  local target_root=""
  local base_merge_target_path="${BUILDKITE_PLUGIN_GIT_BASE_MERGE_TARGET_PATH:-}"
  local base_merge_source_path="${BUILDKITE_PLUGIN_GIT_BASE_MERGE_SOURCE_PATH:-}"
  local idx=""
  local from_var=""
  local to_var=""
  local type_var=""
  local delete_var=""
  local required_var=""
  local merge_target_path_var=""
  local merge_target_suffix_var=""
  local merge_source_path_var=""
  local merge_source_env_var=""
  local from=""
  local to=""
  local entry_type=""
  local delete_mode=""
  local required_mode=""
  local merge_target_path=""
  local merge_target_suffix=""
  local merge_source_path=""
  local merge_source_env=""
  local inferred_suffix=""
  local src=""
  local dest=""
  local copied="false"
  local source_label=""

  source_root="$(sync_source_root)"
  target_root="$(sync_target_root)"

  for idx in $(list_entry_indexes "$prefix"); do
    from_var="${prefix}_${idx}_FROM"
    to_var="${prefix}_${idx}_TO"
    type_var="${prefix}_${idx}_TYPE"
    delete_var="${prefix}_${idx}_DELETE"
    required_var="${prefix}_${idx}_REQUIRED"
    merge_target_path_var="${prefix}_${idx}_MERGE_TARGET_PATH"
    merge_target_suffix_var="${prefix}_${idx}_MERGE_TARGET_SUFFIX"
    merge_source_path_var="${prefix}_${idx}_MERGE_SOURCE_PATH"
    merge_source_env_var="${prefix}_${idx}_MERGE_SOURCE_ENV"

    from="${!from_var:-}"
    to="${!to_var:-$from}"
    entry_type="${!type_var:-$(default_sync_type)}"
    delete_mode="${!delete_var:-false}"
    required_mode="${!required_var:-true}"
    merge_target_path="${!merge_target_path_var:-}"
    merge_target_suffix="$(normalize_merge_suffix "${!merge_target_suffix_var:-}")"
    merge_source_path="${!merge_source_path_var:-}"
    merge_source_env="${!merge_source_env_var:-}"
    inferred_suffix=""

    if [[ -n "$from" ]]; then
      from="$(apply_root_prefix "$source_root" "$from")"
    fi
    if [[ -n "$to" ]]; then
      to="$(apply_root_prefix "$target_root" "$to")"
    fi

    if [[ "$entry_type" == "merge-yaml" ]]; then
      if [[ -z "$merge_target_path" && -n "$base_merge_target_path" ]]; then
        if [[ -n "$merge_target_suffix" ]]; then
          merge_target_path="${base_merge_target_path}${merge_target_suffix}"
        else
          merge_target_path="$base_merge_target_path"
        fi
      fi

      if [[ -z "$merge_source_path" ]]; then
        if [[ -n "$merge_target_suffix" ]]; then
          merge_source_path="$merge_target_suffix"
        elif [[ -n "$base_merge_target_path" && -n "$merge_target_path" && "$merge_target_path" == "$base_merge_target_path"* ]]; then
          inferred_suffix="${merge_target_path#"$base_merge_target_path"}"
          if [[ -n "$inferred_suffix" ]]; then
            if [[ "$inferred_suffix" == .* || "$inferred_suffix" == \[* ]]; then
              merge_source_path="$inferred_suffix"
            else
              merge_source_path=".${inferred_suffix}"
            fi
          fi
        fi
      fi

      if [[ -z "$merge_source_path" && -n "$base_merge_source_path" ]]; then
        merge_source_path="$base_merge_source_path"
      fi

      if [[ -z "$merge_source_path" ]]; then
        merge_source_path="."
      fi
    fi

    if [[ -z "$to" ]]; then
      fail "sync entry #${idx} must define to or from"
    fi

    ensure_safe_target_path "$to"

    src=""
    if [[ -n "$from" ]]; then
      src="$(resolve_source_path "$from")"
    fi
    dest="${TARGET_WORKDIR%/}/$to"

    if [[ "$entry_type" == "auto" ]]; then
      if [[ -z "$src" ]]; then
        fail "sync entry #${idx} type auto requires from"
      fi

      if [[ ! -e "$src" ]]; then
        if is_true "$required_mode"; then
          fail "sync source path does not exist: ${src}"
        fi

        warn "Skipping optional sync source that does not exist: ${src}"
        continue
      fi

      if [[ -d "$src" ]]; then
        entry_type="dir"
      else
        entry_type="file"
      fi
    fi

    copied="false"
    case "$entry_type" in
      file)
        if [[ -z "$src" ]]; then
          fail "sync entry #${idx} type file requires from"
        fi

        if [[ ! -f "$src" ]]; then
          if is_true "$required_mode"; then
            fail "sync entry #${idx} expected file source but found: ${src}"
          fi
          warn "Skipping optional file source that does not exist: ${src}"
          continue
        fi

        copy_file "$src" "$dest"
        copied="true"
        ;;
      dir)
        if [[ -z "$src" ]]; then
          fail "sync entry #${idx} type dir requires from"
        fi

        if [[ ! -d "$src" ]]; then
          if is_true "$required_mode"; then
            fail "sync entry #${idx} expected directory source but found: ${src}"
          fi
          warn "Skipping optional directory source that does not exist: ${src}"
          continue
        fi

        copy_dir "$src" "$dest" "$delete_mode"
        copied="true"
        ;;
      merge-yaml)
        if merge_yaml_entry "$idx" "$src" "$dest" "$merge_target_path" "$merge_source_path" "$merge_source_env" "$required_mode"; then
          copied="true"
        else
          copied="false"
        fi
        ;;
      *)
        fail "Unsupported sync type for entry #${idx}: ${entry_type}"
        ;;
    esac

    if ! is_true "$copied"; then
      continue
    fi

    git add -A "$to"

    if [[ -n "$from" ]]; then
      source_label="$from"
    elif [[ -n "$merge_source_env" ]]; then
      source_label="<env:${merge_source_env}>"
    else
      source_label="<generated>"
    fi

    log "Synced ${source_label} -> ${to} (${entry_type})"
  done
}
