#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 在线迁移模块
# 在两台 VPS 都正常运行时，通过 SSH 直接推送备份并自动恢复
# ============================================================

[[ -n "${_MODULE_MIGRATE_LOADED:-}" ]] && return 0
_MODULE_MIGRATE_LOADED=1

# ---------- 主入口 ----------
run_migrate() {
  local start_ts
  start_ts="$(date +%s)"

  log_banner "VPS Magic Backup — 在线迁移"

  # ==================== 解析迁移参数 ====================
  local target_host="${MIGRATE_TARGET:-}"
  local ssh_port="${MIGRATE_SSH_PORT:-22}"
  local ssh_key="${MIGRATE_SSH_KEY:-}"
  local bw_limit="${MIGRATE_BW_LIMIT:-}"
  local skip_restore="${MIGRATE_SKIP_RESTORE:-0}"
  local auto_confirm="${MIGRATE_AUTO_CONFIRM:-0}"

  # 从 SUBCMD_ARGS 解析
  local -a remaining_args=()
  local -a args=()
  if [[ ${#SUBCMD_ARGS[@]} -gt 0 ]]; then
    args=("${SUBCMD_ARGS[@]}")
  fi
  local i=0
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      --port|-p)
        ssh_port="${args[$((i+1))]:-22}"
        ((i+=2))
        ;;
      --key|-i)
        ssh_key="${args[$((i+1))]:-}"
        ((i+=2))
        ;;
      --bwlimit)
        bw_limit="${args[$((i+1))]:-}"
        ((i+=2))
        ;;
      --skip-restore)
        skip_restore=1
        ((i+=1))
        ;;
      --yes|-y)
        auto_confirm=1
        ((i+=1))
        ;;
      *)
        remaining_args+=("${args[$i]}")
        ((i+=1))
        ;;
    esac
  done

  # 第一个位置参数为目标主机
  if [[ ${#remaining_args[@]} -gt 0 && -z "${target_host}" ]]; then
    target_host="${remaining_args[0]}"
  fi

  if [[ -z "${target_host}" ]]; then
    log_error "$(lang_pick "请指定迁移目标主机。" "Please specify a migration target host.")"
    echo
    echo "  $(lang_pick "用法" "Usage"): vpsmagic migrate user@target-ip [$(lang_pick "选项" "options")]"
    echo
    echo "  $(lang_pick "选项" "Options"):"
    echo "    --port, -p <port>     $(lang_pick "SSH 端口 (默认: 22)" "SSH port (default: 22)")"
    echo "    --key, -i <path>      $(lang_pick "SSH 密钥路径" "SSH key path")"
    echo "    --bwlimit <limit>     $(lang_pick "传输带宽限制 (例如: 10m)" "Transfer bandwidth limit (for example: 10m)")"
    echo "    --skip-restore        $(lang_pick "仅推送备份，不在目标机恢复" "Push backup only and skip remote restore")"
    echo "    --yes, -y             $(lang_pick "跳过确认直接执行" "Run without confirmation")"
    echo "    --dry-run             $(lang_pick "模拟运行" "Dry run")"
    echo
    echo "  $(lang_pick "示例" "Examples"):"
    echo "    vpsmagic migrate root@203.0.113.50"
    echo "    vpsmagic migrate root@new-vps -p 2222 -i ~/.ssh/id_ed25519"
    echo "    vpsmagic migrate root@new-vps --skip-restore --bwlimit 10m"
    echo
    return 1
  fi

  # 构建 SSH 选项
  local -a ssh_opts=("-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=15" "-o" "BatchMode=yes" "-p" "${ssh_port}")
  if [[ -n "${ssh_key}" ]]; then
    ssh_opts+=("-i" "${ssh_key}")
  fi

  local hostname
  hostname="$(hostname 2>/dev/null || echo 'source-vps')"

  log_info "$(lang_pick "源主机" "Source host"):   ${hostname}"
  log_info "$(lang_pick "目标主机" "Target host"): ${target_host}"
  log_info "SSH $(lang_pick "端口" "port"): ${ssh_port}"
  [[ -n "${ssh_key}" ]] && log_info "SSH $(lang_pick "密钥" "key"): ${ssh_key}"
  [[ -n "${bw_limit}" ]] && log_info "$(lang_pick "带宽限制" "Bandwidth limit"): ${bw_limit}"
  [[ "${skip_restore}" == "1" ]] && log_info "$(lang_pick "模式: 仅推送 (跳过远程恢复)" "Mode: push only (skip remote restore)")"
  echo

  # ==================== 第1步: 连接检测 ====================
  log_step "$(lang_pick "第1步: 检测目标主机 SSH 连接..." "Step 1: Check SSH connectivity to the target host...")"

  if log_dry_run "SSH 连接测试: ${target_host}"; then
    log_info "  [dry-run] $(lang_pick "跳过连接测试" "Skipping connection test")"
  else
    if ! ssh "${ssh_opts[@]}" "${target_host}" "echo 'VPSMagic SSH OK'" >/dev/null 2>&1; then
      log_error "$(lang_pick "无法连接到目标主机" "Unable to connect to target host"): ${target_host}"
      echo
      echo "  $(lang_pick "请检查" "Please check"):"
      echo "    1. $(lang_pick "SSH 密钥认证是否已配置 (推荐 ssh-copy-id)" "Whether SSH key authentication is configured (ssh-copy-id recommended)")"
      echo "    2. $(lang_pick "SSH 端口是否正确 (--port)" "Whether the SSH port is correct (--port)")"
      echo "    3. $(lang_pick "防火墙是否放行" "Whether the firewall allows the connection")"
      echo "    4. $(lang_pick "目标主机是否在线" "Whether the target host is online")"
      echo
      echo "  $(lang_pick "快速配置密钥认证" "Quick key setup"):"
      echo "    ssh-copy-id -p ${ssh_port} ${target_host}"
      echo
      return 1
    fi
    log_success "  $(lang_pick "SSH 连接成功" "SSH connection succeeded")"

    # 检测目标机系统信息
    local target_os
    target_os="$(ssh "${ssh_opts[@]}" "${target_host}" "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")"
    local target_disk
    target_disk="$(ssh "${ssh_opts[@]}" "${target_host}" "df -h / 2>/dev/null | awk 'NR==2 {printf \"%s/%s\", \$4, \$2}'" 2>/dev/null || echo "unknown")"
    log_info "  $(lang_pick "目标系统" "Target OS"): ${target_os}"
    log_info "  $(lang_pick "目标磁盘" "Target disk"): $(lang_pick "可用/总计" "free/total") ${target_disk}"
  fi
  echo

  # ==================== 第2步: 确认 ====================
  if [[ "${auto_confirm}" != "1" && "${DRY_RUN}" != "1" ]]; then
    echo
    echo -e "${_CLR_BOLD}${_CLR_YELLOW}$(lang_pick "⚠ 迁移操作将:" "⚠ Migration will:")${_CLR_NC}"
    echo "  1. $(lang_pick "在源机" "Run a full backup on the source host") (${hostname}) $(lang_pick "执行全量备份" "" )"
    echo "  2. $(lang_pick "通过 SSH 传输备份到目标机" "Transfer the backup to the target host over SSH") (${target_host})"
    if [[ "${skip_restore}" != "1" ]]; then
      echo "  3. $(lang_pick "在目标机自动恢复所有服务" "Automatically restore services on the target host")"
    fi
    echo
    if ! confirm "$(lang_pick "确认开始迁移？" "Start migration?")" "y"; then
      log_warn "$(lang_pick "用户取消迁移。" "Migration canceled by user.")"
      return 0
    fi
    echo
  fi

  # ==================== 第3步: 远程 Bootstrap ====================
  log_step "$(lang_pick "第2步: 检测目标机 VPSMagic 环境..." "Step 2: Check VPSMagic on the target host...")"

  if log_dry_run "远程 Bootstrap 检测"; then
    log_info "  [dry-run] $(lang_pick "跳过" "Skipping")"
  else
    local remote_vpsmagic_installed
    remote_vpsmagic_installed="$(ssh "${ssh_opts[@]}" "${target_host}" "command -v vpsmagic >/dev/null 2>&1 && echo 'yes' || echo 'no'" 2>/dev/null)"

    if [[ "${remote_vpsmagic_installed}" == "yes" ]]; then
      log_success "  $(lang_pick "目标机已安装 VPSMagic" "VPSMagic is already installed on the target host")"
    else
      log_info "  $(lang_pick "目标机未安装 VPSMagic，开始远程安装..." "VPSMagic is not installed on the target host. Installing remotely...")"
      _migrate_remote_bootstrap "${target_host}" "${ssh_opts[@]}" || {
        log_error "$(lang_pick "远程 Bootstrap 失败!" "Remote bootstrap failed!")"
        return 1
      }
      log_success "  $(lang_pick "目标机 VPSMagic 安装完成" "VPSMagic installed on the target host")"
    fi

    # 确保目标机恢复目录存在
    ssh "${ssh_opts[@]}" "${target_host}" "mkdir -p /opt/vpsmagic/backups/restore && chmod 700 /opt/vpsmagic/backups/restore" 2>/dev/null || true
  fi
  echo

  # ==================== 第4步: 本地采集+打包 ====================
  log_step "$(lang_pick "第3步: 在源机执行备份..." "Step 3: Run backup on the source host...")"

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local backup_name="${BACKUP_PREFIX:-vpsmagic}_${hostname}_${ts}"
  local staging_dir="${BACKUP_ROOT}/staging/${backup_name}"
  local archive_dir="${BACKUP_ROOT}/archives"
  local archive="${archive_dir}/${backup_name}.tar.gz"
  local sum_file="${archive}.sha256"

  # 执行备份 (采集 + 打包)，复用 run_backup
  # 但这里我们不调 run_backup（它会上传），而是手动编排采集和打包
  _migrate_run_local_backup "${backup_name}" "${staging_dir}" "${archive_dir}" "${archive}" "${sum_file}" || {
    log_error "$(lang_pick "本地备份失败!" "Local backup failed!")"
    return 1
  }

  # 加密后路径可能变化，从约定文件读取最新路径
  if [[ -f "${BACKUP_ROOT}/.migrate_archive_path" ]]; then
    archive="$(cat "${BACKUP_ROOT}/.migrate_archive_path")"
    sum_file="$(cat "${BACKUP_ROOT}/.migrate_sum_path")"
    rm -f "${BACKUP_ROOT}/.migrate_archive_path" "${BACKUP_ROOT}/.migrate_sum_path"
  fi
  echo

  # 获取备份大小
  local archive_size="unknown"
  if [[ -f "${archive}" ]]; then
    archive_size="$(human_size "$(get_file_size "${archive}")")"
  fi

  # ==================== 第5步: SSH 传输 ====================
  log_step "$(lang_pick "第4步: 传输备份到目标机..." "Step 4: Transfer backup to the target host...")"

  local remote_restore_dir="/opt/vpsmagic/backups/restore"

  if log_dry_run "传输 ${archive} -> ${target_host}:${remote_restore_dir}/"; then
    log_info "  [dry-run] $(lang_pick "跳过传输" "Skipping transfer")"
  else
    log_info "  $(lang_pick "文件" "File"): $(basename "${archive}") (${archive_size})"
    local transfer_start
    transfer_start="$(date +%s)"
    _migrate_transfer "${archive}" "${sum_file}" "${target_host}" "${remote_restore_dir}" "${ssh_port}" "${ssh_key}" "${bw_limit}" || {
      log_error "$(lang_pick "传输失败!" "Transfer failed!")"
      return 1
    }
    local transfer_end
    transfer_end="$(date +%s)"
    local transfer_elapsed
    transfer_elapsed="$(elapsed_time "${transfer_start}" "${transfer_end}")"
    log_success "  $(lang_pick "传输完成" "Transfer completed") ($(lang_pick "耗时" "elapsed"): ${transfer_elapsed})"
  fi
  echo

  # ==================== 第6步: 远程校验 ====================
  log_step "$(lang_pick "第5步: 远程校验文件完整性..." "Step 5: Verify file integrity on the target host...")"

  if log_dry_run "远程 SHA256 校验"; then
    log_info "  [dry-run] $(lang_pick "跳过校验" "Skipping verification")"
  else
    local remote_archive="${remote_restore_dir}/$(basename "${archive}")"
    local remote_sum="${remote_restore_dir}/$(basename "${sum_file}")"
    local verify_result
    verify_result="$(ssh "${ssh_opts[@]}" "${target_host}" "
      if command -v sha256sum >/dev/null 2>&1; then
        cd '${remote_restore_dir}' && sha256sum -c '$(basename "${sum_file}")' --quiet 2>/dev/null && echo 'PASS' || echo 'FAIL'
      elif command -v shasum >/dev/null 2>&1; then
        cd '${remote_restore_dir}' && shasum -a 256 -c '$(basename "${sum_file}")' --quiet 2>/dev/null && echo 'PASS' || echo 'FAIL'
      else
        echo 'SKIP'
      fi
    " 2>/dev/null)"

    case "${verify_result}" in
      PASS)
        log_success "  $(lang_pick "远程 SHA256 校验通过" "Remote SHA256 verification passed")"
        ;;
      FAIL)
        log_error "  $(lang_pick "远程 SHA256 校验失败! 文件可能在传输中损坏。" "Remote SHA256 verification failed. The file may have been corrupted during transfer.")"
        if ! confirm "$(lang_pick "是否继续？(不推荐)" "Continue anyway? (not recommended)")" "n"; then
          return 1
        fi
        ;;
      SKIP)
        log_warn "  $(lang_pick "目标机无校验工具，跳过校验" "No checksum tool on target host. Skipping verification")"
        ;;
    esac
  fi
  echo

  # ==================== 第7步: 远程恢复 ====================
  if [[ "${skip_restore}" == "1" ]]; then
    log_info "$(lang_pick "已跳过远程恢复" "Remote restore skipped") (--skip-restore)"
    log_info "$(lang_pick "备份文件已推送至" "Backup file pushed to"): ${target_host}:${remote_restore_dir}/$(basename "${archive}")"
    echo
    echo -e "${_CLR_BOLD}$(lang_pick "在目标机上手动恢复" "Restore manually on the target host"):${_CLR_NC}"
    echo "  ssh ${target_host} -p ${ssh_port}"
    echo "  vpsmagic restore --local ${remote_restore_dir}/$(basename "${archive}")"
    echo
  else
    log_step "$(lang_pick "第6步: 在目标机执行恢复..." "Step 6: Run restore on the target host...")"

    if log_dry_run "远程执行 vpsmagic restore --local"; then
      log_info "  [dry-run] $(lang_pick "跳过远程恢复" "Skipping remote restore")"
    else
      local remote_archive="${remote_restore_dir}/$(basename "${archive}")"
      log_info "  $(lang_pick "远程执行" "Remote command"): vpsmagic restore --local ${remote_archive}"
      echo

      # 远程恢复 — 注意：不能同时用 BatchMode=yes 和 -t
      # 这里需要 pseudo-terminal 以便远程 vpsmagic 能正常输出
      local remote_restore_exit=0
      ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        -p "${ssh_port}" ${ssh_key:+-i "${ssh_key}"} \
        -t "${target_host}" "
        export RESTORE_LOCAL_FILE='${remote_archive}'
        export RESTORE_AUTO_CONFIRM=1
        if command -v vpsmagic >/dev/null 2>&1; then
          vpsmagic restore --auto-confirm
        else
          /opt/vpsmagic/vpsmagic.sh restore --auto-confirm
        fi
      " 2>&1 || remote_restore_exit=$?

      echo
      if [[ "${remote_restore_exit}" -eq 0 ]]; then
        log_success "  $(lang_pick "远程恢复完成" "Remote restore completed")"
      else
        log_warn "  $(lang_pick "远程恢复可能存在部分错误" "Remote restore may have partial errors") ($(lang_pick "退出码" "exit code"): ${remote_restore_exit})"
        log_info "  $(lang_pick "请 SSH 到目标机检查服务状态" "SSH into the target host and inspect service status")"
      fi
    fi
  fi

  # ==================== 完成 ====================
  local end_ts
  end_ts="$(date +%s)"
  local elapsed
  elapsed="$(elapsed_time "${start_ts}" "${end_ts}")"

  echo
  log_separator "═" 56
  log_success "$(lang_pick "迁移完成!" "Migration completed!")"
  echo "  🖥️  $(lang_pick "源主机" "Source host"): ${hostname}"
  echo "  🎯 $(lang_pick "目标机" "Target host"): ${target_host}"
  echo "  📦 $(lang_pick "备份包" "Backup"): $(basename "${archive}") (${archive_size})"
  echo "  ⏱  $(lang_pick "耗时" "Elapsed"): ${elapsed}"
  if [[ "${skip_restore}" == "1" ]]; then
    echo "  📋 $(lang_pick "模式" "Mode"): $(lang_pick "仅推送 (未恢复)" "push only (not restored)")"
  else
    echo "  📋 $(lang_pick "模式" "Mode"): $(lang_pick "完整迁移 (已恢复)" "full migration (restored)")"
  fi
  log_separator "═" 56
  echo

  summary_render

  # 通知
  notify_migrate_result "${target_host}" "${archive_size}" "${elapsed}" "${skip_restore}"

  echo -e "${_CLR_BOLD}${_CLR_YELLOW}$(lang_pick "迁移后检查清单" "Post-migration checklist"):${_CLR_NC}"
  echo "  1. $(lang_pick "SSH 到目标机检查服务" "SSH into the target host and inspect services"):  ssh ${target_host} -p ${ssh_port}"
  echo "  2. $(lang_pick "检查 Docker 容器" "Check Docker containers"):      docker ps"
  echo "  3. $(lang_pick "检查 Systemd 服务" "Check Systemd services"):     systemctl list-units --type=service --state=running"
  echo "  4. $(lang_pick "验证域名解析 (需更新 DNS A 记录指向新 IP)" "Verify DNS resolution (update A records to the new IP)")"
  echo "  5. $(lang_pick "检查 SSL 证书是否正常" "Check SSL certificates")"
  echo "  6. $(lang_pick "在目标机配置定时备份" "Configure scheduled backups on the target host"):  vpsmagic schedule install"
  echo

  return 0
}

