#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 备份总控模块
# 协调所有采集器执行全量备份
# ============================================================

[[ -n "${_MODULE_BACKUP_LOADED:-}" ]] && return 0
_MODULE_BACKUP_LOADED=1

run_backup() {
  local start_ts
  start_ts="$(date +%s)"
  local hostname
  hostname="$(hostname 2>/dev/null || echo 'vps')"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local backup_name="${BACKUP_PREFIX:-vpsmagic}_${hostname}_${ts}"

  log_banner "VPS Magic Backup — 全量备份"
  log_info "备份名称: ${backup_name}"
  log_info "备份根目录: ${BACKUP_ROOT}"
  echo

  # ==================== 磁盘空间预检 ====================
  log_step "磁盘空间检查..."
  local avail_bytes
  avail_bytes="$(get_disk_avail_bytes "${BACKUP_ROOT}")"
  local avail_human
  avail_human="$(human_size "${avail_bytes}")"
  local total_bytes
  total_bytes="$(get_disk_total_bytes "${BACKUP_ROOT}")"
  local total_human
  total_human="$(human_size "${total_bytes}")"

  log_info "备份磁盘: 可用 ${avail_human} / 共 ${total_human}"

  # 基于历史数据估算本次备份大小
  local est_backup_size=524288000  # 默认预估 500MB
  local archive_dir_pre="${BACKUP_ROOT}/archives"
  if [[ -d "${archive_dir_pre}" ]]; then
    local latest_archive
    latest_archive="$(ls -t "${archive_dir_pre}"/*.tar.gz* 2>/dev/null | head -1)"
    if [[ -n "${latest_archive}" ]]; then
      est_backup_size="$(get_file_size "${latest_archive}")"
      # 增加 20% 缓冲
      est_backup_size=$(( est_backup_size * 120 / 100 ))
      log_info "参考上次备份大小: $(human_size "${est_backup_size}")"
    fi
  fi

  local disk_check_result=0
  check_disk_space "${BACKUP_ROOT}" "${est_backup_size}" || disk_check_result=$?

  if (( disk_check_result == 2 )); then
    # 严重不足：尝试先轮转释放空间
    log_warn "尝试清理旧备份释放空间..."
    local archive_dir_early="${BACKUP_ROOT}/archives"
    if [[ -d "${archive_dir_early}" ]]; then
      local oldest
      oldest="$(find "${archive_dir_early}" -maxdepth 1 -name "*.tar.gz*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | awk '{print $2}')"
      if [[ -n "${oldest}" ]]; then
        rm -f "${oldest}" "${oldest}.sha256" 2>/dev/null
        log_info "已删除最旧备份: $(basename "${oldest}")"
      fi
    fi
    # 重新检查
    check_disk_space "${BACKUP_ROOT}" "${est_backup_size}" || {
      log_error "清理后空间仍然不足，中止备份。"
      return 1
    }
  fi
  echo

  # 创建暂存目录
  local staging_dir="${BACKUP_ROOT}/staging/${backup_name}"
  safe_mkdir "${staging_dir}"

  # 写入系统元信息
  _write_manifest() {
    local mf="${staging_dir}/manifest.txt"
    {
      echo "backup_name=${backup_name}"
      echo "hostname=$(hostname 2>/dev/null)"
      echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "timestamp_local=$(date +%Y-%m-%dT%H:%M:%S%z)"
      echo "kernel=$(uname -r 2>/dev/null)"
      echo "os=$(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '"')"
      echo "vpsmagic_version=${VPSMAGIC_VERSION}"
      echo "ip_addresses=$(hostname -I 2>/dev/null | xargs || echo "unknown")"
      echo "docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "none")"
    } > "${mf}"
    log_debug "已写入 manifest"
  }

  _write_manifest

  # 记录已安装的软件包列表
  _save_package_list() {
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
    # Docker 镜像列表
    if command -v docker >/dev/null 2>&1; then
      docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" > "${pkg_dir}/docker_images.txt" 2>/dev/null || true
    fi
    log_debug "已保存软件包列表"
  }

  _save_package_list

  # ==================== 依次调用采集器 ====================
  local total_modules=0
  local completed_modules=0

  # 计算已启用的模块数
  local all_modules=(
    "DOCKER_COMPOSE" "DOCKER_STANDALONE" "SYSTEMD"
    "REVERSE_PROXY" "DATABASE" "SSL_CERTS"
    "CRONTAB" "FIREWALL" "USER_HOME" "CUSTOM_PATHS"
  )
  for m in "${all_modules[@]}"; do
    is_module_enabled "${m}" && ((total_modules++))
  done

  log_info "共 ${total_modules} 个备份模块已启用"
  echo

  # Docker Compose
  if is_module_enabled "DOCKER_COMPOSE"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_docker_compose "${staging_dir}"
    echo
  fi

  # 独立 Docker 容器
  if is_module_enabled "DOCKER_STANDALONE"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_docker_standalone "${staging_dir}"
    echo
  fi

  # Systemd 服务
  if is_module_enabled "SYSTEMD"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_systemd_services "${staging_dir}"
    echo
  fi

  # 反向代理
  if is_module_enabled "REVERSE_PROXY"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_reverse_proxy "${staging_dir}"
    echo
  fi

  # 数据库
  if is_module_enabled "DATABASE"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_databases "${staging_dir}"
    echo
  fi

  # SSL 证书
  if is_module_enabled "SSL_CERTS"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_ssl_certs "${staging_dir}"
    echo
  fi

  # Crontab
  if is_module_enabled "CRONTAB"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_crontab "${staging_dir}"
    echo
  fi

  # 防火墙
  if is_module_enabled "FIREWALL"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_firewall "${staging_dir}"
    echo
  fi

  # 用户目录
  if is_module_enabled "USER_HOME"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_user_home "${staging_dir}"
    echo
  fi

  # 自定义路径
  if is_module_enabled "CUSTOM_PATHS"; then
    ((completed_modules++))
    show_progress "${completed_modules}" "${total_modules}" "总进度"
    collect_custom_paths "${staging_dir}"
    echo
  fi

  # ==================== 打包 ====================
  log_step "打包备份..."

  local archive_dir="${BACKUP_ROOT}/archives"
  safe_mkdir "${archive_dir}"

  local archive="${archive_dir}/${backup_name}.tar.gz"
  local sum_file="${archive}.sha256"

  if log_dry_run "打包 ${staging_dir} -> ${archive}"; then
    log_dry_run "生成校验文件"
  else
    tar -czf "${archive}" -C "${BACKUP_ROOT}/staging" "${backup_name}" 2>/dev/null || {
      log_error "打包失败!"
      summary_add "error" "打包" "tar 失败"
      return 1
    }

    # 校验
    checksum_file "${archive}" "${sum_file}"

    # 加密 (可选)
    if [[ -n "${BACKUP_ENCRYPTION_KEY}" ]]; then
      log_info "加密备份文件..."
      local enc_file="${archive}.enc"
      if encrypt_file "${archive}" "${enc_file}" "${BACKUP_ENCRYPTION_KEY}"; then
        rm -f "${archive}"
        archive="${enc_file}"
        checksum_file "${archive}" "${archive}.sha256"
        sum_file="${archive}.sha256"
        log_success "加密完成"
      else
        log_warn "加密失败，保留未加密文件"
      fi
    fi

    chmod 600 "${archive}" "${sum_file}"
  fi

  # 清理暂存目录
  rm -rf "${BACKUP_ROOT}/staging/${backup_name}" 2>/dev/null || true

  # 获取备份大小
  local archive_size="unknown"
  if [[ -f "${archive}" ]]; then
    archive_size="$(human_size "$(get_file_size "${archive}")")"
  fi

  # ==================== 上传 ====================
  if [[ -n "${RCLONE_REMOTE:-}" ]]; then
    run_upload "${archive}" "${sum_file}"
  else
    log_warn "RCLONE_REMOTE 未配置，跳过上传。"
    summary_add "skip" "远端上传" "未配置"
  fi

  # ==================== 本地轮转 ====================
  _rotate_local_backups() {
    local keep="${BACKUP_KEEP_LOCAL:-3}"
    local count
    count="$(find "${archive_dir}" -maxdepth 1 \( -name "${BACKUP_PREFIX:-vpsmagic}_*.tar.gz" -o -name "${BACKUP_PREFIX:-vpsmagic}_*.tar.gz.enc" \) -type f 2>/dev/null | wc -l | tr -d ' ')"

    log_info "本地备份: 当前 ${count} 份，保留策略 ${keep} 份"

    # 显示空间使用情况
    local post_avail
    post_avail="$(get_disk_avail_bytes "${archive_dir}")"
    local disk_used_by_backups
    disk_used_by_backups="$(du -sh "${archive_dir}" 2>/dev/null | awk '{print $1}')"
    log_info "  备份目录占用: ${disk_used_by_backups:-unknown}，磁盘剩余: $(human_size "${post_avail}")"

    if (( count > keep )); then
      local to_remove=$(( count - keep ))
      log_info "  本地轮转: 删除 ${to_remove} 份旧备份"
      if ! log_dry_run "删除 ${to_remove} 份旧备份"; then
        # 按修改时间排序，删除最旧的
        find "${archive_dir}" -maxdepth 1 \( -name "${BACKUP_PREFIX:-vpsmagic}_*.tar.gz" -o -name "${BACKUP_PREFIX:-vpsmagic}_*.tar.gz.enc" \) -type f -printf '%T@ %p\n' 2>/dev/null | \
          sort -n | head -n "${to_remove}" | awk '{print $2}' | \
          while read -r old_file; do
            rm -f "${old_file}" "${old_file}.sha256" "${old_file}.enc" "${old_file}.enc.sha256"
            log_debug "  已删除: $(basename "${old_file}")"
          done
        local freed_avail
        freed_avail="$(get_disk_avail_bytes "${archive_dir}")"
        local freed=$(( freed_avail - post_avail ))
        (( freed > 0 )) && log_info "  释放空间: $(human_size "${freed}")"
      fi
    fi
  }

  _rotate_local_backups

  # ==================== 完成 ====================
  local end_ts
  end_ts="$(date +%s)"
  local elapsed
  elapsed="$(elapsed_time "${start_ts}" "${end_ts}")"

  echo
  log_separator "═" 56
  log_success "备份完成!"
  echo "  📦 文件: ${archive}"
  echo "  📏 大小: ${archive_size}"
  echo "  ⏱  耗时: ${elapsed}"
  log_separator "═" 56
  echo

  # 打印摘要
  summary_render

  # 发送通知
  notify_backup_result "${archive_size}" "${elapsed}" "${archive}"

  local error_count
  error_count="$(summary_get_error_count)"
  return $(( error_count > 0 ? 1 : 0 ))
}
