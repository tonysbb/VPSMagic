#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 自定义路径
# ============================================================

[[ -n "${_COLLECTOR_CUSTOM_LOADED:-}" ]] && return 0
_COLLECTOR_CUSTOM_LOADED=1

collect_custom_paths() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/custom_paths"

  if [[ -z "${EXTRA_PATHS:-}" ]]; then
    log_debug "未配置自定义备份路径 (EXTRA_PATHS)。"
    return 0
  fi

  log_step "采集自定义路径..."

  local -a paths=()
  parse_list "${EXTRA_PATHS}" paths

  if [[ ${#paths[@]} -eq 0 ]]; then
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0

  for src_path in "${paths[@]}"; do
    if [[ ! -e "${src_path}" ]]; then
      log_warn "  自定义路径不存在: ${src_path}"
      continue
    fi

    log_info "  备份: ${src_path}"

    if log_dry_run "备份自定义路径: ${src_path}"; then
      ((count++))
      continue
    fi

    local safe_name
    safe_name="$(echo "${src_path}" | tr '/' '_' | sed 's/^_//')"

    if [[ -d "${src_path}" ]]; then
      tar -czf "${target_dir}/${safe_name}.tar.gz" \
        -C "$(dirname "${src_path}")" "$(basename "${src_path}")" 2>/dev/null || {
        log_warn "    目录备份失败: ${src_path}"
        continue
      }
    elif [[ -f "${src_path}" ]]; then
      safe_copy "${src_path}" "${target_dir}/${safe_name}"
    fi

    echo "${src_path}" >> "${target_dir}/_path_map.txt"
    ((count++))
  done

  if (( count > 0 )); then
    log_success "自定义路径: 已备份 ${count} 项"
    summary_add "ok" "自定义路径" "${count} 项"
  fi
}
