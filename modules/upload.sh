#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 上传模块 (rclone)
# ============================================================

[[ -n "${_MODULE_UPLOAD_LOADED:-}" ]] && return 0
_MODULE_UPLOAD_LOADED=1
LAST_BACKUP_REMOTE_TARGET=""

_build_rclone_opts() {
  local out_var="$1"
  eval "${out_var}=()"
  if [[ -n "${RCLONE_CONF:-}" && -f "${RCLONE_CONF}" ]]; then
    eval "${out_var}+=(\"--config\" \"\${RCLONE_CONF}\")"
  fi
  if [[ -n "${RCLONE_BW_LIMIT:-}" ]]; then
    eval "${out_var}+=(\"--bwlimit\" \"\${RCLONE_BW_LIMIT}\")"
  fi
  eval "${out_var}+=(\"--progress\" \"--transfers\" \"1\" \"--retries\" \"3\" \"--low-level-retries\" \"10\")"
}

_preflight_rclone_remote() {
  local remote="$1"
  shift
  local -a opts=("$@")

  if rclone mkdir "${remote}" "${opts[@]}" >/dev/null 2>&1; then
    return 0
  fi

  log_warn "$(lang_pick "远端路径不可写或无法创建" "Remote path is not writable or cannot be created"): ${remote}"
  log_info "  $(lang_pick "请将 RCLONE_REMOTE 配置为一个已存在或父目录可写的完整路径。" "Configure RCLONE_REMOTE as a full path whose parent directory already exists or is writable.")"
  log_info "  $(lang_pick "例如 OpenList/WebDAV 常见写法" "For example, a common OpenList/WebDAV path is"): openlist_webdav:139Cloud/backup/vps1"
  return 1
}