# ==================== 内部函数 ====================

# ---------- 远程 Bootstrap: 在目标机安装 VPSMagic ----------
_migrate_remote_bootstrap() {
  local target="$1"
  shift
  local -a ssh_opts=("$@")

  # 推送源码到目标机
  local local_script_dir="${SCRIPT_DIR}"

  log_info "    $(lang_pick "推送 VPSMagic 到目标机..." "Pushing VPSMagic to the target host...")"

  # 用 tar 打包源码，通过 SSH 管道传输并解压
  tar -czf - -C "$(dirname "${local_script_dir}")" "$(basename "${local_script_dir}")" 2>/dev/null | \
    ssh "${ssh_opts[@]}" "${target}" "
      mkdir -p /opt/vpsmagic
      tar -xzf - -C /opt/vpsmagic --strip-components=1
      chmod +x /opt/vpsmagic/vpsmagic.sh /opt/vpsmagic/install.sh
      ln -sf /opt/vpsmagic/vpsmagic.sh /usr/local/bin/vpsmagic
      mkdir -p /opt/vpsmagic/backups
      chmod 700 /opt/vpsmagic/backups
    " 2>/dev/null || return 1

  # 确认安装成功
  ssh "${ssh_opts[@]}" "${target}" "command -v vpsmagic >/dev/null 2>&1 || test -x /opt/vpsmagic/vpsmagic.sh" 2>/dev/null || {
    log_error "    $(lang_pick "远程安装验证失败" "Remote installation verification failed")"
    return 1
  }

  return 0
}

