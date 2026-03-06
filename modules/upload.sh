#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 上传模块 (rclone)
# ============================================================

[[ -n "${_MODULE_UPLOAD_LOADED:-}" ]] && return 0
_MODULE_UPLOAD_LOADED=1

run_upload() {
  local archive="${1:-}"
  local sum_file="${2:-}"

  # 如果没有传参，查找最新的本地备份
  if [[ -z "${archive}" ]]; then
    local archive_dir="${BACKUP_ROOT}/archives"
    archive="$(find "${archive_dir}" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.gz.enc" \) -type f -printf '%T@ %p\n' 2>/dev/null | \
               sort -rn | head -1 | awk '{print $2}')"
    if [[ -z "${archive}" ]]; then
      log_error "未找到可上传的备份文件。"
      summary_add "error" "远端上传" "无备份文件"
      return 1
    fi
    sum_file="${archive}.sha256"
  fi

  if [[ ! -f "${archive}" ]]; then
    log_error "备份文件不存在: ${archive}"
    summary_add "error" "远端上传" "文件不存在"
    return 1
  fi

  if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    log_error "RCLONE_REMOTE 未配置。"
    summary_add "error" "远端上传" "未配置"
    return 1
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone 未安装。"
    summary_add "error" "远端上传" "rclone 未安装"
    return 1
  fi

  log_step "上传备份到远端: ${RCLONE_REMOTE}"

  local rclone_opts=()
  if [[ -n "${RCLONE_CONF:-}" && -f "${RCLONE_CONF}" ]]; then
    rclone_opts+=("--config" "${RCLONE_CONF}")
  fi
  if [[ -n "${RCLONE_BW_LIMIT:-}" ]]; then
    rclone_opts+=("--bwlimit" "${RCLONE_BW_LIMIT}")
  fi
  rclone_opts+=("--progress" "--transfers" "1" "--retries" "3" "--low-level-retries" "10")

  local archive_size
  archive_size="$(human_size "$(get_file_size "${archive}")")"
  log_info "  文件: $(basename "${archive}") (${archive_size})"

  if log_dry_run "rclone copy ${archive} ${RCLONE_REMOTE}"; then
    summary_add "ok" "远端上传" "dry-run"
    return 0
  fi

  # 上传备份文件
  local upload_start
  upload_start="$(date +%s)"

  if rclone copy "${archive}" "${RCLONE_REMOTE}/" "${rclone_opts[@]}" 2>&1; then
    log_success "  备份文件上传成功"
  else
    log_error "  备份文件上传失败!"
    summary_add "error" "远端上传" "上传失败"
    return 1
  fi

  # 上传校验文件
  if [[ -f "${sum_file}" ]]; then
    rclone copy "${sum_file}" "${RCLONE_REMOTE}/" "${rclone_opts[@]}" 2>/dev/null || {
      log_warn "  校验文件上传失败"
    }
  fi

  local upload_end
  upload_end="$(date +%s)"
  local upload_elapsed
  upload_elapsed="$(elapsed_time "${upload_start}" "${upload_end}")"

  # 验证远端文件
  log_info "  验证远端文件..."
  local remote_size
  remote_size="$(rclone size "${RCLONE_REMOTE}/$(basename "${archive}")" "${rclone_opts[@]}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*' || echo "0")"
  local local_size
  local_size="$(get_file_size "${archive}")"

  if [[ "${remote_size}" -gt 0 ]]; then
    if [[ "${remote_size}" -eq "${local_size}" ]]; then
      log_success "  远端验证通过 (大小匹配: ${archive_size})"
    else
      log_warn "  远端文件大小不匹配 (本地: ${local_size}, 远端: ${remote_size})"
    fi
  else
    log_warn "  无法验证远端文件大小"
  fi

  # 远端轮转
  _rotate_remote_backups

  log_success "上传完成 (耗时: ${upload_elapsed})"
  summary_add "ok" "远端上传" "${archive_size}, 耗时 ${upload_elapsed}"
  return 0
}

_rotate_remote_backups() {
  local keep="${BACKUP_KEEP_REMOTE:-30}"
  local prefix="${BACKUP_PREFIX:-vpsmagic}"

  log_info "  远端备份轮转 (保留最新 ${keep} 份)..."

  local rclone_opts=()
  if [[ -n "${RCLONE_CONF:-}" && -f "${RCLONE_CONF}" ]]; then
    rclone_opts+=("--config" "${RCLONE_CONF}")
  fi

  # 列出远端备份文件
  local -a remote_files=()
  while IFS= read -r fname; do
    fname="$(echo "${fname}" | xargs)"
    if [[ "${fname}" == ${prefix}_*.tar.gz* && "${fname}" != *.sha256 ]]; then
      remote_files+=("${fname}")
    fi
  done < <(rclone lsf "${RCLONE_REMOTE}/" "${rclone_opts[@]}" 2>/dev/null)

  local total=${#remote_files[@]}
  if (( total <= keep )); then
    log_debug "  远端共 ${total} 份，无需轮转"
    return 0
  fi

  # 按名称排序（名称中包含时间戳，所以自然排序即可）
  local -a sorted_files=()
  while IFS= read -r f; do
    sorted_files+=("${f}")
  done < <(printf '%s\n' "${remote_files[@]}" | sort)

  local to_remove=$(( total - keep ))
  log_info "  远端共 ${total} 份，将删除 ${to_remove} 份旧备份"

  if ! log_dry_run "删除 ${to_remove} 份远端旧备份"; then
    for (( i=0; i<to_remove; i++ )); do
      local old_file="${sorted_files[$i]}"
      rclone delete "${RCLONE_REMOTE}/${old_file}" "${rclone_opts[@]}" 2>/dev/null || true
      rclone delete "${RCLONE_REMOTE}/${old_file}.sha256" "${rclone_opts[@]}" 2>/dev/null || true
      log_debug "  已删除远端: ${old_file}"
    done
  fi
}
