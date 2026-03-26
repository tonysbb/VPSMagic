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
    log_error "请指定迁移目标主机。"
    echo
    echo "  用法: vpsmagic migrate user@target-ip [选项]"
    echo
    echo "  选项:"
    echo "    --port, -p <port>     SSH 端口 (默认: 22)"
    echo "    --key, -i <path>      SSH 密钥路径"
    echo "    --bwlimit <limit>     传输带宽限制 (例如: 10m)"
    echo "    --skip-restore        仅推送备份，不在目标机恢复"
    echo "    --yes, -y             跳过确认直接执行"
    echo "    --dry-run             模拟运行"
    echo
    echo "  示例:"
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

  log_info "源主机:   ${hostname}"
  log_info "目标主机: ${target_host}"
  log_info "SSH 端口: ${ssh_port}"
  [[ -n "${ssh_key}" ]] && log_info "SSH 密钥: ${ssh_key}"
  [[ -n "${bw_limit}" ]] && log_info "带宽限制: ${bw_limit}"
  [[ "${skip_restore}" == "1" ]] && log_info "模式: 仅推送 (跳过远程恢复)"
  echo

  # ==================== 第1步: 连接检测 ====================
  log_step "第1步: 检测目标主机 SSH 连接..."

  if log_dry_run "SSH 连接测试: ${target_host}"; then
    log_info "  [dry-run] 跳过连接测试"
  else
    if ! ssh "${ssh_opts[@]}" "${target_host}" "echo 'VPSMagic SSH OK'" >/dev/null 2>&1; then
      log_error "无法连接到目标主机: ${target_host}"
      echo
      echo "  请检查:"
      echo "    1. SSH 密钥认证是否已配置 (推荐 ssh-copy-id)"
      echo "    2. SSH 端口是否正确 (--port)"
      echo "    3. 防火墙是否放行"
      echo "    4. 目标主机是否在线"
      echo
      echo "  快速配置密钥认证:"
      echo "    ssh-copy-id -p ${ssh_port} ${target_host}"
      echo
      return 1
    fi
    log_success "  SSH 连接成功"

    # 检测目标机系统信息
    local target_os
    target_os="$(ssh "${ssh_opts[@]}" "${target_host}" "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")"
    local target_disk
    target_disk="$(ssh "${ssh_opts[@]}" "${target_host}" "df -h / 2>/dev/null | awk 'NR==2 {printf \"%s/%s\", \$4, \$2}'" 2>/dev/null || echo "unknown")"
    log_info "  目标系统: ${target_os}"
    log_info "  目标磁盘: 可用/总计 ${target_disk}"
  fi
  echo

  # ==================== 第2步: 确认 ====================
  if [[ "${auto_confirm}" != "1" && "${DRY_RUN}" != "1" ]]; then
    echo
    echo -e "${_CLR_BOLD}${_CLR_YELLOW}⚠ 迁移操作将:${_CLR_NC}"
    echo "  1. 在源机 (${hostname}) 执行全量备份"
    echo "  2. 通过 SSH 传输备份到目标机 (${target_host})"
    if [[ "${skip_restore}" != "1" ]]; then
      echo "  3. 在目标机自动恢复所有服务"
    fi
    echo
    if ! confirm "确认开始迁移？" "y"; then
      log_warn "用户取消迁移。"
      return 0
    fi
    echo
  fi

  # ==================== 第3步: 远程 Bootstrap ====================
  log_step "第2步: 检测目标机 VPSMagic 环境..."

  if log_dry_run "远程 Bootstrap 检测"; then
    log_info "  [dry-run] 跳过"
  else
    local remote_vpsmagic_installed
    remote_vpsmagic_installed="$(ssh "${ssh_opts[@]}" "${target_host}" "command -v vpsmagic >/dev/null 2>&1 && echo 'yes' || echo 'no'" 2>/dev/null)"

    if [[ "${remote_vpsmagic_installed}" == "yes" ]]; then
      log_success "  目标机已安装 VPSMagic"
    else
      log_info "  目标机未安装 VPSMagic，开始远程安装..."
      _migrate_remote_bootstrap "${target_host}" "${ssh_opts[@]}" || {
        log_error "远程 Bootstrap 失败!"
        return 1
      }
      log_success "  目标机 VPSMagic 安装完成"
    fi

    # 确保目标机恢复目录存在
    ssh "${ssh_opts[@]}" "${target_host}" "mkdir -p /opt/vpsmagic/backups/restore && chmod 700 /opt/vpsmagic/backups/restore" 2>/dev/null || true
  fi
  echo

  # ==================== 第4步: 本地采集+打包 ====================
  log_step "第3步: 在源机执行备份..."

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
    log_error "本地备份失败!"
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
  log_step "第4步: 传输备份到目标机..."

  local remote_restore_dir="/opt/vpsmagic/backups/restore"

  if log_dry_run "传输 ${archive} -> ${target_host}:${remote_restore_dir}/"; then
    log_info "  [dry-run] 跳过传输"
  else
    log_info "  文件: $(basename "${archive}") (${archive_size})"
    local transfer_start
    transfer_start="$(date +%s)"
    _migrate_transfer "${archive}" "${sum_file}" "${target_host}" "${remote_restore_dir}" "${ssh_port}" "${ssh_key}" "${bw_limit}" || {
      log_error "传输失败!"
      return 1
    }
    local transfer_end
    transfer_end="$(date +%s)"
    local transfer_elapsed
    transfer_elapsed="$(elapsed_time "${transfer_start}" "${transfer_end}")"
    log_success "  传输完成 (耗时: ${transfer_elapsed})"
  fi
  echo

  # ==================== 第6步: 远程校验 ====================
  log_step "第5步: 远程校验文件完整性..."

  if log_dry_run "远程 SHA256 校验"; then
    log_info "  [dry-run] 跳过校验"
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
        log_success "  远程 SHA256 校验通过"
        ;;
      FAIL)
        log_error "  远程 SHA256 校验失败! 文件可能在传输中损坏。"
        if ! confirm "是否继续？(不推荐)" "n"; then
          return 1
        fi
        ;;
      SKIP)
        log_warn "  目标机无校验工具，跳过校验"
        ;;
    esac
  fi
  echo

  # ==================== 第7步: 远程恢复 ====================
  if [[ "${skip_restore}" == "1" ]]; then
    log_info "已跳过远程恢复 (--skip-restore)"
    log_info "备份文件已推送至: ${target_host}:${remote_restore_dir}/$(basename "${archive}")"
    echo
    echo -e "${_CLR_BOLD}在目标机上手动恢复:${_CLR_NC}"
    echo "  ssh ${target_host} -p ${ssh_port}"
    echo "  vpsmagic restore --local ${remote_restore_dir}/$(basename "${archive}")"
    echo
  else
    log_step "第6步: 在目标机执行恢复..."

    if log_dry_run "远程执行 vpsmagic restore --local"; then
      log_info "  [dry-run] 跳过远程恢复"
    else
      local remote_archive="${remote_restore_dir}/$(basename "${archive}")"
      log_info "  远程执行: vpsmagic restore --local ${remote_archive}"
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
        log_success "  远程恢复完成"
      else
        log_warn "  远程恢复可能存在部分错误 (退出码: ${remote_restore_exit})"
        log_info "  请 SSH 到目标机检查服务状态"
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
  log_success "迁移完成!"
  echo "  🖥️  源主机: ${hostname}"
  echo "  🎯 目标机: ${target_host}"
  echo "  📦 备份包: $(basename "${archive}") (${archive_size})"
  echo "  ⏱  耗时: ${elapsed}"
  if [[ "${skip_restore}" == "1" ]]; then
    echo "  📋 模式: 仅推送 (未恢复)"
  else
    echo "  📋 模式: 完整迁移 (已恢复)"
  fi
  log_separator "═" 56
  echo

  summary_render

  # 通知
  notify_migrate_result "${target_host}" "${archive_size}" "${elapsed}" "${skip_restore}"

  echo -e "${_CLR_BOLD}${_CLR_YELLOW}迁移后检查清单:${_CLR_NC}"
  echo "  1. SSH 到目标机检查服务:  ssh ${target_host} -p ${ssh_port}"
  echo "  2. 检查 Docker 容器:      docker ps"
  echo "  3. 检查 Systemd 服务:     systemctl list-units --type=service --state=running"
  echo "  4. 验证域名解析 (需更新 DNS A 记录指向新 IP)"
  echo "  5. 检查 SSL 证书是否正常"
  echo "  6. 在目标机配置定时备份:  vpsmagic schedule install"
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

  log_info "    推送 VPSMagic 到目标机..."

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
    log_error "    远程安装验证失败"
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
  log_info "备份磁盘: 可用 $(human_size "${avail_bytes}")"
  local disk_check_result=0
  check_disk_space "${BACKUP_ROOT}" || disk_check_result=$?
  if (( disk_check_result == 2 )); then
    log_error "磁盘空间严重不足，中止备份。"
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
  log_debug "已保存软件包列表"

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

  log_info "共 ${total_modules} 个备份模块已启用"

  if is_module_enabled "DOCKER_COMPOSE"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_docker_compose "${staging_dir}"
  fi
  if is_module_enabled "DOCKER_STANDALONE"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_docker_standalone "${staging_dir}"
  fi
  if is_module_enabled "SYSTEMD"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_systemd_services "${staging_dir}"
  fi
  if is_module_enabled "REVERSE_PROXY"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_reverse_proxy "${staging_dir}"
  fi
  if is_module_enabled "DATABASE"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_databases "${staging_dir}"
  fi
  if is_module_enabled "SSL_CERTS"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_ssl_certs "${staging_dir}"
  fi
  if is_module_enabled "CRONTAB"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_crontab "${staging_dir}"
  fi
  if is_module_enabled "FIREWALL"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_firewall "${staging_dir}"
  fi
  if is_module_enabled "USER_HOME"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_user_home "${staging_dir}"
  fi
  if is_module_enabled "CUSTOM_PATHS"; then
    ((completed_modules+=1))
    show_progress "${completed_modules}" "${total_modules}" "采集进度"
    collect_custom_paths "${staging_dir}"
  fi

  echo

  # 打包
  log_info "打包备份..."

  if log_dry_run "打包 ${staging_dir} -> ${archive}"; then
    summary_add "ok" "本地备份" "dry-run"
    return 0
  fi

  tar -czf "${archive}" -C "${BACKUP_ROOT}/staging" "${backup_name}" 2>/dev/null || {
    log_error "打包失败!"
    return 1
  }

  # 校验
  checksum_file "${archive}" "${sum_file}"

  # 加密 (可选)
  if [[ -n "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    log_info "加密备份文件..."
    local enc_file="${archive}.enc"
    if encrypt_file "${archive}" "${enc_file}" "${BACKUP_ENCRYPTION_KEY}"; then
      rm -f "${archive}"
      # 更新调用者的变量 — 通过写入约定文件
      archive="${enc_file}"
      sum_file="${archive}.sha256"
      checksum_file "${archive}" "${sum_file}"
      log_success "加密完成"
      # 将加密后的路径写到约定位置，供调用者读取
      echo "${archive}" > "${BACKUP_ROOT}/.migrate_archive_path"
      echo "${sum_file}" > "${BACKUP_ROOT}/.migrate_sum_path"
    else
      log_warn "加密失败，保留未加密文件"
    fi
  fi

  chmod 600 "${archive}" "${sum_file}"

  # 清理暂存
  rm -rf "${BACKUP_ROOT}/staging/${backup_name}" 2>/dev/null || true

  log_success "本地备份完成: $(basename "${archive}")"
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
    log_info "  使用 rsync 传输 (支持续传)..."

    local -a rsync_opts=(
      "-avz" "--progress"
      "-e" "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p ${port}${key:+ -i ${key}}"
    )
    if [[ -n "${bw_limit}" ]]; then
      rsync_opts+=("--bwlimit=${bw_limit}")
    fi

    rsync "${rsync_opts[@]}" "${archive}" "${target}:${remote_dir}/" 2>&1 || {
      log_error "  rsync 传输失败"
      return 1
    }

    # 传输校验文件
    if [[ -f "${sum_file}" ]]; then
      rsync "${rsync_opts[@]}" "${sum_file}" "${target}:${remote_dir}/" 2>/dev/null || {
        log_warn "  校验文件传输失败"
      }
    fi
  else
    # 回退到 scp
    log_info "  使用 scp 传输..."
    local -a scp_opts=("-P" "${port}" "-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=15")
    if [[ -n "${key}" ]]; then
      scp_opts+=("-i" "${key}")
    fi

    scp "${scp_opts[@]}" "${archive}" "${target}:${remote_dir}/" 2>&1 || {
      log_error "  scp 传输失败"
      return 1
    }

    if [[ -f "${sum_file}" ]]; then
      scp "${scp_opts[@]}" "${sum_file}" "${target}:${remote_dir}/" 2>/dev/null || true
    fi
  fi

  summary_add "ok" "SSH 传输" "$(human_size "$(get_file_size "${archive}")")"
  return 0
}