# ---------- 本地备份 (采集+打包，不上传) ----------
_migrate_run_local_backup() {
  local backup_name="$1"
  local staging_dir="$2"
  local archive_dir="$3"
  local archive="$4"
  local sum_file="$5"

  safe_mkdir "${staging_dir}"
  safe_mkdir "${archive_dir}"

  # 磁盘空间预检
  local avail_bytes
  avail_bytes="$(get_disk_avail_bytes "${BACKUP_ROOT}")"
  log_info "$(lang_pick "备份磁盘" "Backup disk"): $(lang_pick "可用" "available") $(human_size "${avail_bytes}")"
  local disk_check_result=0
  check_disk_space "${BACKUP_ROOT}" || disk_check_result=$?
  if (( disk_check_result == 2 )); then
    log_error "$(lang_pick "磁盘空间严重不足，中止备份。" "Critical disk space shortage. Aborting backup.")"
    return 1
  fi

  # 写入 manifest
  {
    echo "backup_name=${backup_name}"
    echo "hostname=$(hostname 2>/dev/null)"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "timestamp_local=$(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "kernel=$(uname -r 2>/dev/null)"
    local _os_name
    _os_name="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'unknown')"
    echo "os=${_os_name}"
    echo "vpsmagic_version=${VPSMAGIC_VERSION}"
    local _ip_addrs
    _ip_addrs="$(get_primary_ip)"
    echo "ip_addresses=${_ip_addrs}"
    local _docker_ver
    _docker_ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo 'none')"
    echo "docker_version=${_docker_ver}"
    echo "migrate_mode=true"
  } > "${staging_dir}/manifest.txt"

  # 保存软件包列表
  local pkg_dir="${staging_dir}/system_info"
  safe_mkdir "${pkg_dir}"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --get-selections > "${pkg_dir}/dpkg_selections.txt" 2>/dev/null || true
  fi
  if command -v apt >/dev/null 2>&1; then
    apt list --installed > "${pkg_dir}/apt_installed.txt" 2>/dev/null || true
  fi
  if command -v yum >/dev/null 2>&1; then
    yum list installed > "${pkg_dir}/yum_installed.txt" 2>/dev/null || true
  fi
  if command -v pip3 >/dev/null 2>&1; then
    pip3 list --format=freeze > "${pkg_dir}/pip3_packages.txt" 2>/dev/null || true
  fi
  if command -v npm >/dev/null 2>&1; then
    npm list -g --depth=0 > "${pkg_dir}/npm_global.txt" 2>/dev/null || true
  fi
  if command -v docker >/dev/null 2>&1; then
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" > "${pkg_dir}/docker_images.txt" 2>/dev/null || true
  fi
  log_debug "$(lang_pick "已保存软件包列表" "Saved package inventory")"

  # 依次调用采集器
  local total_modules=0
  local completed_modules=0
  local all_modules=(
    "DOCKER_COMPOSE" "DOCKER_STANDALONE" "SYSTEMD"
    "REVERSE_PROXY" "DATABASE" "SSL_CERTS"
    "CRONTAB" "FIREWALL" "USER_HOME" "CUSTOM_PATHS"
  )
  for m in "${all_modules[@]}"; do
    is_module_enabled "${m}" && ((total_modules+=1))
  done

  log_info "$(lang_pick "共 ${total_modules} 个备份模块已启用" "${total_modules} backup modules are enabled")"

  if is_module_enabled "DOCKER_COMPOSE"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_docker_compose "${staging_dir}"
  fi
  if is_module_enabled "DOCKER_STANDALONE"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_docker_standalone "${staging_dir}"
  fi
  if is_module_enabled "SYSTEMD"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_systemd_services "${staging_dir}"
  fi
  if is_module_enabled "REVERSE_PROXY"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_reverse_proxy "${staging_dir}"
  fi
  if is_module_enabled "DATABASE"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_databases "${staging_dir}"
  fi
  if is_module_enabled "SSL_CERTS"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_ssl_certs "${staging_dir}"
  fi
  if is_module_enabled "CRONTAB"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_crontab "${staging_dir}"
  fi
  if is_module_enabled "FIREWALL"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_firewall "${staging_dir}"
  fi
  if is_module_enabled "USER_HOME"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_user_home "${staging_dir}"
  fi
  if is_module_enabled "CUSTOM_PATHS"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "$(lang_pick "采集进度" "Collection progress")"
    collect_custom_paths "${staging_dir}"
  fi

  echo

  # 打包
  log_info "$(lang_pick "打包备份..." "Packaging backup...")"

  if log_dry_run "打包 ${staging_dir} -> ${archive}"; then
    summary_add "ok" "本地备份" "dry-run"
    return 0
  fi

  tar -czf "${archive}" -C "${BACKUP_ROOT}/staging" "${backup_name}" 2>/dev/null || {
    log_error "$(lang_pick "打包失败!" "Packaging failed!")"
    return 1
  }

  # 校验
  checksum_file "${archive}" "${sum_file}"

  # 加密 (可选)
  if [[ -n "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    log_info "$(lang_pick "加密备份文件..." "Encrypting backup file...")"
    local enc_file="${archive}.enc"
    if encrypt_file "${archive}" "${enc_file}" "${BACKUP_ENCRYPTION_KEY}"; then
      rm -f "${archive}"
      # 更新调用者的变量 — 通过写入约定文件
      archive="${enc_file}"
      sum_file="${archive}.sha256"
      checksum_file "${archive}" "${sum_file}"
      log_success "$(lang_pick "加密完成" "Encryption completed")"
      # 将加密后的路径写到约定位置，供调用者读取
      echo "${archive}" > "${BACKUP_ROOT}/.migrate_archive_path"
      echo "${sum_file}" > "${BACKUP_ROOT}/.migrate_sum_path"
    else
      log_warn "$(lang_pick "加密失败，保留未加密文件" "Encryption failed. Keeping the unencrypted file")"
    fi
  fi

  chmod 600 "${archive}" "${sum_file}"

  # 清理暂存
  rm -rf "${BACKUP_ROOT}/staging/${backup_name}" 2>/dev/null || true

  log_success "$(lang_pick "本地备份完成" "Local backup completed"): $(basename "${archive}")"
  summary_add "ok" "本地备份" "$(human_size "$(get_file_size "${archive}")")"

  return 0
}

# ---------- 传输文件到目标机 ----------
_migrate_transfer() {
  local archive="$1"
  local sum_file="$2"
  local target="$3"
  local remote_dir="$4"
  local port="${5:-22}"
  local key="${6:-}"
  local bw_limit="${7:-}"

  # 优先使用 rsync (支持断点续传和带宽限制)
  if command -v rsync >/dev/null 2>&1; then
    log_info "  $(lang_pick "使用 rsync 传输 (支持续传)..." "Using rsync for transfer (resume supported)...")"

    local -a rsync_opts=(
      "-avz" "--progress"
      "-e" "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p ${port}${key:+ -i ${key}}"
    )
    if [[ -n "${bw_limit}" ]]; then
      rsync_opts+=("--bwlimit=${bw_limit}")
    fi

    rsync "${rsync_opts[@]}" "${archive}" "${target}:${remote_dir}/" 2>&1 || {
      log_error "  $(lang_pick "rsync 传输失败" "rsync transfer failed")"
      return 1
    }

    # 传输校验文件
    if [[ -f "${sum_file}" ]]; then
      rsync "${rsync_opts[@]}" "${sum_file}" "${target}:${remote_dir}/" 2>/dev/null || {
        log_warn "  $(lang_pick "校验文件传输失败" "Checksum file transfer failed")"
      }
    fi
  else
    # 回退到 scp
    log_info "  $(lang_pick "使用 scp 传输..." "Using scp for transfer...")"
    local -a scp_opts=("-P" "${port}" "-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=15")
    if [[ -n "${key}" ]]; then
      scp_opts+=("-i" "${key}")
    fi

    scp "${scp_opts[@]}" "${archive}" "${target}:${remote_dir}/" 2>&1 || {
      log_error "  $(lang_pick "scp 传输失败" "scp transfer failed")"
      return 1
    }

    if [[ -f "${sum_file}" ]]; then
      scp "${scp_opts[@]}" "${sum_file}" "${target}:${remote_dir}/" 2>/dev/null || true
    fi
  fi

  summary_add "ok" "SSH 传输" "$(human_size "$(get_file_size "${archive}")")"
  return 0
}