run_upload() {
  local archive="${1:-}"
  local sum_file="${2:-}"

  # 如果没有传参，查找最新的本地备份
  if [[ -z "${archive}" ]]; then
    local archive_dir="${BACKUP_ROOT}/archives"
    archive="$(get_newest_archive_file "${archive_dir}")"
    if [[ -z "${archive}" ]]; then
      log_error "$(lang_pick "未找到可上传的备份文件。" "No backup file was found for upload.")"
      summary_add "error" "远端上传" "$(lang_pick "无备份文件" "no backup file")"
      return 1
    fi
    sum_file="${archive}.sha256"
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    log_error "$(lang_pick "rclone 未安装。" "rclone is not installed.")"
    summary_add "error" "远端上传" "$(lang_pick "rclone 未安装" "rclone not installed")"
    return 1
  fi

  local -a rclone_opts=()
  _build_rclone_opts rclone_opts

  local -a backup_targets=()
  get_backup_targets backup_targets
  if [[ ${#backup_targets[@]} -eq 0 ]]; then
    log_error "$(lang_pick "未找到可用的备份目标。请设置 BACKUP_TARGETS 或 RCLONE_REMOTE。" "No available backup target was found. Please set BACKUP_TARGETS or RCLONE_REMOTE.")"
    summary_add "error" "远端上传" "$(lang_pick "无备份目标" "no backup target")"
    return 1
  fi

  local selected_remote=""
  local candidate=""
  log_step "$(lang_pick "上传备份到远端 (按优先级尝试)..." "Uploading backup to remote (trying targets by priority)...")"
  for candidate in "${backup_targets[@]}"; do
    log_info "  $(lang_pick "预检目标" "Preflight target"): ${candidate}"
    if _preflight_rclone_remote "${candidate}" "${rclone_opts[@]}"; then
      selected_remote="${candidate}"
      break
    fi
    log_warn "  $(lang_pick "目标不可用，继续尝试下一个。" "Target unavailable. Trying the next one.")"
  done

  if [[ -z "${selected_remote}" ]]; then
    log_error "$(lang_pick "所有备份目标都不可用。" "All backup targets are unavailable.")"
    summary_add "error" "远端上传" "$(lang_pick "全部目标不可用" "all targets unavailable")"
    return 1
  fi

  local archive_size
  archive_size="$(lang_pick "未生成" "not generated")"
  if [[ -f "${archive}" ]]; then
    archive_size="$(human_size "$(get_file_size "${archive}")")"
  fi
  log_info "  $(lang_pick "选定目标" "Selected target"): ${selected_remote}"
  log_info "  $(lang_pick "文件" "File"): $(basename "${archive}") (${archive_size})"
  LAST_BACKUP_REMOTE_TARGET="${selected_remote}"

  if log_dry_run "rclone copy ${archive} ${selected_remote}"; then
    summary_add "ok" "远端上传" "dry-run -> ${selected_remote}"
    return 0
  fi

  if [[ ! -f "${archive}" ]]; then
    log_error "$(lang_pick "备份文件不存在" "Backup file does not exist"): ${archive}"
    summary_add "error" "远端上传" "$(lang_pick "文件不存在" "file does not exist")"
    return 1
  fi

  local upload_start
  upload_start="$(date +%s)"

  if rclone copy "${archive}" "${selected_remote}/" "${rclone_opts[@]}" 2>&1; then
    log_success "  $(lang_pick "备份文件上传成功" "Backup file uploaded successfully")"
  else
    log_error "  $(lang_pick "备份文件上传失败!" "Backup file upload failed!")"
    summary_add "error" "远端上传" "$(lang_pick "上传失败" "upload failed")"
    return 1
  fi

  if [[ -f "${sum_file}" ]]; then
    rclone copy "${sum_file}" "${selected_remote}/" "${rclone_opts[@]}" 2>/dev/null || {
      log_warn "  $(lang_pick "校验文件上传失败" "Checksum file upload failed")"
    }
  fi

  local upload_end
  upload_end="$(date +%s)"
  local upload_elapsed
  upload_elapsed="$(elapsed_time "${upload_start}" "${upload_end}")"

  log_info "  $(lang_pick "验证远端文件..." "Verifying remote file...")"
  local remote_size
  remote_size="$(rclone size "${selected_remote}/$(basename "${archive}")" "${rclone_opts[@]}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*' || echo "0")"
  local local_size="$(get_file_size "${archive}")"

  if [[ "${remote_size}" -gt 0 ]]; then
    if [[ "${remote_size}" -eq "${local_size}" ]]; then
      log_success "  $(lang_pick "远端验证通过" "Remote verification passed") ($(lang_pick "大小匹配" "size matches"): ${archive_size})"
    else
      log_warn "  $(lang_pick "远端文件大小不匹配" "Remote file size mismatch") ($(lang_pick "本地" "local"): ${local_size}, $(lang_pick "远端" "remote"): ${remote_size})"
    fi
  else
    log_warn "  $(lang_pick "无法验证远端文件大小" "Unable to verify remote file size")"
  fi

  _rotate_remote_backups "${selected_remote}"

  log_success "$(lang_pick "上传完成" "Upload completed") ($(lang_pick "耗时" "elapsed"): ${upload_elapsed})"
  summary_add "ok" "远端上传" "${archive_size}, $(lang_pick "目标" "target") ${selected_remote}, $(lang_pick "耗时" "elapsed") ${upload_elapsed}"
  return 0
}

_rotate_remote_backups() {
  local remote="${1}"
  local keep="${BACKUP_KEEP_REMOTE:-30}"
  local prefix="${BACKUP_PREFIX:-vpsmagic}"

  log_info "  $(lang_pick "远端备份轮转" "Remote rotation") ($(lang_pick "保留最新" "keeping latest") ${keep} $(lang_pick "份" "files"))..."

  local rclone_opts=()
  _build_rclone_opts rclone_opts

  # 列出远端备份文件
  local -a remote_files=()
  while IFS= read -r fname; do
    fname="$(echo "${fname}" | xargs)"
    if [[ "${fname}" == ${prefix}_*.tar.gz* && "${fname}" != *.sha256 ]]; then
      remote_files+=("${fname}")
    fi
  done < <(rclone lsf "${remote}/" "${rclone_opts[@]}" 2>/dev/null)

  local total=${#remote_files[@]}
  if (( total <= keep )); then
    log_debug "  $(lang_pick "远端共" "Remote total") ${total} $(lang_pick "份，无需轮转" "files, no rotation needed")"
    return 0
  fi

  # 按名称排序（名称中包含时间戳，所以自然排序即可）
  local -a sorted_files=()
  while IFS= read -r f; do
    sorted_files+=("${f}")
  done < <(printf '%s\n' "${remote_files[@]}" | sort)

  local to_remove=$(( total - keep ))
  log_info "  $(lang_pick "远端共" "Remote total") ${total} $(lang_pick "份，将删除" "files, removing") ${to_remove} $(lang_pick "份旧备份" "old backups")"

  if ! log_dry_run "$(lang_pick "删除" "Delete") ${to_remove} $(lang_pick "份远端旧备份" "old remote backups")"; then
    for (( i=0; i<to_remove; i++ )); do
      local old_file="${sorted_files[$i]}"
      rclone delete "${remote}/${old_file}" "${rclone_opts[@]}" 2>/dev/null || true
      rclone delete "${remote}/${old_file}.sha256" "${rclone_opts[@]}" 2>/dev/null || true
      log_debug "  已删除远端: ${old_file}"
    done
  fi
}
