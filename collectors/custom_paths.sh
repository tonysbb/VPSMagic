#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 自定义路径
# ============================================================

[[ -n "${_COLLECTOR_CUSTOM_LOADED:-}" ]] && return 0
_COLLECTOR_CUSTOM_LOADED=1

collect_custom_paths() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/custom_paths"
  local en_item_label="items"

  if [[ -z "${EXTRA_PATHS:-}" ]]; then
    log_debug "$(lang_pick "未配置自定义备份路径 (EXTRA_PATHS)。" "No custom backup paths configured (EXTRA_PATHS).")"
    summary_add "skip" "自定义路径" "未配置"
    return 0
  fi

  log_step "$(lang_pick "采集自定义路径..." "Collecting custom paths...")"

  local -a paths=()
  parse_list "${EXTRA_PATHS}" paths

  if [[ ${#paths[@]} -eq 0 ]]; then
    summary_add "skip" "自定义路径" "未配置"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0

  for src_path in "${paths[@]}"; do
    if [[ ! -e "${src_path}" ]]; then
      log_warn "  $(lang_pick "自定义路径不存在" "Custom path does not exist"): ${src_path}"
      continue
    fi

    log_info "  $(lang_pick "备份" "Backing up"): ${src_path}"

    if log_dry_run "$(lang_pick "备份自定义路径" "Backup custom path"): ${src_path}"; then
      ((count+=1))
      continue
    fi

    local safe_name
    safe_name="$(echo "${src_path}" | tr '/' '_' | sed 's/^_//')"

    if [[ -d "${src_path}" ]]; then
      tar -czf "${target_dir}/${safe_name}.tar.gz" \
        -C "$(dirname "${src_path}")" "$(basename "${src_path}")" 2>/dev/null || {
        log_warn "    $(lang_pick "目录备份失败" "Directory backup failed"): ${src_path}"
        continue
      }
    elif [[ -f "${src_path}" ]]; then
      safe_copy "${src_path}" "${target_dir}/${safe_name}"
    fi

    echo "${src_path}" >> "${target_dir}/_path_map.txt"
    ((count+=1))
  done

  if (( count > 0 )); then
    (( count == 1 )) && en_item_label="item"
    log_success "$(lang_pick "自定义路径" "Custom paths"): $(lang_pick "已备份" "backed up") ${count} $(lang_pick "项" "${en_item_label}")"
    summary_add "ok" "自定义路径" "${count} 项"
  else
    summary_add "skip" "自定义路径" "$(lang_pick "未发现有效路径" "no valid paths found")"
  fi
}
