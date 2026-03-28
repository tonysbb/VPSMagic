#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 上传模块 (rclone)
# ============================================================

[[ -n "${_MODULE_UPLOAD_LOADED:-}" ]] && return 0
_MODULE_UPLOAD_LOADED=1
LAST_BACKUP_REMOTE_TARGET=""
LAST_BACKUP_ASYNC_REMOTE_TARGET=""
LAST_BACKUP_UPLOAD_SKIPPED=0

_async_upload_status_file() {
  printf '%s\n' "${BACKUP_ROOT}/logs/async_upload_last.status"
}

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

_build_shell_quoted_command() {
  local out_var="$1"
  shift
  local cmd=""
  printf -v cmd '%q ' "$@"
  printf -v "${out_var}" '%s' "${cmd% }"
}

_dispatch_async_upload() {
  local archive="$1"
  local sum_file="$2"
  local remote="$3"
  local -a rclone_opts=()
  _build_rclone_opts rclone_opts

  local log_dir="${BACKUP_ROOT}/logs"
  safe_mkdir "${log_dir}"
  local log_file="${log_dir}/async_upload_$(date +%Y%m%d_%H%M%S)_$(basename "${archive}").log"
  local status_file
  status_file="$(_async_upload_status_file)"
  local runner="${log_dir}/async_upload_runner.sh"

  local archive_cmd=""
  _build_shell_quoted_command archive_cmd rclone copy "${archive}" "${remote}/" "${rclone_opts[@]}"

  local command_str="${archive_cmd}"
  if [[ -f "${sum_file}" ]]; then
    local sum_cmd=""
    _build_shell_quoted_command sum_cmd rclone copy "${sum_file}" "${remote}/" "${rclone_opts[@]}"
    command_str="${archive_cmd} && ${sum_cmd}"
  fi

  cat > "${runner}" <<EOF
#!/usr/bin/env bash
status_file=$(printf '%q' "${status_file}")
log_file=$(printf '%q' "${log_file}")
archive_name=$(printf '%q' "$(basename "${archive}")")
remote_target=$(printf '%q' "${remote}")
started_at=$(printf '%q' "$(date +%Y-%m-%dT%H:%M:%S%z)")
{
  printf 'status=running\n'
  printf 'archive=%s\n' "\${archive_name}"
  printf 'target=%s\n' "\${remote_target}"
  printf 'started_at=%s\n' "\${started_at}"
  printf 'log_file=%s\n' "\${log_file}"
} > "\${status_file}"

if ${command_str}; then
  {
    printf 'status=success\n'
    printf 'archive=%s\n' "\${archive_name}"
    printf 'target=%s\n' "\${remote_target}"
    printf 'started_at=%s\n' "\${started_at}"
    printf 'finished_at=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
    printf 'log_file=%s\n' "\${log_file}"
  } > "\${status_file}"
else
  rc=\$?
  {
    printf 'status=failed\n'
    printf 'archive=%s\n' "\${archive_name}"
    printf 'target=%s\n' "\${remote_target}"
    printf 'started_at=%s\n' "\${started_at}"
    printf 'finished_at=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
    printf 'exit_code=%s\n' "\${rc}"
    printf 'log_file=%s\n' "\${log_file}"
  } > "\${status_file}"
  exit "\${rc}"
fi
EOF
  chmod 700 "${runner}" >/dev/null 2>&1 || true

  if command -v nohup >/dev/null 2>&1; then
    nohup "${runner}" >>"${log_file}" 2>&1 &
  else
    "${runner}" >>"${log_file}" 2>&1 &
  fi

  LAST_BACKUP_ASYNC_REMOTE_TARGET="${remote}"
  log_info "  $(lang_pick "异步副本已启动" "Async replica started"): ${remote}"
  log_info "  $(lang_pick "异步日志" "Async log"): ${log_file}"
}

