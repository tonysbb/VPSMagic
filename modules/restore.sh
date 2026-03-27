#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 恢复总控模块
# ============================================================

[[ -n "${_MODULE_RESTORE_LOADED:-}" ]] && return 0
_MODULE_RESTORE_LOADED=1

_RESTORE_HEALTH_COMPOSE_DIRS=()
_RESTORE_HEALTH_SYSTEMD_SERVICES=()
_RESTORE_HEALTH_PROXY_SERVICES=()
_RESTORE_HEALTH_EXPECT_PROXY=0
_RESTORE_HEALTH_CHECK_USER_HOME=0
_RESTORE_APT_UPDATED=0
_RESTORE_SSH_PORTS=()

_reset_restore_health_checks() {
  _RESTORE_HEALTH_COMPOSE_DIRS=()
  _RESTORE_HEALTH_SYSTEMD_SERVICES=()
  _RESTORE_HEALTH_PROXY_SERVICES=()
  _RESTORE_HEALTH_EXPECT_PROXY=0
  _RESTORE_HEALTH_CHECK_USER_HOME=0
  _RESTORE_APT_UPDATED=0
  _RESTORE_SSH_PORTS=()
}

_append_unique_line() {
  local value="$1"
  shift
  local existing=""
  for existing in "$@"; do
    [[ "${existing}" == "${value}" ]] && return 0
  done
  return 1
}

_read_configured_ssh_ports() {
  local file=""
  local line=""
  local port=""

  for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r line; do
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      if [[ "${line}" =~ ^[[:space:]]*Port[[:space:]]+([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
        [[ -n "${port}" ]] && printf '%s\n' "${port}"
      fi
    done < "${file}"
  done
}

_snapshot_restore_ssh_ports() {
  local -a detected=()
  local line=""
  local port=""

  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ "${line}" == *"sshd"* ]] || continue
      if [[ "${line}" =~ (^|[:.])([0-9]+)[[:space:]] ]]; then
        port="${BASH_REMATCH[2]}"
        if [[ -n "${port}" ]] && ! _append_unique_line "${port}" "${detected[@]}"; then
          detected+=("${port}")
        fi
      fi
    done < <(ss -ltnp 2>/dev/null)
  fi

  if (( ${#detected[@]} == 0 )); then
    while IFS= read -r port; do
      [[ "${port}" =~ ^[0-9]+$ ]] || continue
      if ! _append_unique_line "${port}" "${detected[@]}"; then
        detected+=("${port}")
      fi
    done < <(_read_configured_ssh_ports)
  fi

  if (( ${#detected[@]} == 0 )); then
    detected=("22")
  fi

  _RESTORE_SSH_PORTS=("${detected[@]}")
}

_register_restore_compose_dir() {
  local dir="$1"
  [[ -n "${dir}" ]] || return 0
  if ! _append_unique_line "${dir}" "${_RESTORE_HEALTH_COMPOSE_DIRS[@]}"; then
    _RESTORE_HEALTH_COMPOSE_DIRS+=("${dir}")
  fi
}

_register_restore_systemd_service() {
  local svc="$1"
  [[ -n "${svc}" ]] || return 0
  if ! _append_unique_line "${svc}" "${_RESTORE_HEALTH_SYSTEMD_SERVICES[@]}"; then
    _RESTORE_HEALTH_SYSTEMD_SERVICES+=("${svc}")
  fi
}

_register_restore_proxy_service() {
  local svc="$1"
  [[ -n "${svc}" ]] || return 0
  if ! _append_unique_line "${svc}" "${_RESTORE_HEALTH_PROXY_SERVICES[@]}"; then
    _RESTORE_HEALTH_PROXY_SERVICES+=("${svc}")
  fi
}

_mark_restore_proxy_expected() {
  _RESTORE_HEALTH_EXPECT_PROXY=1
}

_systemd_unit_exists() {
  local unit="$1"
  [[ -n "${unit}" ]] || return 1

  if systemctl cat "${unit}" >/dev/null 2>&1; then
    return 0
  fi

  systemctl list-unit-files "${unit}.service" >/dev/null 2>&1
}

_ensure_restore_apt_index() {
  if (( _RESTORE_APT_UPDATED == 0 )); then
    apt-get update -qq >/dev/null 2>&1 || true
    _RESTORE_APT_UPDATED=1
  fi
}

_ensure_proxy_service_package() {
  local svc="$1"
  local pm=""
  local pkg=""

  pm="$(detect_pkg_manager)"
  case "${svc}:${pm}" in
    nginx:apt|nginx:dnf|nginx:yum|nginx:apk) pkg="nginx" ;;
    apache2:apt) pkg="apache2" ;;
    caddy:apt) pkg="caddy" ;;
    *) return 1 ;;
  esac

  if _systemd_unit_exists "${svc}"; then
    return 0
  fi

  log_info "  尝试安装代理服务包: ${pkg}"
  case "${pm}" in
    apt)
      _ensure_restore_apt_index
      apt-get install -y -qq "${pkg}" >/dev/null 2>&1 || return 1
      ;;
    dnf)
      dnf install -y -q "${pkg}" >/dev/null 2>&1 || return 1
      ;;
    yum)
      yum install -y -q "${pkg}" >/dev/null 2>&1 || return 1
      ;;
    apk)
      apk add --quiet "${pkg}" >/dev/null 2>&1 || return 1
      ;;
    *)
      return 1
      ;;
  esac

  _systemd_unit_exists "${svc}"
}

_preserve_ssh_access_after_firewall_restore() {
  local port=""
  local preserved=0

  for port in "${_RESTORE_SSH_PORTS[@]}"; do
    [[ "${port}" =~ ^[0-9]+$ ]] || continue

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
      ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
      iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT 1 -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
    fi

    if command -v ip6tables >/dev/null 2>&1; then
      ip6tables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || \
        ip6tables -I INPUT 1 -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
    fi

    ((preserved+=1))
  done

  if (( preserved > 0 )); then
    summary_add "ok" "恢复 SSH 访问" "$(lang_pick "保留端口" "preserved ports"): $(IFS=,; echo "${_RESTORE_SSH_PORTS[*]}")"
  else
    summary_add "warn" "恢复 SSH 访问" "$(lang_pick "未识别当前 SSH 端口" "current SSH ports not detected")"
  fi
}

