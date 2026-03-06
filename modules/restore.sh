#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 恢复总控模块
# ============================================================

[[ -n "${_MODULE_RESTORE_LOADED:-}" ]] && return 0
_MODULE_RESTORE_LOADED=1

run_restore() {
  local start_ts
  start_ts="$(date +%s)"

  log_banner "VPS Magic Backup — 恢复模式"

  # ==================== 第1步: 列出可用备份 ====================
  log_step "第1步: 查找可用备份..."

  if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    log_error "RCLONE_REMOTE 未配置，无法从远端恢复。"
    return 1
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone 未安装。请先安装: curl https://rclone.org/install.sh | sudo bash"
    return 1
  fi

  local rclone_opts=()
  if [[ -n "${RCLONE_CONF:-}" && -f "${RCLONE_CONF}" ]]; then
    rclone_opts+=("--config" "${RCLONE_CONF}")
  fi

  log_info "正在查询远端备份..."
  local -a available_backups=()
  while IFS= read -r fname; do
    fname="$(echo "${fname}" | xargs)"
    if [[ "${fname}" == *.tar.gz || "${fname}" == *.tar.gz.enc ]]; then
      available_backups+=("${fname}")
    fi
  done < <(rclone lsf "${RCLONE_REMOTE}/" "${rclone_opts[@]}" --files-only 2>/dev/null | sort -r)

  if [[ ${#available_backups[@]} -eq 0 ]]; then
    log_error "远端没有找到任何备份文件。"
    return 1
  fi

  # 显示可用备份
  echo
  echo -e "${_CLR_BOLD}可用备份 (共 ${#available_backups[@]} 份):${_CLR_NC}"
  log_separator "─" 56
  local idx=1
  for bk in "${available_backups[@]}"; do
    local size_info
    size_info="$(rclone size "${RCLONE_REMOTE}/${bk}" "${rclone_opts[@]}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*' || echo "")"
    local size_str=""
    if [[ -n "${size_info}" ]]; then
      size_str=" ($(human_size "${size_info}"))"
    fi
    printf "  %2d) %s%s\n" "${idx}" "${bk}" "${size_str}"
    ((idx++))
  done
  log_separator "─" 56
  echo

  # 用户选择
  local selection=""
  read -r -p "请选择要恢复的备份编号 [默认: 1 (最新)]: " selection
  selection="${selection:-1}"

  if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#available_backups[@]} )); then
    log_error "无效的选择: ${selection}"
    return 1
  fi

  local selected="${available_backups[$((selection-1))]}"
  log_info "选择恢复: ${selected}"

  # ==================== 第2步: 下载备份 ====================
  log_step "第2步: 下载备份文件..."

  local restore_dir="${BACKUP_ROOT}/restore"
  safe_mkdir "${restore_dir}"

  local local_archive="${restore_dir}/${selected}"
  local sum_file="${restore_dir}/${selected}.sha256"

  if [[ -f "${local_archive}" ]]; then
    log_info "本地已存在该备份，跳过下载。"
    if ! confirm "是否重新下载覆盖？" "n"; then
      log_info "使用现有文件。"
    else
      rm -f "${local_archive}" "${sum_file}"
    fi
  fi

  if [[ ! -f "${local_archive}" ]]; then
    if log_dry_run "下载 ${selected}"; then :; else
      rclone copy "${RCLONE_REMOTE}/${selected}" "${restore_dir}/" "${rclone_opts[@]}" --progress 2>&1 || {
        log_error "下载失败!"
        return 1
      }
      # 下载校验文件
      rclone copy "${RCLONE_REMOTE}/${selected}.sha256" "${restore_dir}/" "${rclone_opts[@]}" 2>/dev/null || true
      log_success "下载完成"
    fi
  fi

  # ==================== 第3步: 校验 ====================
  log_step "第3步: 校验文件完整性..."

  if [[ -f "${sum_file}" ]]; then
    if verify_checksum "${local_archive}" "${sum_file}"; then
      log_success "SHA256 校验通过"
    else
      log_error "SHA256 校验失败! 文件可能已损坏。"
      if ! confirm "是否继续恢复（不推荐）？" "n"; then
        return 1
      fi
    fi
  else
    log_warn "未找到校验文件，跳过校验。"
  fi

  # ==================== 第4步: 解密 (如果需要) ====================
  local archive_to_extract="${local_archive}"

  if [[ "${selected}" == *.enc ]]; then
    log_step "第4步: 解密备份..."
    if [[ -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
      read -rs -p "请输入解密密码: " BACKUP_ENCRYPTION_KEY
      echo
    fi
    local decrypted="${local_archive%.enc}"
    if log_dry_run "解密 ${selected}"; then :; else
      if decrypt_file "${local_archive}" "${decrypted}" "${BACKUP_ENCRYPTION_KEY}"; then
        archive_to_extract="${decrypted}"
        log_success "解密成功"
      else
        log_error "解密失败! 密码可能不正确。"
        return 1
      fi
    fi
  fi

  # ==================== 第5步: 解压 ====================
  log_step "第5步: 解压备份..."

  local extract_dir="${restore_dir}/extracted"
  rm -rf "${extract_dir}" 2>/dev/null || true
  safe_mkdir "${extract_dir}"

  if log_dry_run "解压 ${archive_to_extract}"; then :; else
    tar -xzf "${archive_to_extract}" -C "${extract_dir}" 2>/dev/null || {
      log_error "解压失败!"
      return 1
    }
    log_success "解压完成"
  fi

  # 找到解压后的根目录
  local backup_data_dir
  backup_data_dir="$(find "${extract_dir}" -maxdepth 1 -mindepth 1 -type d | head -1)"
  if [[ -z "${backup_data_dir}" ]]; then
    backup_data_dir="${extract_dir}"
  fi

  # 读取 manifest
  if [[ -f "${backup_data_dir}/manifest.txt" ]]; then
    echo
    log_info "备份信息:"
    while IFS='=' read -r key value; do
      echo "  ${key}: ${value}"
    done < "${backup_data_dir}/manifest.txt"
    echo
  fi

  # ==================== 第6步: 确认恢复范围 ====================
  log_step "第6步: 确认恢复范围..."

  echo
  echo -e "${_CLR_BOLD}备份包含以下模块:${_CLR_NC}"
  local -a restore_modules=()
  for dir in "${backup_data_dir}"/*/; do
    [[ -d "${dir}" ]] || continue
    local mod_name
    mod_name="$(basename "${dir}")"
    [[ "${mod_name}" == "system_info" ]] && continue
    restore_modules+=("${mod_name}")
    echo "  ✓ ${mod_name}"
  done
  echo

  if ! confirm "确认开始恢复以上模块？（恢复前建议先备份当前环境）" "y"; then
    log_warn "用户取消恢复。"
    return 0
  fi

  # ==================== 第7步: 执行恢复 ====================
  log_step "第7步: 执行恢复..."

  for mod in "${restore_modules[@]}"; do
    local mod_dir="${backup_data_dir}/${mod}"
    echo
    case "${mod}" in
      docker_compose)
        _restore_docker_compose "${mod_dir}"
        ;;
      docker_standalone)
        _restore_docker_standalone "${mod_dir}"
        ;;
      systemd)
        _restore_systemd "${mod_dir}"
        ;;
      reverse_proxy)
        _restore_reverse_proxy "${mod_dir}"
        ;;
      database)
        _restore_database "${mod_dir}"
        ;;
      ssl_certs)
        _restore_ssl_certs "${mod_dir}"
        ;;
      crontab)
        _restore_crontab "${mod_dir}"
        ;;
      firewall)
        _restore_firewall "${mod_dir}"
        ;;
      user_home)
        _restore_user_home "${mod_dir}"
        ;;
      custom_paths)
        _restore_custom_paths "${mod_dir}"
        ;;
      *)
        log_warn "未知模块 ${mod}，跳过。"
        ;;
    esac
  done

  # ==================== 完成 ====================
  local end_ts
  end_ts="$(date +%s)"
  local elapsed
  elapsed="$(elapsed_time "${start_ts}" "${end_ts}")"

  echo
  log_separator "═" 56
  log_success "恢复完成!"
  echo "  📦 恢复自: ${selected}"
  echo "  ⏱  耗时: ${elapsed}"
  log_separator "═" 56
  echo

  summary_render
  notify_restore_result "${selected}" "${elapsed}"

  echo -e "${_CLR_BOLD}${_CLR_YELLOW}建议操作:${_CLR_NC}"
  echo "  1. 检查所有服务是否正常运行"
  echo "  2. 验证域名和 SSL 证书"
  echo "  3. 测试数据库连接"
  echo "  4. 配置新的定时备份: vpsmagic schedule install"
  echo
}

# ==================== 各模块恢复函数 ====================

_restore_docker_compose() {
  local mod_dir="$1"
  log_step "恢复 Docker Compose 项目..."

  if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker 未安装，请先安装 Docker。"
    summary_add "warn" "恢复 Docker Compose" "Docker 未安装"
    return 0
  fi

  for proj_dir in "${mod_dir}"/*/; do
    [[ -d "${proj_dir}" ]] || continue
    local proj_name
    proj_name="$(basename "${proj_dir}")"
    local original_path=""
    [[ -f "${proj_dir}/_original_path.txt" ]] && original_path="$(cat "${proj_dir}/_original_path.txt")"

    if [[ -z "${original_path}" ]]; then
      original_path="/opt/${proj_name}"
    fi

    log_info "  恢复项目: ${proj_name} -> ${original_path}"

    if log_dry_run "恢复 Docker Compose: ${proj_name}"; then continue; fi

    safe_mkdir "${original_path}"

    # 还原 compose 文件
    for cf in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env; do
      [[ -f "${proj_dir}/${cf}" ]] && cp -a "${proj_dir}/${cf}" "${original_path}/"
    done

    # 还原 Dockerfile
    find "${proj_dir}" -maxdepth 1 -name "Dockerfile*" -exec cp {} "${original_path}/" \; 2>/dev/null || true

    # 还原卷数据
    if [[ -d "${proj_dir}/volumes" ]]; then
      for vol_archive in "${proj_dir}/volumes"/*.tar.gz; do
        [[ -f "${vol_archive}" ]] || continue
        local vol_name
        vol_name="$(basename "${vol_archive}" .tar.gz)"
        log_debug "    恢复卷: ${vol_name}"
        # 创建 Docker volume
        local full_vol="${proj_name}_${vol_name}"
        docker volume create "${full_vol}" >/dev/null 2>&1 || true
        local vol_mount
        vol_mount="$(docker volume inspect "${full_vol}" --format '{{ .Mountpoint }}' 2>/dev/null)"
        if [[ -n "${vol_mount}" ]]; then
          tar -xzf "${vol_archive}" -C "${vol_mount}" 2>/dev/null || true
        fi
      done
    fi

    # 还原 bind mount 数据
    if [[ -d "${proj_dir}/bind_mounts" ]]; then
      if [[ -f "${proj_dir}/bind_mounts/_mount_map.txt" ]]; then
        while IFS= read -r mount_line; do
          local mount_src="${mount_line%%:*}"
          local safe_name
          safe_name="$(echo "${mount_src}" | tr '/' '_' | sed 's/^_//')"
          if [[ -f "${proj_dir}/bind_mounts/${safe_name}.tar.gz" ]]; then
            safe_mkdir "$(dirname "${mount_src}")"
            tar -xzf "${proj_dir}/bind_mounts/${safe_name}.tar.gz" -C "$(dirname "${mount_src}")" 2>/dev/null || true
            log_debug "    恢复 bind mount: ${mount_src}"
          fi
        done < "${proj_dir}/bind_mounts/_mount_map.txt"
      fi
    fi

    # 还原项目配置文件
    if [[ -d "${proj_dir}/project_configs" ]]; then
      cp -a "${proj_dir}/project_configs/." "${original_path}/" 2>/dev/null || true
      log_debug "    恢复项目配置文件"
    fi

    # 启动项目
    log_info "  启动项目: ${proj_name}"
    (cd "${original_path}" && docker compose pull 2>/dev/null && docker compose up -d 2>/dev/null) || {
      log_warn "  项目 ${proj_name} 启动失败，请手动检查"
    }

    # 恢复文件权限 (关键: 如 aria2 temp 需要 65534:65534 uid:gid)
    if [[ -f "${proj_dir}/_permissions.txt" ]]; then
      log_info "  恢复文件权限..."
      while IFS=' ' read -r perms owner path; do
        [[ "${perms}" =~ ^[0-9]+$ ]] || continue
        [[ -e "${path}" ]] || continue
        chmod "${perms}" "${path}" 2>/dev/null || true
        chown "${owner}" "${path}" 2>/dev/null || true
      done < <(grep -v '^#' "${proj_dir}/_permissions.txt" 2>/dev/null)
      log_debug "    权限已恢复"
    fi
  done

  summary_add "ok" "恢复 Docker Compose" "已恢复"
}

_restore_docker_standalone() {
  local mod_dir="$1"
  log_step "恢复独立 Docker 容器..."

  if ! command -v docker >/dev/null 2>&1; then
    summary_add "warn" "恢复独立容器" "Docker 未安装"
    return 0
  fi

  for container_dir in "${mod_dir}"/*/; do
    [[ -d "${container_dir}" ]] || continue
    local name
    name="$(basename "${container_dir}")"

    if [[ ! -f "${container_dir}/metadata.env" ]]; then
      continue
    fi

    log_info "  恢复容器: ${name}"

    if log_dry_run "恢复独立容器: ${name}"; then continue; fi

    # 读取元数据
    # shellcheck disable=SC1091
    source "${container_dir}/metadata.env" 2>/dev/null || continue

    # 拉取镜像
    if [[ -n "${IMAGE:-}" ]]; then
      docker pull "${IMAGE}" 2>/dev/null || log_warn "    镜像拉取失败: ${IMAGE}"
    fi

    # 还原卷数据
    if [[ -d "${container_dir}/volumes" ]]; then
      for vol_archive in "${container_dir}/volumes"/*.tar.gz; do
        [[ -f "${vol_archive}" ]] || continue
        local vol_name
        vol_name="$(basename "${vol_archive}" .tar.gz)"
        log_debug "    恢复卷: ${vol_name}"
      done
    fi

    log_info "    注意: 独立容器需要根据 ${container_dir}/inspect.json 手动重建"
    log_info "    或参考 ${container_dir}/metadata.env 中的配置"
  done

  summary_add "ok" "恢复独立容器" "元数据已恢复"
}

_restore_systemd() {
  local mod_dir="$1"
  log_step "恢复 Systemd 服务..."

  for svc_dir in "${mod_dir}"/*/; do
    [[ -d "${svc_dir}" ]] || continue
    local svc_name
    svc_name="$(basename "${svc_dir}")"

    log_info "  恢复服务: ${svc_name}"

    if log_dry_run "恢复 Systemd: ${svc_name}"; then continue; fi

    # 还原 service 文件
    for sf in "${svc_dir}"/*.service; do
      [[ -f "${sf}" ]] && cp -a "${sf}" /etc/systemd/system/ 2>/dev/null || true
    done

    # 还原 override
    if [[ -d "${svc_dir}/overrides" ]]; then
      local override_target="/etc/systemd/system/${svc_name}.service.d"
      safe_mkdir "${override_target}"
      cp -a "${svc_dir}/overrides/." "${override_target}/" 2>/dev/null || true
    fi

    # 还原程序目录
    if [[ -f "${svc_dir}/program.tar.gz" && -f "${svc_dir}/_program_path.txt" ]]; then
      local prog_path
      prog_path="$(cat "${svc_dir}/_program_path.txt")"
      safe_mkdir "$(dirname "${prog_path}")"
      tar -xzf "${svc_dir}/program.tar.gz" -C "$(dirname "${prog_path}")" 2>/dev/null || true
    fi

    # 还原工作目录
    if [[ -f "${svc_dir}/workdir.tar.gz" && -f "${svc_dir}/_workdir_path.txt" ]]; then
      local work_path
      work_path="$(cat "${svc_dir}/_workdir_path.txt")"
      safe_mkdir "$(dirname "${work_path}")"
      tar -xzf "${svc_dir}/workdir.tar.gz" -C "$(dirname "${work_path}")" 2>/dev/null || true
    fi

    # 还原配置文件 (config.yaml, .env 等)
    for cfg in config.yaml config.yml config.json .env config.env config.toml; do
      if [[ -f "${svc_dir}/${cfg}" ]]; then
        local cfg_target=""
        [[ -f "${svc_dir}/_workdir_path.txt" ]] && cfg_target="$(cat "${svc_dir}/_workdir_path.txt")/${cfg}"
        if [[ -n "${cfg_target}" ]]; then
          safe_mkdir "$(dirname "${cfg_target}")"
          cp -a "${svc_dir}/${cfg}" "${cfg_target}" 2>/dev/null || true
          log_debug "    还原配置: ${cfg}"
        fi
      fi
    done

    # Python venv 重建 (基于 requirements_freeze.txt)
    if [[ -f "${svc_dir}/_venv_path.txt" ]]; then
      local venv_path
      venv_path="$(cat "${svc_dir}/_venv_path.txt")"
      local py_version="python3"
      [[ -f "${svc_dir}/_python_version.txt" ]] && py_version="$(cat "${svc_dir}/_python_version.txt" | awk '{print $2}' | cut -d. -f1,2)"

      log_info "    重建 Python venv: ${venv_path}"
      if command -v python3 >/dev/null 2>&1; then
        python3 -m venv "${venv_path}" 2>/dev/null || {
          log_warn "    venv 创建失败，请手动执行: python3 -m venv ${venv_path}"
        }
        # pip install from freeze
        local req_file=""
        if [[ -f "${svc_dir}/requirements_freeze.txt" ]]; then
          req_file="${svc_dir}/requirements_freeze.txt"
        elif [[ -f "${svc_dir}/requirements.txt" ]]; then
          req_file="${svc_dir}/requirements.txt"
        fi
        if [[ -n "${req_file}" && -x "${venv_path}/bin/pip" ]]; then
          log_info "    安装依赖: $(wc -l < "${req_file}" 2>/dev/null || echo '?') 个包..."
          "${venv_path}/bin/pip" install -r "${req_file}" 2>/dev/null || {
            log_warn "    pip install 部分失败，请检查 ${req_file}"
          }
        fi
      else
        log_warn "    python3 未安装，请先安装后手动重建 venv"
      fi
    fi

    # 读取状态
    if [[ -f "${svc_dir}/status.env" ]]; then
      # shellcheck disable=SC1091
      source "${svc_dir}/status.env" 2>/dev/null
      # 恢复启用状态
      systemctl daemon-reload 2>/dev/null || true
      if [[ "${ENABLED:-}" == "enabled" ]]; then
        systemctl enable "${svc_name}" 2>/dev/null || true
        systemctl start "${svc_name}" 2>/dev/null || {
          log_warn "    服务 ${svc_name} 启动失败"
        }
      fi
    fi
  done

  systemctl daemon-reload 2>/dev/null || true
  summary_add "ok" "恢复 Systemd" "服务已恢复"
}

_restore_reverse_proxy() {
  local mod_dir="$1"
  log_step "恢复反向代理配置..."

  # Nginx
  if [[ -f "${mod_dir}/nginx/etc_nginx.tar.gz" ]]; then
    log_info "  恢复 Nginx 配置..."
    if ! log_dry_run "恢复 Nginx"; then
      tar -xzf "${mod_dir}/nginx/etc_nginx.tar.gz" -C /etc 2>/dev/null || true
      if command -v nginx >/dev/null 2>&1; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
      fi
    fi
  fi

  # Caddy
  if [[ -f "${mod_dir}/caddy/etc_caddy.tar.gz" ]]; then
    log_info "  恢复 Caddy 配置..."
    if ! log_dry_run "恢复 Caddy"; then
      tar -xzf "${mod_dir}/caddy/etc_caddy.tar.gz" -C /etc 2>/dev/null || true
      systemctl reload caddy 2>/dev/null || true
    fi
  fi

  # Apache
  if [[ -f "${mod_dir}/apache/etc_apache2.tar.gz" ]]; then
    log_info "  恢复 Apache 配置..."
    if ! log_dry_run "恢复 Apache"; then
      tar -xzf "${mod_dir}/apache/etc_apache2.tar.gz" -C /etc 2>/dev/null || true
    fi
  fi

  summary_add "ok" "恢复反向代理" "配置已恢复"
}

_restore_database() {
  local mod_dir="$1"
  log_step "恢复数据库..."

  # MySQL
  if [[ -d "${mod_dir}/mysql" ]]; then
    for sql_file in "${mod_dir}/mysql"/*.sql; do
      [[ -f "${sql_file}" ]] || continue
      local fname
      fname="$(basename "${sql_file}")"
      log_info "  MySQL 恢复提示: ${fname}"
      log_info "    请手动执行: mysql -u root -p < ${sql_file}"
    done
  fi

  # PostgreSQL
  if [[ -d "${mod_dir}/postgres" ]]; then
    for sql_file in "${mod_dir}/postgres"/*.sql; do
      [[ -f "${sql_file}" ]] || continue
      local fname
      fname="$(basename "${sql_file}")"
      log_info "  PostgreSQL 恢复提示: ${fname}"
      log_info "    请手动执行: psql -U postgres < ${sql_file}"
    done
  fi

  # SQLite
  if [[ -d "${mod_dir}/sqlite" ]]; then
    if [[ -f "${mod_dir}/sqlite/_path_map.txt" ]]; then
      while IFS= read -r orig_path; do
        local safe_name
        safe_name="$(echo "${orig_path}" | tr '/' '_' | sed 's/^_//')"
        if [[ -f "${mod_dir}/sqlite/${safe_name}" ]]; then
          log_info "  恢复 SQLite: ${orig_path}"
          if ! log_dry_run "恢复 SQLite: ${orig_path}"; then
            safe_mkdir "$(dirname "${orig_path}")"
            cp -a "${mod_dir}/sqlite/${safe_name}" "${orig_path}" 2>/dev/null || true
          fi
        fi
      done < "${mod_dir}/sqlite/_path_map.txt"
    fi
  fi

  summary_add "ok" "恢复数据库" "已处理"
}

_restore_ssl_certs() {
  local mod_dir="$1"
  log_step "恢复 SSL 证书..."

  if [[ -f "${mod_dir}/letsencrypt.tar.gz" ]]; then
    log_info "  恢复 Let's Encrypt..."
    if ! log_dry_run "恢复 Let's Encrypt"; then
      tar -xzf "${mod_dir}/letsencrypt.tar.gz" -C /etc 2>/dev/null || true
    fi
  fi

  # acme.sh
  if [[ -f "${mod_dir}/_acme_paths.txt" ]]; then
    while IFS= read -r acme_path; do
      local safe_name
      safe_name="acme_$(echo "${acme_path}" | tr '/' '_' | sed 's/^_//')"
      if [[ -f "${mod_dir}/${safe_name}.tar.gz" ]]; then
        log_info "  恢复 acme.sh: ${acme_path}"
        if ! log_dry_run "恢复 acme.sh"; then
          safe_mkdir "$(dirname "${acme_path}")"
          tar -xzf "${mod_dir}/${safe_name}.tar.gz" -C "$(dirname "${acme_path}")" 2>/dev/null || true
        fi
      fi
    done < "${mod_dir}/_acme_paths.txt"
  fi

  summary_add "ok" "恢复 SSL" "证书已恢复"
}

_restore_crontab() {
  local mod_dir="$1"
  log_step "恢复 Crontab..."

  for cron_file in "${mod_dir}"/user_*.crontab; do
    [[ -f "${cron_file}" ]] || continue
    local username
    username="$(basename "${cron_file}" .crontab | sed 's/^user_//')"
    log_info "  恢复 ${username} 的 crontab"
    if ! log_dry_run "恢复 crontab: ${username}"; then
      crontab -u "${username}" "${cron_file}" 2>/dev/null || {
        log_warn "    ${username} 的 crontab 恢复失败"
      }
    fi
  done

  # 系统 cron 目录
  for cron_archive in "${mod_dir}"/*.tar.gz; do
    [[ -f "${cron_archive}" ]] || continue
    local dir_name
    dir_name="$(basename "${cron_archive}" .tar.gz)"
    log_info "  恢复系统 cron: ${dir_name}"
    if ! log_dry_run "恢复 ${dir_name}"; then
      tar -xzf "${cron_archive}" -C /etc 2>/dev/null || true
    fi
  done

  # /etc/crontab
  if [[ -f "${mod_dir}/crontab" ]]; then
    if ! log_dry_run "恢复 /etc/crontab"; then
      cp -a "${mod_dir}/crontab" /etc/crontab 2>/dev/null || true
    fi
  fi

  summary_add "ok" "恢复 Crontab" "已恢复"
}

_restore_firewall() {
  local mod_dir="$1"
  log_step "恢复防火墙规则..."

  if [[ -f "${mod_dir}/iptables.rules" ]]; then
    log_info "  恢复 iptables 规则"
    if ! log_dry_run "恢复 iptables"; then
      iptables-restore < "${mod_dir}/iptables.rules" 2>/dev/null || true
    fi
  fi

  if [[ -f "${mod_dir}/ip6tables.rules" ]]; then
    if ! log_dry_run "恢复 ip6tables"; then
      ip6tables-restore < "${mod_dir}/ip6tables.rules" 2>/dev/null || true
    fi
  fi

  if [[ -d "${mod_dir}" ]] && ls "${mod_dir}/etc_ufw.tar.gz" >/dev/null 2>&1; then
    log_info "  恢复 UFW 配置"
    if ! log_dry_run "恢复 UFW"; then
      tar -xzf "${mod_dir}/etc_ufw.tar.gz" -C /etc 2>/dev/null || true
      ufw reload 2>/dev/null || true
    fi
  fi

  if [[ -f "${mod_dir}/nftables.rules" ]]; then
    log_info "  恢复 nftables 规则"
    if ! log_dry_run "恢复 nftables"; then
      nft -f "${mod_dir}/nftables.rules" 2>/dev/null || true
    fi
  fi

  if ls "${mod_dir}/etc_firewalld.tar.gz" >/dev/null 2>&1; then
    log_info "  恢复 firewalld"
    if ! log_dry_run "恢复 firewalld"; then
      tar -xzf "${mod_dir}/etc_firewalld.tar.gz" -C /etc 2>/dev/null || true
      systemctl reload firewalld 2>/dev/null || true
    fi
  fi

  if ls "${mod_dir}/etc_fail2ban.tar.gz" >/dev/null 2>&1; then
    log_info "  恢复 fail2ban"
    if ! log_dry_run "恢复 fail2ban"; then
      tar -xzf "${mod_dir}/etc_fail2ban.tar.gz" -C /etc 2>/dev/null || true
      systemctl restart fail2ban 2>/dev/null || true
    fi
  fi

  summary_add "ok" "恢复防火墙" "规则已恢复"
}

_restore_user_home() {
  local mod_dir="$1"
  log_step "恢复用户目录..."

  for user_dir in "${mod_dir}"/*/; do
    [[ -d "${user_dir}" ]] || continue
    local username
    username="$(basename "${user_dir}")"

    if [[ ! -f "${user_dir}/user_info.env" ]]; then
      continue
    fi

    # shellcheck disable=SC1091
    source "${user_dir}/user_info.env" 2>/dev/null || continue
    local home="${HOME:-}"

    if [[ -z "${home}" ]]; then continue; fi

    log_info "  恢复用户: ${username} -> ${home}"

    if log_dry_run "恢复用户目录: ${username}"; then continue; fi

    safe_mkdir "${home}"

    # 还原 dotfiles
    find "${user_dir}" -maxdepth 2 -type f ! -name "user_info.env" ! -name "crontab.bak" | while read -r f; do
      local rel
      rel="$(realpath --relative-to="${user_dir}" "${f}" 2>/dev/null || echo "")"
      if [[ -n "${rel}" ]]; then
        local target="${home}/${rel}"
        safe_mkdir "$(dirname "${target}")"
        cp -a "${f}" "${target}" 2>/dev/null || true
      fi
    done

    # 修正所有权
    chown -R "${username}:" "${home}" 2>/dev/null || true
  done

  summary_add "ok" "恢复用户目录" "已恢复"
}

_restore_custom_paths() {
  local mod_dir="$1"
  log_step "恢复自定义路径..."

  if [[ ! -f "${mod_dir}/_path_map.txt" ]]; then
    return 0
  fi

  while IFS= read -r orig_path; do
    local safe_name
    safe_name="$(echo "${orig_path}" | tr '/' '_' | sed 's/^_//')"
    local archive="${mod_dir}/${safe_name}.tar.gz"
    local file="${mod_dir}/${safe_name}"

    log_info "  恢复: ${orig_path}"

    if log_dry_run "恢复自定义路径: ${orig_path}"; then continue; fi

    safe_mkdir "$(dirname "${orig_path}")"

    if [[ -f "${archive}" ]]; then
      tar -xzf "${archive}" -C "$(dirname "${orig_path}")" 2>/dev/null || true
    elif [[ -f "${file}" ]]; then
      cp -a "${file}" "${orig_path}" 2>/dev/null || true
    fi
  done < "${mod_dir}/_path_map.txt"

  summary_add "ok" "恢复自定义路径" "已恢复"
}