_report_previous_async_upload_status() {
  local status_file=""
  status_file="$(_async_upload_status_file)"
  [[ -f "${status_file}" ]] || return 0

  local status=""
  local target=""
  local archive=""
  local finished_at=""
  local log_file=""
  status="$(awk -F= '$1=="status"{print substr($0,index($0,"=")+1)}' "${status_file}" 2>/dev/null)"
  target="$(awk -F= '$1=="target"{print substr($0,index($0,"=")+1)}' "${status_file}" 2>/dev/null)"
  archive="$(awk -F= '$1=="archive"{print substr($0,index($0,"=")+1)}' "${status_file}" 2>/dev/null)"
  finished_at="$(awk -F= '$1=="finished_at"{print substr($0,index($0,"=")+1)}' "${status_file}" 2>/dev/null)"
  log_file="$(awk -F= '$1=="log_file"{print substr($0,index($0,"=")+1)}' "${status_file}" 2>/dev/null)"

  case "${status}" in
    success)
      log_info "  $(lang_pick "上次异步副本成功" "Previous async replica succeeded"): ${archive} -> ${target}"
      ;;
    failed)
      log_warn "  $(lang_pick "上次异步副本失败" "Previous async replica failed"): ${archive} -> ${target}"
      [[ -n "${finished_at}" ]] && log_warn "  $(lang_pick "失败时间" "Failed at"): ${finished_at}"
      [[ -n "${log_file}" ]] && log_warn "  $(lang_pick "异步日志" "Async log"): ${log_file}"
      ;;
    running)
      log_warn "  $(lang_pick "上次异步副本仍在运行" "Previous async replica is still running"): ${archive} -> ${target}"
      [[ -n "${log_file}" ]] && log_warn "  $(lang_pick "异步日志" "Async log"): ${log_file}"
      ;;
  esac
}