_find_compose_file() {
  local project_dir="$1"
  local candidate=""
  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${project_dir}/${candidate}" ]]; then
      printf '%s\n' "${project_dir}/${candidate}"
      return 0
    fi
  done
  return 1
}

_port_is_listening() {
  local port="$1"
  [[ -n "${port}" ]] || return 1

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$"
  else
    return 1
  fi
}

_collect_proxy_listener_services() {
  local out_var="$1"
  local -a detected=()
  local line=""
  local source_cmd=""

  if command -v ss >/dev/null 2>&1; then
    source_cmd="ss -ltnp 2>/dev/null"
  elif command -v netstat >/dev/null 2>&1; then
    source_cmd="netstat -ltnp 2>/dev/null"
  else
    eval "${out_var}=()"
    return 0
  fi

  while IFS= read -r line; do
    [[ "${line}" =~ (^|[[:space:]])LISTEN([[:space:]]|$) ]] || continue
    [[ "${line}" =~ (^|[:.])(80|443)([[:space:]]|$) ]] || continue

    if [[ "${line}" == *"apache2"* ]]; then
      if ! _append_unique_line "apache2" "${detected[@]}"; then
        detected+=("apache2")
      fi
    fi
    if [[ "${line}" == *"nginx"* ]]; then
      if ! _append_unique_line "nginx" "${detected[@]}"; then
        detected+=("nginx")
      fi
    fi
    if [[ "${line}" == *"caddy"* ]]; then
      if ! _append_unique_line "caddy" "${detected[@]}"; then
        detected+=("caddy")
      fi
    fi
  done < <(eval "${source_cmd}")

  eval "${out_var}=(\"\${detected[@]}\")"
}

_collect_compose_published_ports() {
  local compose_project="$1"
  local out_var="$2"
  local -a collected=()
  local cid=""

  while IFS= read -r cid; do
    [[ -n "${cid}" ]] || continue
    while IFS= read -r mapping; do
      [[ -n "${mapping}" ]] || continue
      local host_part="${mapping##*->}"
      host_part="${host_part%%/*}"
      local host_port="${host_part##*:}"
      [[ "${host_port}" =~ ^[0-9]+$ ]] || continue
      if ! _append_unique_line "${host_port}" "${collected[@]}"; then
        collected+=("${host_port}")
      fi
    done < <(docker port "${cid}" 2>/dev/null | awk -F'[: ]+' 'NF {print $NF}' | grep -E '^[0-9]+$' || true)
  done < <(docker ps -q --filter "label=com.docker.compose.project=${compose_project}" 2>/dev/null)

  eval "${out_var}=(\"\${collected[@]}\")"
}