run_upload() {
  local archive="${1:-}"
  local sum_file="${2:-}"
  LAST_BACKUP_REMOTE_TARGET=""
  LAST_BACKUP_ASYNC_REMOTE_TARGET=""
  LAST_BACKUP_UPLOAD_SKIPPED=0

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
  _report_previous_async_upload_status

  local -a backup_targets=()
  get_backup_targets backup_targets
  if [[ ${#backup_targets[@]} -eq 0 ]]; then
    log_error "$(lang_pick "未找到可用的备份目标。请设置 BACKUP_TARGETS 或 RCLONE_REMOTE。" "No available backup target was found. Please set BACKUP_TARGETS or RCLONE_REMOTE.")"
    summary_add "error" "远端上传" "$(lang_pick "无备份目标" "no backup target")"
    return 1
  fi

  local selected_remote=""
  local candidate=""
  local preferred_remote=""
  preferred_remote="$(get_backup_primary_target)"
  local interactive_targets="${BACKUP_INTERACTIVE_TARGETS:-true}"
  local enable_cloud_backup="true"
  if [[ -t 0 && -z "${BACKUP_REMOTE_OVERRIDE:-}" ]]; then
    local default_cloud="y"
    [[ "$(normalize_backup_destination)" == "local" ]] && default_cloud="n"
    if ! confirm "$(lang_pick "是否启用云端备份？" "Enable cloud backup for this run?")" "${default_cloud}"; then
      enable_cloud_backup="false"
    fi
  fi
  if [[ "${enable_cloud_backup}" != "true" ]]; then
    LAST_BACKUP_UPLOAD_SKIPPED=1
    summary_add "skip" "远端上传" "$(lang_pick "本次仅本地备份" "local-only backup for this run")"
    log_info "$(lang_pick "本次仅执行本地备份，跳过云端上传。" "This run will keep only the local backup and skip remote upload.")"
    return 0
  fi
  if [[ -n "${BACKUP_REMOTE_OVERRIDE:-}" ]]; then
    selected_remote="${BACKUP_REMOTE_OVERRIDE}"
  elif [[ "${interactive_targets}" == "true" && -t 0 && ${#backup_targets[@]} -gt 0 ]]; then
    echo
    echo -e "${_CLR_BOLD}$(lang_pick "可用远端备份路径" "Available remote backup targets"):${_CLR_NC}"
    log_separator "─" 56
    local idx=1
    local default_index=1
    for candidate in "${backup_targets[@]}"; do
      printf "  %2d) %s\n" "${idx}" "${candidate}"
      if [[ -n "${preferred_remote}" && "${candidate}" == "${preferred_remote}" ]]; then
        default_index="${idx}"
      fi
      ((idx+=1))
    done
    log_separator "─" 56
    echo

    local selection=""
    read -r -p "$(lang_pick "请选择主备份目标编号" "Select the primary backup target") [$(prompt_default_label): ${default_index}]: " selection
    selection="${selection:-${default_index}}"
    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#backup_targets[@]} )); then
      log_error "$(lang_pick "无效的选择" "Invalid selection"): ${selection}"
      summary_add "error" "远端上传" "$(lang_pick "主目标选择无效" "invalid primary target selection")"
      return 1
    fi
    selected_remote="${backup_targets[$((selection-1))]}"
  else
    log_step "$(lang_pick "上传备份到远端 (按优先级尝试)..." "Uploading backup to remote (trying targets by priority)...")"
    if [[ -n "${preferred_remote}" ]]; then
      for candidate in "${backup_targets[@]}"; do
        if [[ "${candidate}" == "${preferred_remote}" ]]; then
          log_info "  $(lang_pick "预检目标" "Preflight target"): ${candidate}"
          if _preflight_rclone_remote "${candidate}" "${rclone_opts[@]}"; then
            selected_remote="${candidate}"
            break
          fi
        fi
      done
    fi
    if [[ -z "${selected_remote}" ]]; then
      for candidate in "${backup_targets[@]}"; do
        log_info "  $(lang_pick "预检目标" "Preflight target"): ${candidate}"
        if _preflight_rclone_remote "${candidate}" "${rclone_opts[@]}"; then
          selected_remote="${candidate}"
          break
        fi
        log_warn "  $(lang_pick "目标不可用，继续尝试下一个。" "Target unavailable. Trying the next one.")"
      done
    fi
  fi

  if [[ -z "${selected_remote}" ]]; then
    log_error "$(lang_pick "所有备份目标都不可用。" "All backup targets are unavailable.")"
    summary_add "error" "远端上传" "$(lang_pick "全部目标不可用" "all targets unavailable")"
    return 1
  fi

  if ! _preflight_rclone_remote "${selected_remote}" "${rclone_opts[@]}"; then
    log_error "$(lang_pick "选定的主目标不可用。" "The selected primary target is unavailable.")"
    summary_add "error" "远端上传" "$(lang_pick "主目标不可用" "primary target unavailable")"
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

  local async_target=""
  async_target="$(get_backup_async_target)"
  if [[ -n "${async_target}" && "${async_target}" != "${selected_remote}" ]]; then
    log_info "  $(lang_pick "预检异步副本目标" "Preflight async replica target"): ${async_target}"
    if _preflight_rclone_remote "${async_target}" "${rclone_opts[@]}"; then
      _dispatch_async_upload "${archive}" "${sum_file}" "${async_target}"
    else
      log_warn "  $(lang_pick "异步副本目标不可用，已跳过" "Async replica target unavailable, skipped"): ${async_target}"
    fi
  fi

  log_success "$(lang_pick "上传完成" "Upload completed") ($(lang_pick "耗时" "elapsed"): ${upload_elapsed})"
  local upload_summary="${archive_size}, $(lang_pick "目标" "target") ${selected_remote}, $(lang_pick "耗时" "elapsed") ${upload_elapsed}"
  if [[ -n "${LAST_BACKUP_ASYNC_REMOTE_TARGET:-}" ]]; then
    upload_summary+=", $(lang_pick "异步副本" "async replica") ${LAST_BACKUP_ASYNC_REMOTE_TARGET}"
  fi
  summary_add "ok" "远端上传" "${upload_summary}"
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