_run_restore_health_checks() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  log_step "$(lang_pick "恢复后健康检查..." "Post-restore health checks...")"

  local compose_dir=""
  for compose_dir in "${_RESTORE_HEALTH_COMPOSE_DIRS[@]}"; do
    local compose_file=""
    compose_file="$(_find_compose_file "${compose_dir}")"
    if [[ -z "${compose_file}" ]]; then
      summary_add "warn" "健康检查 / Docker Compose" "${compose_dir}: $(lang_pick "未找到 compose 文件" "compose file missing")"
      continue
    fi

    local expected_services="0"
    local running_services="0"
    expected_services="$(docker compose -f "${compose_file}" config --services 2>/dev/null | awk 'NF {count+=1} END {print count+0}')"
    running_services="$(docker compose -f "${compose_file}" ps --services --filter status=running 2>/dev/null | awk 'NF {count+=1} END {print count+0}')"
    if (( expected_services > 0 && running_services == expected_services )); then
      summary_add "ok" "健康检查 / Docker Compose" "$(basename "${compose_dir}"): ${running_services}/${expected_services} running"
    else
      summary_add "warn" "健康检查 / Docker Compose" "$(basename "${compose_dir}"): ${running_services}/${expected_services} running"
    fi

    local compose_project=""
    compose_project="$(basename "${compose_dir}")"
    local -a published_ports=()
    _collect_compose_published_ports "${compose_project}" published_ports
    if (( ${#published_ports[@]} > 0 )); then
      local port=""
      local -a listening_ports=()
      for port in "${published_ports[@]}"; do
        if _port_is_listening "${port}"; then
          listening_ports+=("${port}")
        fi
      done
      if (( ${#listening_ports[@]} == ${#published_ports[@]} )); then
        summary_add "ok" "健康检查 / Compose 端口" "${compose_project}: $(IFS=,; echo "${listening_ports[*]}")"
      else
        summary_add "warn" "健康检查 / Compose 端口" "${compose_project}: $(IFS=,; echo "${listening_ports[*]:-none}") / $(IFS=,; echo "${published_ports[*]}")"
      fi
    fi
  done

  local svc=""
  for svc in "${_RESTORE_HEALTH_SYSTEMD_SERVICES[@]}"; do
    local active_state=""
    active_state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
    if [[ "${active_state}" == "active" ]]; then
      summary_add "ok" "健康检查 / Systemd" "${svc}: active"
    else
      summary_add "warn" "健康检查 / Systemd" "${svc}: ${active_state:-unknown}"
    fi
  done

  local -a proxy_listener_svcs=()
  _collect_proxy_listener_services proxy_listener_svcs

  local active_proxy_count=0
  for svc in "${_RESTORE_HEALTH_PROXY_SERVICES[@]}"; do
    local active_state=""
    active_state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
    if [[ "${active_state}" == "active" ]]; then
      ((active_proxy_count+=1))
    elif _append_unique_line "${svc}" "${proxy_listener_svcs[@]}"; then
      ((active_proxy_count+=1))
    fi
  done

  for svc in "${_RESTORE_HEALTH_PROXY_SERVICES[@]}"; do
    local active_state=""
    active_state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
    if [[ "${active_state}" == "active" ]]; then
      summary_add "ok" "健康检查 / 反向代理" "${svc}: active"
    elif _append_unique_line "${svc}" "${proxy_listener_svcs[@]}"; then
      summary_add "ok" "健康检查 / 反向代理" "${svc}: $(lang_pick "监听 80/443" "listening on 80/443")"
    elif (( active_proxy_count > 0 )); then
      summary_add "skip" "健康检查 / 反向代理" "${svc}: $(lang_pick "配置已恢复，当前未启用" "restored but not enabled")"
    else
      summary_add "warn" "健康检查 / 反向代理" "${svc}: ${active_state:-unknown}"
    fi
  done

  local -a proxy_ports=()
  _port_is_listening 80 && proxy_ports+=("80")
  _port_is_listening 443 && proxy_ports+=("443")
  if (( _RESTORE_HEALTH_EXPECT_PROXY == 1 )); then
    if (( ${#proxy_ports[@]} > 0 )); then
      summary_add "ok" "健康检查 / 代理端口" "$(IFS=,; echo "${proxy_ports[*]}")"
    else
      summary_add "warn" "健康检查 / 代理端口" "$(lang_pick "80/443 未监听" "80/443 not listening")"
    fi
  fi

  if (( _RESTORE_HEALTH_CHECK_USER_HOME == 1 )) && command -v rclone >/dev/null 2>&1; then
    local remote_count="0"
    remote_count="$(rclone listremotes 2>/dev/null | awk 'NF {count+=1} END {print count+0}')"
    if (( remote_count > 0 )); then
      summary_add "ok" "健康检查 / rclone" "${remote_count} $(lang_pick "个 remote 可用" "remotes available")"
    else
      summary_add "warn" "健康检查 / rclone" "$(lang_pick "未发现可用 remote" "no remotes detected")"
    fi
  fi
}

_build_restore_rclone_opts() {
  local out_var="$1"
  eval "${out_var}=()"
  if [[ -n "${RCLONE_CONF:-}" && -f "${RCLONE_CONF}" ]]; then
    eval "${out_var}+=(\"--config\" \"\${RCLONE_CONF}\")"
  fi
}

_read_env_value() {
  local env_file="$1"
  local key="$2"
  [[ -f "${env_file}" ]] || return 1

  awk -F= -v target="${key}" '
    /^[[:space:]]*#/ { next }
    {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == target) {
        value=substr($0, index($0, "=") + 1)
        sub(/\r$/, "", value)
        print value
        exit
      }
    }
  ' "${env_file}" 2>/dev/null
}

_is_unsafe_tar_member() {
  local member="$1"
  member="${member#./}"
  case "${member}" in
    ""|.)
      return 1
      ;;
    /*|../*|*/../*|..|[A-Za-z]:/*|[A-Za-z]:\\*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_extract_tar_safe() {
  local archive="$1"
  local target_dir="$2"
  local label="${3:-tar}"

  if [[ ! -f "${archive}" ]]; then
    log_error "${label}: 文件不存在 (${archive})"
    return 1
  fi

  while IFS= read -r entry; do
    if _is_unsafe_tar_member "${entry}"; then
      log_error "${label}: 检测到不安全路径条目 (${entry})，拒绝解压"
      return 1
    fi
  done < <(tar -tzf "${archive}" 2>/dev/null) || {
    log_error "${label}: 无法读取归档目录 (${archive})"
    return 1
  }

  tar -xzf "${archive}" -C "${target_dir}" 2>/dev/null
}

_ensure_python_venv_support() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  local pm=""
  pm="$(detect_pkg_manager)"
  case "${pm}" in
    apt)
      if dpkg -s python3-venv >/dev/null 2>&1; then
        return 0
      fi
      log_info "    安装 python3-venv..."
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq python3-venv >/dev/null 2>&1
      ;;
    *)
      return 0
      ;;
  esac

  dpkg -s python3-venv >/dev/null 2>&1
}

run_restore() {
  _reset_restore_health_checks
  _snapshot_restore_ssh_ports
  # 本地文件恢复模式 (由 migrate 或 --local 触发)
  if [[ -n "${RESTORE_LOCAL_FILE:-}" ]]; then
    _restore_from_local "${RESTORE_LOCAL_FILE}"
    return $?
  fi

  local start_ts
  start_ts="$(date +%s)"

  log_banner "$(lang_pick "VPS Magic Backup — 恢复模式" "VPS Magic Backup — Restore Mode")"

  # ==================== 第1步: 列出可用备份 ====================
  log_step "$(lang_pick "第1步: 查找可用备份..." "Step 1: Find available backups...")"

  if ! command -v rclone >/dev/null 2>&1; then
    log_error "$(lang_pick "rclone 未安装。请先安装" "rclone is not installed. Install it first"): curl https://rclone.org/install.sh | sudo bash"
    return 1
  fi

  local -a restore_targets=()
  get_backup_targets restore_targets
  if [[ ${#restore_targets[@]} -eq 0 ]]; then
    log_error "$(lang_pick "未找到可用的远端恢复目标。请设置 BACKUP_TARGETS 或 RCLONE_REMOTE。" "No remote restore target found. Please set BACKUP_TARGETS or RCLONE_REMOTE.")"
    log_info "$(lang_pick "如果要从本地文件恢复，请使用" "To restore from a local file, use"): vpsmagic restore --local <file>"
    return 1
  fi

  local rclone_opts=()
  _build_restore_rclone_opts rclone_opts

  log_info "$(lang_pick "正在查询远端备份..." "Querying remote backups...")"
  local -a available_backups=()
  local -a available_backup_remotes=()
  local remote=""
  for remote in "${restore_targets[@]}"; do
    local -a remote_files=()
    while IFS= read -r fname; do
      fname="$(echo "${fname}" | xargs)"
      if [[ "${fname}" == *.tar.gz || "${fname}" == *.tar.gz.enc ]]; then
        remote_files+=("${fname}")
      fi
    done < <(rclone lsf "${remote}/" "${rclone_opts[@]}" --files-only 2>/dev/null | sort -r)

    if [[ ${#remote_files[@]} -eq 0 ]]; then
      continue
    fi

    for fname in "${remote_files[@]}"; do
      available_backups+=("${fname}")
      available_backup_remotes+=("${remote}")
    done
  done

  if [[ ${#available_backups[@]} -eq 0 ]]; then
    log_error "$(lang_pick "在所有候选远端中都没有找到备份文件。" "No backup files were found in any candidate remote.")"
    return 1
  fi

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "可用备份" "Available backups") ($(lang_pick "共" "total") ${#available_backups[@]} $(lang_pick "份" "files")):${_CLR_NC}"
  log_separator "─" 56
  local idx=1
  for bk in "${available_backups[@]}"; do
    local remote_for_bk="${available_backup_remotes[$((idx-1))]}"
    local size_info
    size_info="$(rclone size "${remote_for_bk}/${bk}" "${rclone_opts[@]}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*' || echo "")"
    local size_str=""
    if [[ -n "${size_info}" ]]; then
      size_str=" ($(human_size "${size_info}"))"
    fi
    printf "  %2d) [%s] %s%s\n" "${idx}" "${remote_for_bk}" "${bk}" "${size_str}"
    ((idx+=1))
  done
  log_separator "─" 56
  echo

  local selection=""
  read -r -p "$(lang_pick "请选择要恢复的备份编号" "Select the backup number to restore") [$(prompt_default_label): 1 ($(lang_pick "最新" "latest"))]: " selection
  selection="${selection:-1}"

  if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#available_backups[@]} )); then
    log_error "$(lang_pick "无效的选择" "Invalid selection"): ${selection}"
    return 1
  fi

  local selected="${available_backups[$((selection-1))]}"
  local selected_remote="${available_backup_remotes[$((selection-1))]}"
  log_info "$(lang_pick "选择恢复" "Selected for restore"): ${selected} ($(lang_pick "来源" "source"): ${selected_remote})"

  # ==================== 第2步: 下载备份 ====================
  log_step "$(lang_pick "第2步: 下载备份文件..." "Step 2: Download backup file...")"

  local restore_dir="${BACKUP_ROOT}/restore"
  safe_mkdir "${restore_dir}"

  local local_archive="${restore_dir}/${selected}"
  local sum_file="${restore_dir}/${selected}.sha256"

  if [[ -f "${local_archive}" ]]; then
    log_info "$(lang_pick "本地已存在该备份，跳过下载。" "The backup already exists locally. Skipping download.")"
    if ! confirm "$(lang_pick "是否重新下载覆盖？" "Re-download and overwrite it?")" "n"; then
      log_info "$(lang_pick "使用现有文件。" "Using the existing local file.")"
    else
      rm -f "${local_archive}" "${sum_file}"
    fi
  fi

  if [[ ! -f "${local_archive}" ]]; then
    if log_dry_run "$(lang_pick "下载" "Download") ${selected} <- ${selected_remote}"; then :; else
      rclone copy "${selected_remote}/${selected}" "${restore_dir}/" "${rclone_opts[@]}" --progress 2>&1 || {
        log_error "$(lang_pick "下载失败!" "Download failed!")"
        return 1
      }
      rclone copy "${selected_remote}/${selected}.sha256" "${restore_dir}/" "${rclone_opts[@]}" 2>/dev/null || true
      log_success "$(lang_pick "下载完成" "Download completed")"
    fi
  fi

  # ==================== 第3步: 校验 ====================
  log_step "$(lang_pick "第3步: 校验文件完整性..." "Step 3: Verify file integrity...")"

  if [[ -f "${sum_file}" ]]; then
    if verify_checksum "${local_archive}" "${sum_file}"; then
      log_success "$(lang_pick "SHA256 校验通过" "SHA256 verification passed")"
    else
      log_error "$(lang_pick "SHA256 校验失败! 文件可能已损坏。" "SHA256 verification failed. The file may be corrupted.")"
      if ! confirm "$(lang_pick "是否继续恢复（不推荐）？" "Continue restoring anyway? (not recommended)")" "n"; then
        return 1
      fi
    fi
  else
    log_warn "$(lang_pick "未找到校验文件，跳过校验。" "Checksum file not found. Skipping verification.")"
  fi

  # ==================== 第4步: 解密 (如果需要) ====================
  local archive_to_extract="${local_archive}"

  if [[ "${selected}" == *.enc ]]; then
      log_step "$(lang_pick "第4步: 解密备份..." "Step 4: Decrypt backup...")"
    if [[ -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
      read -rs -p "$(lang_pick "请输入解密密码" "Enter decryption password"): " BACKUP_ENCRYPTION_KEY
      echo
    fi
    local decrypted="${local_archive%.enc}"
    if log_dry_run "$(lang_pick "解密" "Decrypt") ${selected}"; then :; else
      if decrypt_file "${local_archive}" "${decrypted}" "${BACKUP_ENCRYPTION_KEY}"; then
        archive_to_extract="${decrypted}"
        log_success "$(lang_pick "解密成功" "Decryption succeeded")"
      else
        log_error "$(lang_pick "解密失败! 密码可能不正确。" "Decryption failed. The password may be incorrect.")"
        return 1
      fi
    fi
  fi

  # ==================== 第5步: 解压 ====================
  log_step "$(lang_pick "第5步: 解压备份..." "Step 5: Extract backup...")"

  local extract_dir="${restore_dir}/extracted"
  rm -rf "${extract_dir}" 2>/dev/null || true
  safe_mkdir "${extract_dir}"

  if log_dry_run "$(lang_pick "解压" "Extract") ${archive_to_extract}"; then :; else
    _extract_tar_safe "${archive_to_extract}" "${extract_dir}" "主备份包" || {
      log_error "$(lang_pick "解压失败!" "Extraction failed!")"
      return 1
    }
    log_success "$(lang_pick "解压完成" "Extraction completed")"
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
    log_info "$(lang_pick "备份信息" "Backup info"):"
    while IFS='=' read -r key value; do
      echo "  ${key}: ${value}"
    done < "${backup_data_dir}/manifest.txt"
    echo
  fi

  # ==================== 第6步: 确认恢复范围 ====================
  log_step "$(lang_pick "第6步: 确认恢复范围..." "Step 6: Confirm restore scope...")"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "备份包含以下模块" "Backup contains these modules"):${_CLR_NC}"
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

  if [[ "${RESTORE_AUTO_CONFIRM:-0}" != "1" ]]; then
    if ! confirm "$(lang_pick "确认开始恢复以上模块？（恢复前建议先备份当前环境）" "Confirm restoring the modules above? (back up the current environment first)")" "y"; then
      log_warn "$(lang_pick "用户取消恢复。" "Restore canceled by user.")"
      return 0
    fi
  else
    log_info "$(lang_pick "自动确认模式，跳过交互。" "Auto-confirm mode enabled. Skipping prompt.")"
  fi

  # ==================== 第7步: 执行恢复 ====================
  log_step "$(lang_pick "第7步: 执行恢复..." "Step 7: Run restore...")"

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
        log_warn "$(lang_pick "未知模块" "Unknown module") ${mod}，$(lang_pick "跳过。" "skipping.")"
        ;;
    esac
  done

  _run_restore_health_checks

  # ==================== 完成 ====================
  local end_ts
  end_ts="$(date +%s)"
  local elapsed
  elapsed="$(elapsed_time "${start_ts}" "${end_ts}")"

  echo
  log_separator "═" 56
  log_success "$(lang_pick "恢复完成!" "Restore completed!")"
  echo "  📦 $(lang_pick "恢复自" "Restored from"): ${selected}"
  echo "  ⏱  $(lang_pick "耗时" "Elapsed"): ${elapsed}"
  log_separator "═" 56
  echo

  summary_render
  notify_restore_result "${selected}" "${elapsed}"

  echo -e "${_CLR_BOLD}${_CLR_YELLOW}$(lang_pick "建议操作" "Recommended actions"):${_CLR_NC}"
  echo "  1. $(lang_pick "检查所有服务是否正常运行" "Check whether all services are running normally")"
  echo "  2. $(lang_pick "验证域名和 SSL 证书" "Verify domains and SSL certificates")"
  echo "  3. $(lang_pick "测试数据库连接" "Test database connections")"
  echo "  4. $(lang_pick "配置新的定时备份" "Configure scheduled backups"): vpsmagic schedule install"
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
    local backup_key
    backup_key="$(basename "${proj_dir}")"
    local compose_project_name="${backup_key}"
    [[ -f "${proj_dir}/_compose_project_name.txt" ]] && compose_project_name="$(cat "${proj_dir}/_compose_project_name.txt")"
    local original_path=""
    [[ -f "${proj_dir}/_original_path.txt" ]] && original_path="$(cat "${proj_dir}/_original_path.txt")"

    if [[ -z "${original_path}" ]]; then
      original_path="/opt/${compose_project_name}"
    fi

    log_info "  恢复项目: ${compose_project_name} (${backup_key}) -> ${original_path}"

    if log_dry_run "恢复 Docker Compose: ${compose_project_name}"; then continue; fi

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
        local full_vol="${compose_project_name}_${vol_name}"
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
            _extract_tar_safe "${proj_dir}/bind_mounts/${safe_name}.tar.gz" "$(dirname "${mount_src}")" "bind mount ${mount_src}" || {
              log_warn "    bind mount 目录恢复失败: ${mount_src}"
              continue
            }
            log_debug "    恢复 bind mount: ${mount_src}"
          elif [[ -f "${proj_dir}/bind_mounts/${safe_name}" ]]; then
            safe_mkdir "$(dirname "${mount_src}")"
            cp -a "${proj_dir}/bind_mounts/${safe_name}" "${mount_src}" 2>/dev/null || {
              log_warn "    bind mount 文件恢复失败: ${mount_src}"
              continue
            }
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

    # 启动项目（在权限恢复之后）
    log_info "  启动项目: ${compose_project_name}"
    (cd "${original_path}" && docker compose pull 2>/dev/null && docker compose up -d 2>/dev/null) || {
      log_warn "  项目 ${compose_project_name} 启动失败，请手动检查"
    }
    _register_restore_compose_dir "${original_path}"
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

  local manual_count=0
  for container_dir in "${mod_dir}"/*/; do
    [[ -d "${container_dir}" ]] || continue
    local name
    name="$(basename "${container_dir}")"

    if [[ ! -f "${container_dir}/metadata.env" ]]; then
      continue
    fi

    log_info "  恢复容器: ${name}"

    if log_dry_run "恢复独立容器: ${name}"; then continue; fi

    local image=""
    image="$(_read_env_value "${container_dir}/metadata.env" "IMAGE")"

    # 拉取镜像
    if [[ -n "${image}" ]]; then
      docker pull "${image}" 2>/dev/null || log_warn "    镜像拉取失败: ${image}"
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
    ((manual_count+=1))
  done

  if (( manual_count > 0 )); then
    summary_add "warn" "恢复独立容器" "${manual_count} 个容器需手动重建"
  else
    summary_add "skip" "恢复独立容器" "未发现可恢复容器"
  fi
}

_restore_systemd() {
  local mod_dir="$1"
  log_step "恢复 Systemd 服务..."
  local restored_count=0
  local warning_count=0

  for svc_dir in "${mod_dir}"/*/; do
    [[ -d "${svc_dir}" ]] || continue
    local svc_name
    svc_name="$(basename "${svc_dir}")"
    local svc_warn=0

    log_info "  恢复服务: ${svc_name}"
    _register_restore_systemd_service "${svc_name}"

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
        if ! _ensure_python_venv_support; then
          log_warn "    python3-venv 不可用，请先安装后再重建: apt-get install python3-venv"
          svc_warn=1
        else
          python3 -m venv "${venv_path}" 2>/dev/null || {
            log_warn "    venv 创建失败，请手动执行: python3 -m venv ${venv_path}"
            svc_warn=1
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
              svc_warn=1
            }
          fi
        fi
      else
        log_warn "    python3 未安装，请先安装后手动重建 venv"
        svc_warn=1
      fi
    fi

    # 读取状态
    if [[ -f "${svc_dir}/status.env" ]]; then
      local enabled_state=""
      enabled_state="$(_read_env_value "${svc_dir}/status.env" "ENABLED")"
      # 恢复启用状态
      systemctl daemon-reload 2>/dev/null || true
      if [[ "${enabled_state}" == "enabled" ]]; then
        systemctl enable "${svc_name}" 2>/dev/null || true
        systemctl start "${svc_name}" 2>/dev/null || {
          log_warn "    服务 ${svc_name} 启动失败"
          svc_warn=1
        }
      fi
    fi

    ((restored_count+=1))
    warning_count=$(( warning_count + svc_warn ))
  done

  systemctl daemon-reload 2>/dev/null || true
  if (( restored_count == 0 )); then
    summary_add "skip" "恢复 Systemd" "未发现可恢复服务"
  elif (( warning_count > 0 )); then
    summary_add "warn" "恢复 Systemd" "${restored_count} 个服务已处理，${warning_count} 个需手动检查"
  else
    summary_add "ok" "恢复 Systemd" "${restored_count} 个服务已恢复"
  fi
}

_restore_reverse_proxy() {
  local mod_dir="$1"
  log_step "恢复反向代理配置..."
  local restored_count=0
  local warning_count=0
  local deferred_count=0
  local auto_activate_proxy=0
  local enabled_state=""
  local active_state=""

  # Nginx
  if [[ -f "${mod_dir}/nginx/etc_nginx.tar.gz" ]]; then
    _mark_restore_proxy_expected
    _register_restore_proxy_service "nginx"
    log_info "  恢复 Nginx 配置..."
    if ! log_dry_run "恢复 Nginx"; then
      tar -xzf "${mod_dir}/nginx/etc_nginx.tar.gz" -C /etc 2>/dev/null || true
      enabled_state="$(_read_env_value "${mod_dir}/nginx/status.env" "ENABLED")"
      active_state="$(_read_env_value "${mod_dir}/nginx/status.env" "ACTIVE")"
      auto_activate_proxy=0
      [[ "${enabled_state}" == "enabled" || "${active_state}" == "active" ]] && auto_activate_proxy=1

      if (( auto_activate_proxy == 1 )) && ! _systemd_unit_exists "nginx"; then
        _ensure_proxy_service_package "nginx" || true
      fi
      if (( auto_activate_proxy == 1 )) && command -v nginx >/dev/null 2>&1 && _systemd_unit_exists "nginx"; then
        systemctl enable nginx 2>/dev/null || true
        if ! systemctl is-active nginx >/dev/null 2>&1; then
          systemctl start nginx 2>/dev/null || {
            log_warn "  Nginx 启动失败，请手动检查"
            ((warning_count+=1))
          }
        fi
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
      elif (( auto_activate_proxy == 1 )); then
        log_warn "  未发现 Nginx 服务单元，请手动检查"
        ((warning_count+=1))
      else
        log_info "  Nginx 在源机未启用，仅恢复配置"
        ((deferred_count+=1))
      fi
    fi
    ((restored_count+=1))
  fi

  # Caddy
  if [[ -f "${mod_dir}/caddy/etc_caddy.tar.gz" ]]; then
    _mark_restore_proxy_expected
    _register_restore_proxy_service "caddy"
    log_info "  恢复 Caddy 配置..."
    if ! log_dry_run "恢复 Caddy"; then
      tar -xzf "${mod_dir}/caddy/etc_caddy.tar.gz" -C /etc 2>/dev/null || true
      enabled_state="$(_read_env_value "${mod_dir}/caddy/status.env" "ENABLED")"
      active_state="$(_read_env_value "${mod_dir}/caddy/status.env" "ACTIVE")"
      auto_activate_proxy=0
      [[ "${enabled_state}" == "enabled" || "${active_state}" == "active" ]] && auto_activate_proxy=1

      if (( auto_activate_proxy == 1 )) && ! _systemd_unit_exists "caddy"; then
        _ensure_proxy_service_package "caddy" || true
      fi
      if (( auto_activate_proxy == 1 )) && _systemd_unit_exists "caddy"; then
        systemctl enable caddy 2>/dev/null || true
        if ! systemctl is-active caddy >/dev/null 2>&1; then
          systemctl start caddy 2>/dev/null || {
            log_warn "  Caddy 启动失败，请手动检查"
            ((warning_count+=1))
          }
        fi
        systemctl reload caddy 2>/dev/null || true
      elif (( auto_activate_proxy == 1 )); then
        log_warn "  未发现 Caddy 服务单元，请手动检查"
        ((warning_count+=1))
      else
        log_info "  Caddy 在源机未启用，仅恢复配置"
        ((deferred_count+=1))
      fi
    fi
    ((restored_count+=1))
  fi

  # Apache
  if [[ -f "${mod_dir}/apache/etc_apache2.tar.gz" ]]; then
    _mark_restore_proxy_expected
    _register_restore_proxy_service "apache2"
    log_info "  恢复 Apache 配置..."
    if ! log_dry_run "恢复 Apache"; then
      tar -xzf "${mod_dir}/apache/etc_apache2.tar.gz" -C /etc 2>/dev/null || true
      enabled_state="$(_read_env_value "${mod_dir}/apache/status.env" "ENABLED")"
      active_state="$(_read_env_value "${mod_dir}/apache/status.env" "ACTIVE")"
      auto_activate_proxy=0
      [[ "${enabled_state}" == "enabled" || "${active_state}" == "active" ]] && auto_activate_proxy=1

      if (( auto_activate_proxy == 1 )) && ! _systemd_unit_exists "apache2"; then
        _ensure_proxy_service_package "apache2" || true
      fi
      if (( auto_activate_proxy == 1 )) && _systemd_unit_exists "apache2"; then
        systemctl enable apache2 2>/dev/null || true
        if ! systemctl is-active apache2 >/dev/null 2>&1; then
          systemctl start apache2 2>/dev/null || {
            log_warn "  Apache 启动失败，请手动检查"
            ((warning_count+=1))
          }
        fi
        systemctl reload apache2 2>/dev/null || true
      elif (( auto_activate_proxy == 1 )); then
        log_warn "  未发现 Apache 服务单元，请手动检查"
        ((warning_count+=1))
      else
        log_info "  Apache 在源机未启用，仅恢复配置"
        ((deferred_count+=1))
      fi
    fi
    ((restored_count+=1))
  fi

  if (( restored_count == 0 )); then
    summary_add "skip" "恢复反向代理" "未发现可恢复配置"
  elif (( warning_count > 0 )); then
    summary_add "warn" "恢复反向代理" "${restored_count} 项已处理，${warning_count} 项需手动检查"
  elif (( deferred_count > 0 )); then
    summary_add "ok" "恢复反向代理" "${restored_count} 项配置已恢复，${deferred_count} 项未启用"
  else
    summary_add "ok" "恢复反向代理" "${restored_count} 项配置已恢复"
  fi
}

_restore_database() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复数据库..." "Restoring databases...")"

  # MySQL
  if [[ -d "${mod_dir}/mysql" ]]; then
    for sql_file in "${mod_dir}/mysql"/*.sql; do
      [[ -f "${sql_file}" ]] || continue
      local fname
      fname="$(basename "${sql_file}")"
      log_info "  $(lang_pick "MySQL 恢复提示" "MySQL restore hint"): ${fname}"
      log_info "    $(lang_pick "请手动执行" "Run manually"): mysql -u root -p < ${sql_file}"
    done
  fi

  # PostgreSQL
  if [[ -d "${mod_dir}/postgres" ]]; then
    for sql_file in "${mod_dir}/postgres"/*.sql; do
      [[ -f "${sql_file}" ]] || continue
      local fname
      fname="$(basename "${sql_file}")"
      log_info "  $(lang_pick "PostgreSQL 恢复提示" "PostgreSQL restore hint"): ${fname}"
      log_info "    $(lang_pick "请手动执行" "Run manually"): psql -U postgres < ${sql_file}"
    done
  fi

  # SQLite
  if [[ -d "${mod_dir}/sqlite" ]]; then
    if [[ -f "${mod_dir}/sqlite/_path_map.txt" ]]; then
      while IFS= read -r orig_path; do
        local safe_name
        safe_name="$(echo "${orig_path}" | tr '/' '_' | sed 's/^_//')"
        if [[ -f "${mod_dir}/sqlite/${safe_name}" ]]; then
          log_info "  $(lang_pick "恢复 SQLite" "Restoring SQLite"): ${orig_path}"
          if ! log_dry_run "$(lang_pick "恢复 SQLite" "Restore SQLite"): ${orig_path}"; then
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

  if ! log_dry_run "保留 SSH 访问"; then
    _preserve_ssh_access_after_firewall_restore
  fi

  summary_add "ok" "恢复防火墙" "规则已恢复"
}

_restore_user_home() {
  local mod_dir="$1"
  log_step "恢复用户目录..."
  local restored_users=0
  local restored_files=0

  for user_dir in "${mod_dir}"/*/; do
    [[ -d "${user_dir}" ]] || continue
    local username
    username="$(basename "${user_dir}")"
    local user_root="${user_dir%/}"

    if [[ ! -f "${user_dir}/user_info.env" ]]; then
      continue
    fi

    local home=""
    home="$(_read_env_value "${user_dir}/user_info.env" "HOME")"
    if [[ -z "${home}" ]]; then
      if [[ "${username}" == "root" ]]; then
        home="/root"
      else
        home="$(getent passwd "${username}" 2>/dev/null | cut -d: -f6)"
      fi
    fi

    if [[ -z "${home}" ]]; then continue; fi

    log_info "  恢复用户: ${username} -> ${home}"

    if log_dry_run "恢复用户目录: ${username}"; then continue; fi

    safe_mkdir "${home}"

    # 还原 dotfiles
    while IFS= read -r f; do
      local rel
      rel="$(relative_child_path "${user_root}" "${f}")"
      if [[ -n "${rel}" ]]; then
        local target="${home}/${rel}"
        if [[ "${rel}" == ".ssh/authorized_keys" ]]; then
          log_info "    保留当前 authorized_keys: ${target}"
          continue
        fi
        safe_mkdir "$(dirname "${target}")"
        cp -a "${f}" "${target}" 2>/dev/null || true
        ((restored_files+=1))
      fi
    done < <(find "${user_dir}" -type f ! -name "user_info.env" ! -name "crontab.bak")

    # 修正所有权
    chown -R "${username}:" "${home}" 2>/dev/null || true
    ((restored_users+=1))
    _RESTORE_HEALTH_CHECK_USER_HOME=1
  done

  if (( restored_users == 0 )); then
    summary_add "skip" "恢复用户目录" "未发现可恢复用户"
  else
    summary_add "ok" "恢复用户目录" "${restored_users} 个用户，${restored_files} 个文件"
  fi
}

_restore_custom_paths() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复自定义路径..." "Restoring custom paths...")"

  if [[ ! -f "${mod_dir}/_path_map.txt" ]]; then
    return 0
  fi

  while IFS= read -r orig_path; do
    local safe_name
    safe_name="$(echo "${orig_path}" | tr '/' '_' | sed 's/^_//')"
    local archive="${mod_dir}/${safe_name}.tar.gz"
    local file="${mod_dir}/${safe_name}"

    log_info "  $(lang_pick "恢复" "Restoring"): ${orig_path}"

    if log_dry_run "$(lang_pick "恢复自定义路径" "Restore custom path"): ${orig_path}"; then continue; fi

    safe_mkdir "$(dirname "${orig_path}")"

    if [[ -f "${archive}" ]]; then
      tar -xzf "${archive}" -C "$(dirname "${orig_path}")" 2>/dev/null || true
    elif [[ -f "${file}" ]]; then
      cp -a "${file}" "${orig_path}" 2>/dev/null || true
    fi
  done < "${mod_dir}/_path_map.txt"

  summary_add "ok" "恢复自定义路径" "已恢复"
}

# ==================== 本地文件恢复 (迁移模式) ====================

_restore_from_local() {
  local local_archive="$1"
  local start_ts
  start_ts="$(date +%s)"
  _reset_restore_health_checks
  _snapshot_restore_ssh_ports

  log_banner "$(lang_pick "VPS Magic Backup — 恢复模式 (本地文件)" "VPS Magic Backup — Restore Mode (Local File)")"

  if [[ ! -f "${local_archive}" ]]; then
    log_error "$(lang_pick "指定的本地备份文件不存在" "The specified local backup file does not exist"): ${local_archive}"
    return 1
  fi

  local selected
  selected="$(basename "${local_archive}")"
  local sum_file="${local_archive}.sha256"

  log_info "$(lang_pick "恢复文件" "Restore file"): ${selected}"
  log_info "$(lang_pick "文件大小" "File size"): $(human_size "$(get_file_size "${local_archive}")")"
  echo

  # ==================== 校验 ====================
  log_step "$(lang_pick "第1步: 校验文件完整性..." "Step 1: Verify file integrity...")"

  if [[ -f "${sum_file}" ]]; then
    if verify_checksum "${local_archive}" "${sum_file}"; then
      log_success "$(lang_pick "SHA256 校验通过" "SHA256 verification passed")"
    else
      log_error "$(lang_pick "SHA256 校验失败! 文件可能已损坏。" "SHA256 verification failed. The file may be corrupted.")"
      if [[ "${RESTORE_AUTO_CONFIRM:-0}" != "1" ]]; then
        if ! confirm "$(lang_pick "是否继续恢复（不推荐）？" "Continue restoring anyway? (not recommended)")" "n"; then
          return 1
        fi
      else
        log_warn "$(lang_pick "自动模式: 继续恢复" "Auto mode: continuing restore")"
      fi
    fi
  else
    log_warn "$(lang_pick "未找到校验文件，跳过校验。" "Checksum file not found. Skipping verification.")"
  fi

  # ==================== 解密 (如果需要) ====================
  local archive_to_extract="${local_archive}"

  if [[ "${selected}" == *.enc ]]; then
    log_step "$(lang_pick "第2步: 解密备份..." "Step 2: Decrypt backup...")"
    if [[ -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
      read -rs -p "$(lang_pick "请输入解密密码" "Enter decryption password"): " BACKUP_ENCRYPTION_KEY
      echo
    fi
    local decrypted="${local_archive%.enc}"
    if log_dry_run "解密 ${selected}"; then :; else
      if decrypt_file "${local_archive}" "${decrypted}" "${BACKUP_ENCRYPTION_KEY}"; then
        archive_to_extract="${decrypted}"
        log_success "$(lang_pick "解密成功" "Decryption succeeded")"
      else
        log_error "$(lang_pick "解密失败! 密码可能不正确。" "Decryption failed. The password may be incorrect.")"
        return 1
      fi
    fi
  fi

  # ==================== 解压 ====================
  log_step "$(lang_pick "第3步: 解压备份..." "Step 3: Extract backup...")"

  local restore_dir="${BACKUP_ROOT}/restore"
  safe_mkdir "${restore_dir}"
  local extract_dir="${restore_dir}/extracted"
  rm -rf "${extract_dir}" 2>/dev/null || true
  safe_mkdir "${extract_dir}"

  if log_dry_run "解压 ${archive_to_extract}"; then :; else
    _extract_tar_safe "${archive_to_extract}" "${extract_dir}" "主备份包" || {
      log_error "$(lang_pick "解压失败!" "Extraction failed!")"
      return 1
    }
    log_success "$(lang_pick "解压完成" "Extraction completed")"
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
    log_info "$(lang_pick "备份信息" "Backup info"):"
    while IFS='=' read -r key value; do
      echo "  ${key}: ${value}"
    done < "${backup_data_dir}/manifest.txt"
    echo
  fi

  # ==================== 确认恢复范围 ====================
  log_step "$(lang_pick "第4步: 确认恢复范围..." "Step 4: Confirm restore scope...")"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "备份包含以下模块" "Backup contains these modules"):${_CLR_NC}"
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

  if [[ "${RESTORE_AUTO_CONFIRM:-0}" != "1" ]]; then
    if ! confirm "$(lang_pick "确认开始恢复以上模块？（恢复前建议先备份当前环境）" "Confirm restoring the modules above? (back up the current environment first)")" "y"; then
      log_warn "$(lang_pick "用户取消恢复。" "Restore canceled by user.")"
      return 0
    fi
  else
    log_info "$(lang_pick "自动确认模式，开始恢复。" "Auto-confirm mode enabled. Starting restore.")"
  fi

  # ==================== 执行恢复 ====================
  log_step "$(lang_pick "第5步: 执行恢复..." "Step 5: Run restore...")"

  for mod in "${restore_modules[@]}"; do
    local mod_dir="${backup_data_dir}/${mod}"
    echo
    case "${mod}" in
      docker_compose)    _restore_docker_compose "${mod_dir}" ;;
      docker_standalone) _restore_docker_standalone "${mod_dir}" ;;
      systemd)           _restore_systemd "${mod_dir}" ;;
      reverse_proxy)     _restore_reverse_proxy "${mod_dir}" ;;
      database)          _restore_database "${mod_dir}" ;;
      ssl_certs)         _restore_ssl_certs "${mod_dir}" ;;
      crontab)           _restore_crontab "${mod_dir}" ;;
      firewall)          _restore_firewall "${mod_dir}" ;;
      user_home)         _restore_user_home "${mod_dir}" ;;
      custom_paths)      _restore_custom_paths "${mod_dir}" ;;
      *)                 log_warn "$(lang_pick "未知模块" "Unknown module") ${mod}，$(lang_pick "跳过。" "skipping.")" ;;
    esac
  done

  _run_restore_health_checks

  # ==================== 完成 ====================
  local end_ts
  end_ts="$(date +%s)"
  local elapsed
  elapsed="$(elapsed_time "${start_ts}" "${end_ts}")"

  echo
  log_separator "═" 56
  log_success "$(lang_pick "恢复完成! (本地文件模式)" "Restore completed! (local file mode)")"
  echo "  📦 $(lang_pick "恢复自" "Restored from"): ${selected}"
  echo "  ⏱  $(lang_pick "耗时" "Elapsed"): ${elapsed}"
  log_separator "═" 56
  echo

  summary_render
  notify_restore_result "${selected}" "${elapsed}"

  echo -e "${_CLR_BOLD}${_CLR_YELLOW}$(lang_pick "建议操作" "Recommended actions"):${_CLR_NC}"
  echo "  1. $(lang_pick "检查所有服务是否正常运行" "Check whether all services are running normally")"
  echo "  2. $(lang_pick "验证域名和 SSL 证书" "Verify domains and SSL certificates")"
  echo "  3. $(lang_pick "测试数据库连接" "Test database connections")"
  echo "  4. $(lang_pick "配置新的定时备份" "Configure scheduled backups"): vpsmagic schedule install"
  echo
}
