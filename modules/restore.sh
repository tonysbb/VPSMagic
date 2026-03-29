#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 恢复总控模块
# ============================================================

[[ -n "${_MODULE_RESTORE_LOADED:-}" ]] && return 0
_MODULE_RESTORE_LOADED=1

_RESTORE_HEALTH_COMPOSE_DIRS=()
_RESTORE_HEALTH_SYSTEMD_SERVICES=()
_RESTORE_HEALTH_SYSTEMD_MANUAL=()
_RESTORE_HEALTH_PROXY_SERVICES=()
_RESTORE_HEALTH_EXPECT_PROXY=0
_RESTORE_HEALTH_CHECK_USER_HOME=0
_RESTORE_APT_UPDATED=0
_RESTORE_SSH_PORTS=()
_RESTORE_PREFLIGHT_TARGETS=()
_RESTORE_PREFLIGHT_READY=()
_RESTORE_PREFLIGHT_ERRORS=()
_RESTORE_DOCKER_INSTALL_ERROR=""
_RESTORE_CADDY_TLS_SELF_HEAL_RAN=0

_reset_restore_health_checks() {
  _RESTORE_HEALTH_COMPOSE_DIRS=()
  _RESTORE_HEALTH_SYSTEMD_SERVICES=()
  _RESTORE_HEALTH_SYSTEMD_MANUAL=()
  _RESTORE_HEALTH_PROXY_SERVICES=()
  _RESTORE_HEALTH_EXPECT_PROXY=0
  _RESTORE_HEALTH_CHECK_USER_HOME=0
  _RESTORE_APT_UPDATED=0
  _RESTORE_SSH_PORTS=()
  _RESTORE_PREFLIGHT_TARGETS=()
  _RESTORE_PREFLIGHT_READY=()
  _RESTORE_PREFLIGHT_ERRORS=()
  _RESTORE_DOCKER_INSTALL_ERROR=""
  _RESTORE_CADDY_TLS_SELF_HEAL_RAN=0
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

_mark_restore_systemd_manual() {
  local svc="$1"
  [[ -n "${svc}" ]] || return 0
  if ! _append_unique_line "${svc}" "${_RESTORE_HEALTH_SYSTEMD_MANUAL[@]}"; then
    _RESTORE_HEALTH_SYSTEMD_MANUAL+=("${svc}")
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
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    _RESTORE_APT_UPDATED=1
  fi
}

_apt_package_available() {
  local pkg="$1"
  apt-cache show "${pkg}" >/dev/null 2>&1
}

_apt_install_noninteractive() {
  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@" >/dev/null 2>&1
}

_install_docker_via_official_repo() {
  local keyring_dir="/etc/apt/keyrings"
  local keyring_file="${keyring_dir}/docker.gpg"
  local list_file="/etc/apt/sources.list.d/docker.list"
  local arch=""
  local codename=""

  command -v apt-get >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v gpg >/dev/null 2>&1 || return 1
  command -v dpkg >/dev/null 2>&1 || return 1

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
  [[ -n "${codename}" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "${arch}" && -n "${codename}" ]] || return 1

  _ensure_restore_apt_index
  _apt_install_noninteractive ca-certificates curl gnupg lsb-release apt-transport-https || return 1

  install -m 0755 -d "${keyring_dir}" >/dev/null 2>&1 || return 1
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o "${keyring_file}" >/dev/null 2>&1 || return 1
  chmod 0644 "${keyring_file}" >/dev/null 2>&1 || true

  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/debian %s stable\n' \
    "${arch}" "${keyring_file}" "${codename}" > "${list_file}" || return 1

  _RESTORE_APT_UPDATED=0
  _ensure_restore_apt_index
  _apt_install_noninteractive docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
}

_install_caddy_via_official_repo() {
  local list_file="/etc/apt/sources.list.d/caddy-stable.list"
  local keyring_dir="/usr/share/keyrings"
  local keyring_file="${keyring_dir}/caddy-stable-archive-keyring.gpg"

  command -v apt-get >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v gpg >/dev/null 2>&1 || return 1

  _ensure_restore_apt_index
  _apt_install_noninteractive debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1

  install -m 0755 -d "${keyring_dir}" >/dev/null 2>&1 || return 1
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
    gpg --dearmor -o "${keyring_file}" >/dev/null 2>&1 || return 1
  chmod 0644 "${keyring_file}" >/dev/null 2>&1 || true

  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o "${list_file}" >/dev/null 2>&1 || return 1

  _RESTORE_APT_UPDATED=0
  _ensure_restore_apt_index
  _apt_install_noninteractive caddy || return 1
}

_maybe_repair_caddy_tls_state() {
  local since_ts="${1:-}"
  local backup_stamp=""
  local recent_logs=""
  local share_dir="/var/lib/caddy/.local/share/caddy"
  local autosave_file="/var/lib/caddy/.config/caddy/autosave.json"

  [[ -n "${since_ts}" ]] || return 0
  [[ "${_RESTORE_CADDY_TLS_SELF_HEAL_RAN}" == "1" ]] && return 0
  command -v journalctl >/dev/null 2>&1 || return 0
  systemctl is-active caddy >/dev/null 2>&1 || return 0

  sleep 5
  recent_logs="$(journalctl -u caddy --since "@${since_ts}" --no-pager 2>/dev/null || true)"
  case "${recent_logs}" in
    *"Unable to validate JWS"*|*"caddy_legacy_user_removed"*)
      ;;
    *)
      return 0
      ;;
  esac

  log_warn "  $(lang_pick "检测到 Caddy 证书状态异常，尝试一次性重建本机 TLS 状态" "Detected stale Caddy TLS state; attempting one local TLS state reset")"
  backup_stamp="$(date +%Y%m%d_%H%M%S)"
  if [[ -d "${share_dir}" ]]; then
    cp -a "${share_dir}" "${share_dir}.bak_${backup_stamp}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${autosave_file}" ]]; then
    cp -a "${autosave_file}" "${autosave_file}.bak_${backup_stamp}" >/dev/null 2>&1 || true
  fi

  rm -rf "${share_dir}" >/dev/null 2>&1 || true
  rm -f "${autosave_file}" >/dev/null 2>&1 || true
  _RESTORE_CADDY_TLS_SELF_HEAL_RAN=1

  if systemctl restart caddy >/dev/null 2>&1; then
    log_info "  $(lang_pick "已清理本机 Caddy TLS 状态并重启服务，等待重新签发证书" "Cleared local Caddy TLS state and restarted the service; waiting for certificate re-issuance")"
  else
    log_warn "  $(lang_pick "Caddy TLS 状态重建后重启失败，请手动检查 journalctl -u caddy" "Caddy restart failed after TLS state reset; inspect journalctl -u caddy manually")"
  fi
}

_ensure_rclone_installed() {
  if command -v rclone >/dev/null 2>&1; then
    return 0
  fi

  local pm=""
  pm="$(detect_pkg_manager)"
  log_info "  $(lang_pick "尝试安装 rclone..." "Attempting to install rclone...")"
  case "${pm}" in
    apt)
      _ensure_restore_apt_index
      if ! _apt_package_available "rclone"; then
        return 1
      fi
      _apt_install_noninteractive rclone || return 1
      ;;
    dnf)
      dnf install -y -q rclone >/dev/null 2>&1 || return 1
      ;;
    yum)
      yum install -y -q rclone >/dev/null 2>&1 || return 1
      ;;
    apk)
      apk add --quiet rclone >/dev/null 2>&1 || return 1
      ;;
    *)
      return 1
      ;;
  esac

  command -v rclone >/dev/null 2>&1
}

_ensure_docker_stack_installed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    _RESTORE_DOCKER_INSTALL_ERROR=""
    return 0
  fi

  local pm=""
  pm="$(detect_pkg_manager)"
  _RESTORE_DOCKER_INSTALL_ERROR=""
  log_info "  $(lang_pick "尝试安装 Docker / Compose..." "Attempting to install Docker / Compose...")"
  case "${pm}" in
    apt)
      _ensure_restore_apt_index
      _apt_install_noninteractive ca-certificates curl gnupg lsb-release >/dev/null 2>&1 || true
      if _apt_package_available "docker-ce" && _apt_package_available "docker-compose-plugin"; then
        if ! _apt_install_noninteractive docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
          _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "安装 docker-ce / docker-compose-plugin 失败" "failed to install docker-ce / docker-compose-plugin")"
          return 1
        fi
      elif _apt_package_available "docker.io" && _apt_package_available "docker-compose-plugin"; then
        if ! _apt_install_noninteractive docker.io docker-compose-plugin; then
          _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "安装 docker.io / docker-compose-plugin 失败" "failed to install docker.io / docker-compose-plugin")"
          return 1
        fi
      elif _apt_package_available "docker.io"; then
        log_info "  $(lang_pick "默认软件源只提供 docker.io，尝试添加 Docker 官方仓库" "Default package sources only provide docker.io; trying Docker's official repository")"
        if ! _install_docker_via_official_repo; then
          _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "APT 源只提供 docker.io，且切换到 Docker 官方仓库后仍无法安装 docker-compose-plugin。请检查网络或手动安装 Docker Compose。" "APT sources only provide docker.io, and docker-compose-plugin still could not be installed after switching to Docker's official repository. Check network access or install Docker Compose manually.")"
          return 1
        fi
      else
        log_info "  $(lang_pick "默认软件源未提供可用的 Docker 软件包，尝试添加 Docker 官方仓库" "Default package sources do not provide usable Docker packages; trying Docker's official repository")"
        if ! _install_docker_via_official_repo; then
          _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "APT 源未提供可用的 Docker / Docker Compose 软件包，且添加 Docker 官方仓库后安装仍失败" "APT sources do not provide usable Docker / Docker Compose packages, and installation still failed after adding Docker's official repository")"
          return 1
        fi
      fi
      ;;
    apk)
      apk add --quiet docker docker-cli-compose >/dev/null 2>&1 || {
        _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "安装 docker / docker-cli-compose 失败" "failed to install docker / docker-cli-compose")"
        return 1
      }
      ;;
    dnf|yum)
      if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        :
      else
        _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "当前发行版未实现自动安装，请先手动安装 Docker / Docker Compose" "automatic installation is not implemented for this distribution; install Docker / Docker Compose manually first")"
        return 1
      fi
      ;;
    *)
      _RESTORE_DOCKER_INSTALL_ERROR="$(lang_pick "当前包管理器不支持自动安装 Docker / Docker Compose" "automatic Docker / Docker Compose installation is not supported for this package manager")"
      return 1
      ;;
  esac

  systemctl enable --now docker >/dev/null 2>&1 || true
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    _RESTORE_DOCKER_INSTALL_ERROR=""
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    _RESTORE_DOCKER_INSTALL_ERROR="${_RESTORE_DOCKER_INSTALL_ERROR:-$(lang_pick "Docker 已安装，但 docker compose 子命令不可用" "Docker is installed, but the docker compose subcommand is unavailable")}"
  else
    _RESTORE_DOCKER_INSTALL_ERROR="${_RESTORE_DOCKER_INSTALL_ERROR:-$(lang_pick "Docker 安装后仍不可用" "Docker is still unavailable after installation")}"
  fi
  return 1
}

_manifest_display_key() {
  local key="$1"
  case "${key}" in
    backup_name) printf '%s\n' "$(lang_pick "备份名称" "backup_name")" ;;
    hostname) printf '%s\n' "$(lang_pick "主机名" "hostname")" ;;
    timestamp) printf '%s\n' "$(lang_pick "时间戳(UTC)" "timestamp")" ;;
    timestamp_local) printf '%s\n' "$(lang_pick "本地时间戳" "timestamp_local")" ;;
    kernel) printf '%s\n' "$(lang_pick "内核" "kernel")" ;;
    os) printf '%s\n' "$(lang_pick "系统" "os")" ;;
    vpsmagic_version) printf '%s\n' "$(lang_pick "VPS Magic 版本" "vpsmagic_version")" ;;
    ip_addresses) printf '%s\n' "$(lang_pick "IP 地址" "ip_addresses")" ;;
    docker_version) printf '%s\n' "$(lang_pick "Docker 版本" "docker_version")" ;;
    *) printf '%s\n' "${key}" ;;
  esac
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

  log_info "  $(lang_pick "尝试安装代理服务包" "Attempting to install proxy package"): ${pkg}"
  case "${pm}" in
    apt)
      _ensure_restore_apt_index
      if ! _apt_install_noninteractive "${pkg}"; then
        if [[ "${svc}" == "caddy" ]]; then
          log_info "  $(lang_pick "默认软件源未提供 caddy，尝试添加官方仓库" "Default package sources do not provide caddy; trying the official repository")"
          _install_caddy_via_official_repo || return 1
        else
          return 1
        fi
      fi
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

_restore_snapshot_root() {
  printf '%s\n' "${BACKUP_ROOT}/restore/snapshots"
}

_restore_rollback_scope_note() {
  printf '%s\n' "$(lang_pick "仅回滚配置级内容，不回滚卷数据、数据库结果或业务副作用" "configuration-only rollback; volumes, database results, and business side effects are not reverted")"
}

_collect_restore_snapshot_paths() {
  local backup_data_dir="$1"
  local out_var="$2"
  local -a collected=()
  local path=""

  for path in \
    /etc/caddy \
    /etc/nginx \
    /etc/apache2 \
    /etc/systemd/system \
    /etc/ufw \
    /etc/cron.d \
    /etc/cron.daily \
    /etc/cron.hourly \
    /etc/cron.monthly \
    /etc/cron.weekly
  do
    [[ -e "${path}" ]] || continue
    if ! _append_unique_line "${path}" "${collected[@]}"; then
      collected+=("${path}")
    fi
  done

  if [[ -d "${backup_data_dir}/docker_compose" ]]; then
    local proj_dir=""
    for proj_dir in "${backup_data_dir}/docker_compose"/*/; do
      [[ -d "${proj_dir}" ]] || continue
      local compose_project_name=""
      compose_project_name="$(basename "${proj_dir}")"
      [[ -f "${proj_dir}/_compose_project_name.txt" ]] && compose_project_name="$(cat "${proj_dir}/_compose_project_name.txt")"
      local original_path=""
      [[ -f "${proj_dir}/_original_path.txt" ]] && original_path="$(cat "${proj_dir}/_original_path.txt")"
      [[ -n "${original_path}" ]] || original_path="/opt/${compose_project_name}"

      local candidate=""
      for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env; do
        local file_path="${original_path}/${candidate}"
        [[ -e "${file_path}" ]] || continue
        if ! _append_unique_line "${file_path}" "${collected[@]}"; then
          collected+=("${file_path}")
        fi
      done
    done
  fi

  eval "${out_var}=(\"\${collected[@]}\")"
}

_create_restore_snapshot() {
  local backup_data_dir="$1"
  local selected_label="$2"
  local snapshot_root=""
  snapshot_root="$(_restore_snapshot_root)"
  safe_mkdir "${snapshot_root}"

  local safe_label=""
  safe_label="$(printf '%s' "$(basename "${selected_label}")" | tr '/: ' '___')"
  local snapshot_dir="${snapshot_root}/pre_restore_$(date +%Y%m%d_%H%M%S)_${safe_label}"
  safe_mkdir "${snapshot_dir}"

  local -a snapshot_paths=()
  _collect_restore_snapshot_paths "${backup_data_dir}" snapshot_paths

  if (( ${#snapshot_paths[@]} > 0 )); then
    tar -czf "${snapshot_dir}/filesystem.tar.gz" -P "${snapshot_paths[@]}" >/dev/null 2>&1 || true
  fi

  printf '%s\n' "$(_restore_rollback_scope_note)" > "${snapshot_dir}/rollback_scope.txt"
  if (( ${#snapshot_paths[@]} > 0 )); then
    printf '%s\n' "${snapshot_paths[@]}" | sort > "${snapshot_dir}/included_paths.txt"
  else
    : > "${snapshot_dir}/included_paths.txt"
  fi

  if command -v crontab >/dev/null 2>&1; then
    crontab -l > "${snapshot_dir}/root.crontab" 2>/dev/null || true
  fi

  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > "${snapshot_dir}/iptables.rules" 2>/dev/null || true
  fi

  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > "${snapshot_dir}/ip6tables.rules" 2>/dev/null || true
  fi

  if command -v nft >/dev/null 2>&1; then
    nft list ruleset > "${snapshot_dir}/nft.rules" 2>/dev/null || true
  fi

  {
    printf 'selected=%s\n' "${selected_label}"
    printf 'created_at=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
    printf 'paths=%s\n' "${#snapshot_paths[@]}"
    printf 'scope=%s\n' "$(_restore_rollback_scope_note)"
  } > "${snapshot_dir}/meta.env"

  printf '%s\n' "${snapshot_dir}"
}

_rollback_restore_snapshot() {
  local snapshot_dir="$1"
  local rc=0

  [[ -d "${snapshot_dir}" ]] || return 1

  if [[ -f "${snapshot_dir}/filesystem.tar.gz" ]]; then
    tar -xzf "${snapshot_dir}/filesystem.tar.gz" -P >/dev/null 2>&1 || rc=1
  fi

  if [[ -f "${snapshot_dir}/root.crontab" ]] && command -v crontab >/dev/null 2>&1; then
    crontab "${snapshot_dir}/root.crontab" >/dev/null 2>&1 || rc=1
  fi

  if [[ -f "${snapshot_dir}/iptables.rules" ]] && command -v iptables-restore >/dev/null 2>&1; then
    iptables-restore < "${snapshot_dir}/iptables.rules" >/dev/null 2>&1 || rc=1
  fi

  if [[ -f "${snapshot_dir}/ip6tables.rules" ]] && command -v ip6tables-restore >/dev/null 2>&1; then
    ip6tables-restore < "${snapshot_dir}/ip6tables.rules" >/dev/null 2>&1 || rc=1
  fi

  if [[ -f "${snapshot_dir}/nft.rules" ]] && command -v nft >/dev/null 2>&1; then
    nft -f "${snapshot_dir}/nft.rules" >/dev/null 2>&1 || rc=1
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw reload >/dev/null 2>&1 || true
  fi

  return "${rc}"
}

_restore_has_critical_failure() {
  local error_count=0
  error_count="$(summary_get_error_count)"
  if (( error_count > 0 )); then
    return 0
  fi

  local item=""
  local status=""
  local module=""
  for item in "${_SUMMARY_ITEMS[@]}"; do
    IFS='|' read -r status module _ <<< "${item}"
    [[ "${status}" == "warn" ]] || continue
    case "${module}" in
      "恢复 Docker Compose"|"恢复反向代理"|"恢复 Systemd"|\
      "健康检查 / Docker Compose"|"健康检查 / Compose 端口"|"健康检查 / Compose 出网"|\
      "健康检查 / Systemd"|"健康检查 / 反向代理"|"健康检查 / 代理端口")
        return 0
        ;;
    esac
  done

  return 1
}

_finalize_restore_result() {
  local selected="$1"
  local elapsed="$2"
  local snapshot_dir="$3"
  local success_banner="$4"
  local failure_banner="$5"

  local should_rollback=0
  local rollback_enabled="${RESTORE_ROLLBACK_ON_FAILURE:-false}"

  if _restore_has_critical_failure; then
    if [[ "$(_summary_count_status "error")" == "0" ]]; then
      summary_add "error" "恢复总体状态" "$(lang_pick "至少一个关键恢复步骤失败，详见上方日志" "at least one critical restore step failed; see logs above")"
    fi
    if [[ -z "${snapshot_dir}" || ! -d "${snapshot_dir}" ]]; then
      summary_add "warn" "恢复回滚" "$(lang_pick "未生成恢复前快照，无法自动回滚" "no pre-restore snapshot was created; automatic rollback is unavailable")"
    elif [[ "${rollback_enabled}" == "true" ]]; then
      should_rollback=1
      log_warn "$(lang_pick "检测到恢复失败，已根据参数自动执行轻量回滚。" "Restore failure detected. Lightweight rollback will run automatically because the flag is enabled.") $(lang_pick "注意" "Note"): $(_restore_rollback_scope_note)"
    elif [[ "${RESTORE_AUTO_CONFIRM:-0}" != "1" && -t 0 ]]; then
      if confirm "$(lang_pick "检测到恢复失败，是否执行轻量回滚？" "Restore failure detected. Run lightweight rollback?") $(lang_pick "注意" "Note"): $(_restore_rollback_scope_note)" "n"; then
        should_rollback=1
      fi
    fi

    if (( should_rollback == 1 )); then
      if _rollback_restore_snapshot "${snapshot_dir}"; then
        summary_add "warn" "恢复回滚" "$(lang_pick "已执行轻量回滚，请人工复核系统状态" "lightweight rollback completed; please review the system state manually"): $(_restore_rollback_scope_note)"
      else
        summary_add "error" "恢复回滚" "$(lang_pick "轻量回滚失败，请手动处理" "lightweight rollback failed; manual intervention required")"
      fi
    else
      if [[ -n "${snapshot_dir}" && -d "${snapshot_dir}" ]]; then
        summary_add "warn" "恢复回滚" "$(lang_pick "未执行自动回滚，配置级快照保留在" "automatic rollback not executed; configuration snapshot kept at"): ${snapshot_dir}"
      fi
    fi

    echo
    log_separator "═" 56
    log_error "${failure_banner}"
    echo "  📦 $(lang_pick "目标备份" "Backup"): ${selected}"
    echo "  ⏱  $(lang_pick "耗时" "Elapsed"): ${elapsed}"
    [[ -n "${snapshot_dir}" ]] && echo "  🧩 $(lang_pick "快照" "Snapshot"): ${snapshot_dir}"
    log_separator "═" 56
    echo

    summary_render
    notify_restore_result "${selected}" "${elapsed}"
    return 1
  fi

  if [[ -d "${snapshot_dir}" ]]; then
    if [[ "${RESTORE_AUTO_CONFIRM:-0}" != "1" && -t 0 ]]; then
      if confirm "$(lang_pick "恢复成功，是否删除本次配置级临时快照？" "Restore succeeded. Delete the temporary configuration snapshot?")" "y"; then
        rm -rf "${snapshot_dir}" 2>/dev/null || true
      fi
    fi
  fi

  echo
  log_separator "═" 56
  log_success "${success_banner}"
  echo "  📦 $(lang_pick "恢复自" "Restored from"): ${selected}"
  echo "  ⏱  $(lang_pick "耗时" "Elapsed"): ${elapsed}"
  log_separator "═" 56
  echo

  summary_render
  notify_restore_result "${selected}" "${elapsed}"
  return 0
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

_docker_exec_https_probe() {
  local container_name="$1"
  [[ -n "${container_name}" ]] || return 1

  if docker exec "${container_name}" sh -lc 'command -v curl >/dev/null 2>&1' >/dev/null 2>&1; then
    docker exec "${container_name}" sh -lc 'curl -fsSIL --max-time 8 https://www.cloudflare.com/cdn-cgi/trace >/dev/null' >/dev/null 2>&1
    return $?
  fi

  if docker exec "${container_name}" sh -lc 'command -v wget >/dev/null 2>&1' >/dev/null 2>&1; then
    docker exec "${container_name}" sh -lc 'wget -T 8 -q --spider https://www.cloudflare.com/cdn-cgi/trace' >/dev/null 2>&1
    return $?
  fi

  return 2
}

_collect_compose_container_names() {
  local compose_project="$1"
  local out_var="$2"
  local -a collected=()
  local container_name=""

  while IFS= read -r container_name; do
    [[ -n "${container_name}" ]] || continue
    collected+=("${container_name}")
  done < <(docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=${compose_project}" 2>/dev/null)

  eval "${out_var}=(\"\${collected[@]}\")"
}

_list_local_restore_candidates() {
  local out_var="$1"
  local -a ordered=()
  local -a dirs=(
    "${BACKUP_ROOT}/archives"
    "${BACKUP_ROOT}/restore"
  )
  local dir=""
  local file=""

  for dir in "${dirs[@]}"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      if ! _append_unique_line "${file}" "${ordered[@]}"; then
        ordered+=("${file}")
      fi
    done < <(list_archive_files_sorted "${dir}" "" "desc")
  done

  eval "${out_var}=(\"\${ordered[@]}\")"
}

_list_remote_backup_archives() {
  local remote="$1"
  local out_var="$2"
  local err_var="$3"
  local output=""
  local rc=0
  local -a collected=()
  local fname=""

  output="$(rclone lsf "${remote}/" --files-only 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf -v "${err_var}" '%s' "$(printf '%s\n' "${output}" | head -1)"
    eval "${out_var}=()"
    return "${rc}"
  fi

  while IFS= read -r fname; do
    fname="$(echo "${fname}" | xargs)"
    [[ -n "${fname}" ]] || continue
    if [[ "${fname}" == *.tar.gz || "${fname}" == *.tar.gz.enc ]]; then
      collected+=("${fname}")
    fi
  done <<< "$(printf '%s\n' "${output}" | sort -r)"

  printf -v "${err_var}" '%s' ""
  eval "${out_var}=(\"\${collected[@]}\")"
  return 0
}

_calculate_sha256() {
  local file="$1"
  [[ -f "${file}" ]] || return 1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" 2>/dev/null | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" 2>/dev/null | awk '{print $1}'
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "${file}" 2>/dev/null | awk '{print $NF}'
    return 0
  fi

  return 1
}

_read_remote_archive_checksum() {
  local remote_archive="$1"
  local out_var="$2"
  shift 2
  local output=""
  local checksum=""

  output="$(rclone cat "${remote_archive}.sha256" "$@" 2>/dev/null | head -1)" || true
  checksum="$(awk '{print $1}' <<< "${output}")"
  if [[ "${checksum}" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    checksum="${checksum,,}"
    printf -v "${out_var}" '%s' "${checksum}"
    return 0
  fi

  printf -v "${out_var}" '%s' ""
  return 1
}

_extract_rclone_remote_name() {
  vpsmagic_extract_rclone_remote_name "${1:-}"
}

_rclone_remote_exists() {
  local remote_name="$1"
  shift
  local line=""
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line%:}" == "${remote_name}" ]] && return 0
  done < <(rclone "$@" listremotes 2>/dev/null || true)
  return 1
}

_remote_uses_oci_credentials() {
  local remote_name="$1"
  shift
  vpsmagic_remote_uses_oci_credentials "${remote_name}" "$@"
}

_preflight_restore_remote_target() {
  local remote_target="$1"
  local err_var="$2"
  local -a rclone_opts=()
  _build_restore_rclone_opts rclone_opts

  local remote_name=""
  remote_name="$(_extract_rclone_remote_name "${remote_target}")"
  if [[ -z "${remote_name}" || "${remote_name}" == "${remote_target}" ]]; then
    printf -v "${err_var}" '%s' "$(lang_pick "远端路径格式无效，应为 remote:path" "invalid remote path format; expected remote:path")"
    return 1
  fi

  if ! _rclone_remote_exists "${remote_name}" "${rclone_opts[@]}"; then
    local conf_path="${RCLONE_CONF:-${HOME}/.config/rclone/rclone.conf}"
    printf -v "${err_var}" '%s' "$(lang_pick "未检测到 rclone remote 配置" "rclone remote is not configured"): ${remote_name} ($(lang_pick "配置文件" "config"): ${conf_path})$(lang_pick "。请先复制源机的 rclone.conf，或在目标机运行 rclone config，无法满足时改用 restore --local。" ". Copy the source host rclone.conf first, or run rclone config on the target host. If that is not possible, use restore --local instead.")"
    return 1
  fi

  local backend_type=""
  backend_type="$(vpsmagic_expected_backend_for_remote "${remote_name}" "${rclone_opts[@]}" 2>/dev/null || true)"
  if [[ -n "${backend_type}" ]] && ! vpsmagic_rclone_backend_supported "${backend_type}" "${rclone_opts[@]}"; then
    printf -v "${err_var}" '%s' "$(lang_pick "当前 rclone 不支持该远端 backend" "the current rclone build does not support this remote backend"): ${remote_name} (type=${backend_type})$(lang_pick "。请安装支持该 backend 的 rclone，或改用其他远端 / restore --local。" ". Install an rclone build that supports this backend, or use another remote / restore --local.")"
    return 1
  fi

  if _remote_uses_oci_credentials "${remote_name}" "${rclone_opts[@]}"; then
    local oci_conf="${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}"
    if [[ ! -f "${oci_conf}" ]]; then
      printf -v "${err_var}" '%s' "$(lang_pick "OCI 凭据缺失" "OCI credentials are missing"): ${oci_conf}$(lang_pick "。请先复制源机的 /root/.oci/config 和对应密钥，或改用其他远端/restore --local。" ". Copy /root/.oci/config and its key material from the source host first, or use another remote / restore --local.")"
      return 1
    fi
  fi

  printf -v "${err_var}" '%s' ""
  return 0
}

_store_restore_remote_preflight_result() {
  local target="$1"
  local ready="$2"
  local error_text="$3"
  _RESTORE_PREFLIGHT_TARGETS+=("${target}")
  _RESTORE_PREFLIGHT_READY+=("${ready}")
  _RESTORE_PREFLIGHT_ERRORS+=("${error_text}")
}

_get_restore_remote_preflight_result() {
  local target="$1"
  local ready_var="$2"
  local error_var="$3"
  local idx=0

  while (( idx < ${#_RESTORE_PREFLIGHT_TARGETS[@]} )); do
    if [[ "${_RESTORE_PREFLIGHT_TARGETS[$idx]}" == "${target}" ]]; then
      printf -v "${ready_var}" '%s' "${_RESTORE_PREFLIGHT_READY[$idx]}"
      printf -v "${error_var}" '%s' "${_RESTORE_PREFLIGHT_ERRORS[$idx]}"
      return 0
    fi
    ((idx+=1))
  done

  return 1
}

_run_restore_remote_preflight() {
  local targets_var="$1"
  local -n _targets="${targets_var}"
  local target=""
  local error_text=""
  local any_ready=0
  local any_problem=0

  for target in "${_targets[@]}"; do
    if _preflight_restore_remote_target "${target}" error_text; then
      _store_restore_remote_preflight_result "${target}" "1" ""
      any_ready=1
    else
      _store_restore_remote_preflight_result "${target}" "0" "${error_text}"
      any_problem=1
    fi
  done

  if (( any_problem == 1 )); then
    echo
    echo -e "${_CLR_BOLD}$(lang_pick "远端恢复前置检查" "Remote restore prerequisites"):${_CLR_NC}"
    log_separator "─" 56
    local idx=0
    while (( idx < ${#_RESTORE_PREFLIGHT_TARGETS[@]} )); do
      if [[ "${_RESTORE_PREFLIGHT_READY[$idx]}" == "1" ]]; then
        echo "  ✅ ${_RESTORE_PREFLIGHT_TARGETS[$idx]}"
      else
        echo "  ⚠️ ${_RESTORE_PREFLIGHT_TARGETS[$idx]}"
        echo "     ${_RESTORE_PREFLIGHT_ERRORS[$idx]}"
      fi
      ((idx+=1))
    done
    log_separator "─" 56
    echo "  $(lang_pick "无法满足前置条件时，可改用" "If prerequisites cannot be satisfied, use"): vpsmagic restore --local <file>"
    echo
  fi

  (( any_ready == 1 ))
}

_order_restore_modules() {
  local input_var="$1"
  local output_var="$2"
  local -n _restore_in="${input_var}"
  local -n _restore_out="${output_var}"
  local -a preferred_order=(
    crontab
    custom_paths
    firewall
    docker_compose
    docker_standalone
    reverse_proxy
    database
    ssl_certs
    systemd
    user_home
  )
  local -a ordered=()
  local preferred=""
  local existing=""

  for preferred in "${preferred_order[@]}"; do
    for existing in "${_restore_in[@]}"; do
      [[ "${existing}" == "${preferred}" ]] || continue
      ordered+=("${existing}")
      break
    done
  done

  for existing in "${_restore_in[@]}"; do
    if ! _append_unique_line "${existing}" "${ordered[@]}"; then
      ordered+=("${existing}")
    fi
  done

  _restore_out=("${ordered[@]}")
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

    local -a compose_containers=()
    _collect_compose_container_names "${compose_project}" compose_containers
    if (( ${#compose_containers[@]} > 0 )); then
      local probe_result=2
      local probe_container=""
      for probe_container in "${compose_containers[@]}"; do
        if _docker_exec_https_probe "${probe_container}"; then
          probe_result=0
        else
          probe_result=$?
        fi
        if (( probe_result == 0 || probe_result == 1 )); then
          break
        fi
      done

      if (( probe_result == 0 )); then
        summary_add "ok" "健康检查 / Compose 出网" "${compose_project}: ok"
      elif (( probe_result == 1 )); then
        summary_add "warn" "健康检查 / Compose 出网" "${compose_project}: $(lang_pick "容器内 HTTPS 出网失败，优先检查 Docker 网络" "container HTTPS egress failed; check Docker network first")"
      fi
    fi
  done

  local svc=""
  for svc in "${_RESTORE_HEALTH_SYSTEMD_SERVICES[@]}"; do
    if _append_unique_line "${svc}" "${_RESTORE_HEALTH_SYSTEMD_MANUAL[@]}"; then
      summary_add "skip" "健康检查 / Systemd" "${svc}: $(lang_pick "已恢复，切换后手动启动" "restored; start manually after cutover")"
      continue
    fi
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

  if (( _RESTORE_HEALTH_CHECK_USER_HOME == 1 )); then
    if command -v rclone >/dev/null 2>&1; then
      local remote_count="0"
      remote_count="$(rclone listremotes 2>/dev/null | awk 'NF {count+=1} END {print count+0}')"
      if (( remote_count > 0 )); then
        summary_add "ok" "健康检查 / rclone" "${remote_count} $(lang_pick "个 remote 可用" "remotes available")"
      else
        summary_add "warn" "健康检查 / rclone" "$(lang_pick "未发现可用 remote" "no remotes detected")"
      fi
    else
      summary_add "warn" "健康检查 / rclone" "$(lang_pick "rclone 未安装" "rclone not installed")"
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
    log_error "${label}: $(lang_pick "文件不存在" "file not found") (${archive})"
    return 1
  fi

  while IFS= read -r entry; do
    if _is_unsafe_tar_member "${entry}"; then
      log_error "${label}: $(lang_pick "检测到不安全路径条目，拒绝解压" "unsafe archive path detected; extraction refused") (${entry})"
      return 1
    fi
  done < <(tar -tzf "${archive}" 2>/dev/null) || {
    log_error "${label}: $(lang_pick "无法读取归档目录" "unable to read archive index") (${archive})"
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
      log_info "    $(lang_pick "安装 python3-venv..." "Installing python3-venv...")"
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq python3-venv >/dev/null 2>&1
      ;;
    *)
      return 0
      ;;
  esac

  dpkg -s python3-venv >/dev/null 2>&1
}

_prepare_python_requirement_file() {
  local source_file="$1"
  local target_file="$2"

  [[ -f "${source_file}" ]] || return 1
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    $0 == "pkg_resources==0.0.0" { next }
    { print }
  ' "${source_file}" > "${target_file}"
}

_systemd_service_requires_manual_start() {
  local svc_name="$1"
  local svc_dir="$2"

  if [[ -f "${svc_dir}/status.env" ]]; then
    local start_policy=""
    start_policy="$(_read_env_value "${svc_dir}/status.env" "START_POLICY")"
    [[ "${start_policy}" == "manual" ]] && return 0
  fi
  if [[ -f "${svc_dir}/requirements_freeze.txt" ]] && grep -qi '^python-telegram-bot==' "${svc_dir}/requirements_freeze.txt" 2>/dev/null; then
    return 0
  fi
  if [[ -f "${svc_dir}/requirements.txt" ]] && grep -qi '^python-telegram-bot==' "${svc_dir}/requirements.txt" 2>/dev/null; then
    return 0
  fi
  if [[ -f "${svc_dir}/_workdir_path.txt" ]] && grep -Eqi '/telegram[_-]?bot([/$]|$)' "${svc_dir}/_workdir_path.txt" 2>/dev/null; then
    return 0
  fi
  if [[ -f "${svc_dir}/_program_path.txt" ]] && grep -Eqi '/telegram[_-]?bot([/$]|$)' "${svc_dir}/_program_path.txt" 2>/dev/null; then
    return 0
  fi
  if [[ "${svc_name}" =~ (^|[-_])bot($|[-_]) ]] && [[ -f "${svc_dir}/requirements_freeze.txt" ]] && grep -qi '^python-telegram-bot==' "${svc_dir}/requirements_freeze.txt" 2>/dev/null; then
    return 0
  fi

  return 1
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
  local force_remote_search=0
  local has_explicit_remote_config=0
  if [[ -n "${BACKUP_REMOTE_OVERRIDE:-}" || -n "${BACKUP_TARGETS:-}" || -n "${RCLONE_REMOTE:-}" || -n "${BACKUP_PRIMARY_TARGET:-}" || -n "${BACKUP_ASYNC_TARGET:-}" ]]; then
    has_explicit_remote_config=1
  fi

  log_banner "$(lang_pick "VPS Magic Backup — 恢复模式" "VPS Magic Backup — Restore Mode")"

  # ==================== 第1步: 列出可用备份 ====================
  log_step "$(lang_pick "第1步: 查找可用备份..." "Step 1: Find available backups...")"

  local -a local_backups=()
  _list_local_restore_candidates local_backups
  if (( ${#local_backups[@]} > 0 )); then
    echo
    echo -e "${_CLR_BOLD}$(lang_pick "本地可用备份" "Available local backups") ($(lang_pick "共" "total") ${#local_backups[@]} $(lang_pick "份" "files")):${_CLR_NC}"
    log_separator "─" 56
    local idx=1
    local local_bk=""
    for local_bk in "${local_backups[@]}"; do
      printf "  %2d) %s (%s)\n" "${idx}" "$(basename "${local_bk}")" "$(dirname "${local_bk}")"
      ((idx+=1))
    done
    log_separator "─" 56
    echo

    echo "   0) $(lang_pick "搜索云端最新备份" "Search remote backups instead")"
    log_separator "─" 56
    echo

    local local_selection=""
    read -r -p "$(lang_pick "请选择本地备份编号" "Select the local backup") [$(prompt_default_label): 1 ($(lang_pick "最新" "latest")), 0=$(lang_pick "云端" "remote")]: " local_selection
    local_selection="${local_selection:-1}"
    if ! [[ "${local_selection}" =~ ^[0-9]+$ ]] || (( local_selection < 0 || local_selection > ${#local_backups[@]} )); then
      log_error "$(lang_pick "无效的选择" "Invalid selection"): ${local_selection}"
      return 1
    fi

    if (( local_selection == 0 )); then
      log_info "$(lang_pick "已切换为搜索云端备份。" "Switching to remote backup search.")"
      force_remote_search=1
    else
      local selected_local_archive="${local_backups[$((local_selection-1))]}"
      log_info "$(lang_pick "选择本地恢复" "Selected local restore"): ${selected_local_archive}"
      _restore_from_local "${selected_local_archive}"
      return $?
    fi
  fi

  if (( force_remote_search == 0 )) && (( has_explicit_remote_config == 0 )) && [[ "${RESTORE_AUTO_CONFIRM:-0}" != "1" ]]; then
    if ! confirm "$(lang_pick "未找到本地备份，是否搜索云端备份？" "No local backup found. Search remote backups?")" "y"; then
      log_warn "$(lang_pick "用户取消恢复。" "Restore canceled by user.")"
      return 0
    fi
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    if ! _ensure_rclone_installed; then
      log_error "$(lang_pick "rclone 未安装且自动安装失败。" "rclone is not installed and automatic installation failed.")"
      log_info "  $(lang_pick "安装" "Install"): curl https://rclone.org/install.sh | sudo bash"
      return 1
    fi
  fi

  local -a restore_targets=()
  get_restore_targets restore_targets
  if [[ ${#restore_targets[@]} -eq 0 ]]; then
    log_error "$(lang_pick "未找到可用的远端恢复目标。请设置 BACKUP_TARGETS 或 RCLONE_REMOTE。" "No remote restore target found. Please set BACKUP_TARGETS or RCLONE_REMOTE.")"
    log_info "$(lang_pick "如果要从本地文件恢复，请使用" "To restore from a local file, use"): vpsmagic restore --local <file>"
    return 1
  fi

  local rclone_opts=()
  _build_restore_rclone_opts rclone_opts

  local -a ready_restore_targets=()
  local selected_restore_remote=""
  local preferred_restore_remote=""
  preferred_restore_remote="$(get_restore_primary_target)"
  if ! _run_restore_remote_preflight restore_targets; then
    log_error "$(lang_pick "所有远端恢复目标都未通过前置检查。" "No remote restore target passed the prerequisite checks.")"
    log_info "$(lang_pick "如果要从本地文件恢复，请使用" "To restore from a local file, use"): vpsmagic restore --local <file>"
    return 1
  fi

  ready_restore_targets=()
  for ready_target in "${restore_targets[@]}"; do
    local ready_flag=""
    local ready_error=""
    if _get_restore_remote_preflight_result "${ready_target}" ready_flag ready_error && [[ "${ready_flag}" == "1" ]]; then
      ready_restore_targets+=("${ready_target}")
    fi
  done

  local interactive_targets="${BACKUP_INTERACTIVE_TARGETS:-true}"
  if [[ "${interactive_targets}" == "true" && -t 0 && ${#ready_restore_targets[@]} -gt 0 ]]; then
    echo
    echo -e "${_CLR_BOLD}$(lang_pick "可用远端恢复路径" "Available remote restore targets"):${_CLR_NC}"
    log_separator "─" 56
    local idx=1
    local default_index=1
    for remote in "${ready_restore_targets[@]}"; do
      printf "  %2d) %s\n" "${idx}" "${remote}"
      if [[ -n "${preferred_restore_remote}" && "${remote}" == "${preferred_restore_remote}" ]]; then
        default_index="${idx}"
      fi
      ((idx+=1))
    done
    log_separator "─" 56
    echo

    local remote_selection=""
    read -r -p "$(lang_pick "请选择恢复远端编号" "Select the restore remote") [$(prompt_default_label): ${default_index}]: " remote_selection
    remote_selection="${remote_selection:-${default_index}}"
    if ! [[ "${remote_selection}" =~ ^[0-9]+$ ]] || (( remote_selection < 1 || remote_selection > ${#ready_restore_targets[@]} )); then
      log_error "$(lang_pick "无效的选择" "Invalid selection"): ${remote_selection}"
      return 1
    fi
    selected_restore_remote="${ready_restore_targets[$((remote_selection-1))]}"
  elif [[ -n "${preferred_restore_remote}" ]]; then
    selected_restore_remote="${preferred_restore_remote}"
  else
    selected_restore_remote="${ready_restore_targets[0]}"
  fi

  if ! _append_unique_line "${selected_restore_remote}" "${ready_restore_targets[@]}"; then
    selected_restore_remote="${ready_restore_targets[0]}"
  fi

  log_info "$(lang_pick "正在查询远端备份..." "Querying remote backups...")"
  local -a available_backups=()
  local -a available_backup_remotes=()
  local -a remote_search_order=()
  local primary_remote_problem=0
  remote_search_order+=("${selected_restore_remote}")
  for remote in "${ready_restore_targets[@]}"; do
    if [[ "${remote}" != "${selected_restore_remote}" ]]; then
      remote_search_order+=("${remote}")
    fi
  done

  for remote in "${remote_search_order[@]}"; do
    local -a remote_files=()
    local remote_error=""
    local remote_ready=""
    if _get_restore_remote_preflight_result "${remote}" remote_ready remote_error && [[ "${remote_ready}" != "1" ]]; then
      if [[ "${remote}" == "${selected_restore_remote}" ]]; then
        primary_remote_problem=1
      fi
      continue
    fi
    if ! _list_remote_backup_archives "${remote}" remote_files remote_error; then
      log_warn_soft "$(lang_pick "远端访问失败" "Remote access failed"): ${remote}"
      [[ -n "${remote_error}" ]] && log_warn_soft "  ${remote_error}"
      if [[ "${remote}" == "${selected_restore_remote}" ]]; then
        primary_remote_problem=1
      fi
      continue
    fi

    for fname in "${remote_files[@]}"; do
      available_backups+=("${fname}")
      available_backup_remotes+=("${remote}")
    done

    if (( ${#available_backups[@]} > 0 )); then
      if [[ "${remote}" != "${selected_restore_remote}" ]]; then
        if (( primary_remote_problem == 1 )); then
          log_info "$(lang_pick "主远端不可用，已切换到" "Primary remote unavailable. Falling back to"): ${remote}"
        else
          log_info "$(lang_pick "主远端无备份，已切换到" "No backup found in the primary remote. Falling back to"): ${remote}"
        fi
      fi
      break
    fi
  done

  if [[ ${#available_backups[@]} -eq 0 ]]; then
    log_error "$(lang_pick "所有候选远端均未找到备份文件。" "No backup files were found in any candidate remote.")"
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
  local skip_download=0

  if [[ -f "${local_archive}" ]]; then
    local remote_checksum=""
    local local_checksum=""
    if _read_remote_archive_checksum "${selected_remote}/${selected}" remote_checksum "${rclone_opts[@]}"; then
      local_checksum="$(_calculate_sha256 "${local_archive}" 2>/dev/null || true)"
      if [[ -n "${local_checksum}" && "${local_checksum,,}" == "${remote_checksum}" ]]; then
        skip_download=1
        [[ -f "${sum_file}" ]] || printf '%s  %s\n' "${remote_checksum}" "$(basename "${local_archive}")" > "${sum_file}"
        log_info "$(lang_pick "本地已存在同名备份且与远端校验一致，直接复用。" "A local backup with the same name already exists and matches the remote checksum. Reusing it directly.")"
      fi
    fi

    if (( skip_download == 0 )); then
      log_info "$(lang_pick "本地已存在该备份。" "The backup already exists locally.")"
      if ! confirm "$(lang_pick "是否重新下载覆盖？" "Re-download and overwrite it?")" "n"; then
        log_info "$(lang_pick "使用现有文件。" "Using the existing local file.")"
        skip_download=1
      else
        rm -f "${local_archive}" "${sum_file}"
      fi
    fi
  fi

  if (( skip_download == 0 )) && [[ ! -f "${local_archive}" ]]; then
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
      echo "  $(_manifest_display_key "${key}"): ${value}"
    done < "${backup_data_dir}/manifest.txt"
    echo
  fi

  # ==================== 第6步: 确认恢复范围 ====================
  log_step "$(lang_pick "第6步: 确认恢复范围..." "Step 6: Confirm restore scope...")"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "备份包含以下模块" "Backup contains these modules"):${_CLR_NC}"
  local -a restore_modules=()
  local -a ordered_restore_modules=()
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
    if ! confirm_exact "$(lang_pick "输入 yes 确认开始恢复（恢复前建议先备份当前环境）" "Type yes to start the restore (back up the current environment first)")" "yes"; then
      log_warn "$(lang_pick "用户取消恢复。" "Restore canceled by user.")"
      return 0
    fi
  else
    log_info "$(lang_pick "自动确认模式，跳过交互。" "Auto-confirm mode enabled. Skipping prompt.")"
  fi

  _order_restore_modules restore_modules ordered_restore_modules

  local snapshot_dir=""
  snapshot_dir="$(_create_restore_snapshot "${backup_data_dir}" "${selected}")"
  [[ -n "${snapshot_dir}" ]] && log_info "$(lang_pick "已创建恢复前轻量快照" "Created lightweight pre-restore snapshot"): ${snapshot_dir}"

  # ==================== 第7步: 执行恢复 ====================
  log_step "$(lang_pick "第7步: 执行恢复..." "Step 7: Run restore...")"

  for mod in "${ordered_restore_modules[@]}"; do
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
  _finalize_restore_result \
    "${selected}" \
    "${elapsed}" \
    "${snapshot_dir}" \
    "$(lang_pick "恢复完成!" "Restore completed!")" \
    "$(lang_pick "恢复失败!" "Restore failed!")" || return 1

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
  log_step "$(lang_pick "恢复 Docker Compose 项目..." "Restoring Docker Compose projects...")"

  if ! command -v docker >/dev/null 2>&1; then
    if ! _ensure_docker_stack_installed; then
      log_warn "$(lang_pick "Docker 未安装且自动安装失败，请先安装 Docker。" "Docker is not installed and automatic installation failed. Please install Docker first.") ${_RESTORE_DOCKER_INSTALL_ERROR:+($(lang_pick "原因" "reason"): ${_RESTORE_DOCKER_INSTALL_ERROR})}"
      summary_add "warn" "恢复 Docker Compose" "$(lang_pick "Docker 未安装且自动安装失败" "Docker is not installed and automatic installation failed")${_RESTORE_DOCKER_INSTALL_ERROR:+; ${_RESTORE_DOCKER_INSTALL_ERROR}}"
      return 0
    fi
  fi

  if ! docker compose version >/dev/null 2>&1; then
    if ! _ensure_docker_stack_installed; then
      log_warn "$(lang_pick "Docker Compose 不可用且自动安装失败，请先安装 Docker Compose。" "Docker Compose is unavailable and automatic installation failed. Please install Docker Compose first.") ${_RESTORE_DOCKER_INSTALL_ERROR:+($(lang_pick "原因" "reason"): ${_RESTORE_DOCKER_INSTALL_ERROR})}"
      summary_add "warn" "恢复 Docker Compose" "$(lang_pick "Docker Compose 不可用且自动安装失败" "Docker Compose is unavailable and automatic installation failed")${_RESTORE_DOCKER_INSTALL_ERROR:+; ${_RESTORE_DOCKER_INSTALL_ERROR}}"
      return 0
    fi
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

    log_info "  $(lang_pick "恢复项目" "Restoring project"): ${compose_project_name} (${backup_key}) -> ${original_path}"

    if log_dry_run "$(lang_pick "恢复 Docker Compose" "Restore Docker Compose"): ${compose_project_name}"; then continue; fi

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
        log_debug "    $(lang_pick "恢复卷" "Restoring volume"): ${vol_name}"
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
              log_warn "    $(lang_pick "bind mount 目录恢复失败" "Bind mount directory restore failed"): ${mount_src}"
              continue
            }
            log_debug "    $(lang_pick "恢复 bind mount" "Restoring bind mount"): ${mount_src}"
          elif [[ -f "${proj_dir}/bind_mounts/${safe_name}" ]]; then
            safe_mkdir "$(dirname "${mount_src}")"
            cp -a "${proj_dir}/bind_mounts/${safe_name}" "${mount_src}" 2>/dev/null || {
              log_warn "    $(lang_pick "bind mount 文件恢复失败" "Bind mount file restore failed"): ${mount_src}"
              continue
            }
            log_debug "    $(lang_pick "恢复 bind mount" "Restoring bind mount"): ${mount_src}"
          fi
        done < "${proj_dir}/bind_mounts/_mount_map.txt"
      fi
    fi

    # 还原项目配置文件
    if [[ -d "${proj_dir}/project_configs" ]]; then
      cp -a "${proj_dir}/project_configs/." "${original_path}/" 2>/dev/null || true
      log_debug "    $(lang_pick "恢复项目配置文件" "Restored project config files")"
    fi

    # 恢复文件权限 (关键: 如 aria2 temp 需要 65534:65534 uid:gid)
    if [[ -f "${proj_dir}/_permissions.txt" ]]; then
      log_info "  $(lang_pick "恢复文件权限..." "Restoring file permissions...")"
      while IFS=' ' read -r perms owner path; do
        [[ "${perms}" =~ ^[0-9]+$ ]] || continue
        [[ -e "${path}" ]] || continue
        chmod "${perms}" "${path}" 2>/dev/null || true
        chown "${owner}" "${path}" 2>/dev/null || true
      done < <(grep -v '^#' "${proj_dir}/_permissions.txt" 2>/dev/null)
      log_debug "    $(lang_pick "权限已恢复" "Permissions restored")"
    fi

    # 启动项目（在权限恢复之后）
    log_info "  $(lang_pick "启动项目" "Starting project"): ${compose_project_name}"
    (
      cd "${original_path}" && \
      docker compose down --remove-orphans 2>/dev/null || true
    )
    log_info "  $(lang_pick "重建默认网络" "Recreating default network"): ${compose_project_name}_default"
    docker network rm "${compose_project_name}_default" >/dev/null 2>&1 || true
    (cd "${original_path}" && docker compose pull 2>/dev/null && docker compose up -d --force-recreate 2>/dev/null) || {
      log_warn "  $(lang_pick "项目启动失败，请手动检查" "Project failed to start. Please inspect it manually"): ${compose_project_name}"
    }
    _register_restore_compose_dir "${original_path}"
  done

  summary_add "ok" "恢复 Docker Compose" "已恢复"
}

_restore_docker_standalone() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复独立 Docker 容器..." "Restoring standalone Docker containers...")"

  if ! command -v docker >/dev/null 2>&1; then
    if ! _ensure_docker_stack_installed; then
      summary_add "warn" "恢复独立容器" "Docker 未安装且自动安装失败"
      return 0
    fi
  fi

  local manual_count=0
  for container_dir in "${mod_dir}"/*/; do
    [[ -d "${container_dir}" ]] || continue
    local name
    name="$(basename "${container_dir}")"

    if [[ ! -f "${container_dir}/metadata.env" ]]; then
      continue
    fi

    log_info "  $(lang_pick "恢复容器" "Restoring container"): ${name}"

    if log_dry_run "$(lang_pick "恢复独立容器" "Restore standalone container"): ${name}"; then continue; fi

    local image=""
    image="$(_read_env_value "${container_dir}/metadata.env" "IMAGE")"

    # 拉取镜像
    if [[ -n "${image}" ]]; then
      docker pull "${image}" 2>/dev/null || log_warn "    $(lang_pick "镜像拉取失败" "Image pull failed"): ${image}"
    fi

    # 还原卷数据
    if [[ -d "${container_dir}/volumes" ]]; then
      for vol_archive in "${container_dir}/volumes"/*.tar.gz; do
        [[ -f "${vol_archive}" ]] || continue
        local vol_name
        vol_name="$(basename "${vol_archive}" .tar.gz)"
        log_debug "    $(lang_pick "恢复卷" "Restoring volume"): ${vol_name}"
      done
    fi

    log_info "    $(lang_pick "注意: 独立容器需要根据 inspect.json 手动重建" "Note: standalone containers need manual recreation based on inspect.json"): ${container_dir}/inspect.json"
    log_info "    $(lang_pick "或参考 metadata.env 中的配置" "Or refer to the settings in metadata.env"): ${container_dir}/metadata.env"
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
  log_step "$(lang_pick "恢复 Systemd 服务..." "Restoring Systemd services...")"
  local restored_count=0
  local warning_count=0
  local deferred_count=0

  for svc_dir in "${mod_dir}"/*/; do
    [[ -d "${svc_dir}" ]] || continue
    local svc_name
    svc_name="$(basename "${svc_dir}")"
    local svc_warn=0

    log_info "  $(lang_pick "恢复服务" "Restoring service"): ${svc_name}"
    _register_restore_systemd_service "${svc_name}"

    if log_dry_run "$(lang_pick "恢复 Systemd" "Restore Systemd"): ${svc_name}"; then continue; fi

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
          log_debug "    $(lang_pick "还原配置" "Restoring config"): ${cfg}"
        fi
      fi
    done

    # Python venv 重建 (基于 requirements_freeze.txt)
    if [[ -f "${svc_dir}/_venv_path.txt" ]]; then
      local venv_path
      venv_path="$(cat "${svc_dir}/_venv_path.txt")"
      local py_version="python3"
      [[ -f "${svc_dir}/_python_version.txt" ]] && py_version="$(cat "${svc_dir}/_python_version.txt" | awk '{print $2}' | cut -d. -f1,2)"

      log_info "    $(lang_pick "重建 Python venv" "Rebuilding Python venv"): ${venv_path}"
      if command -v python3 >/dev/null 2>&1; then
        if ! _ensure_python_venv_support; then
          log_warn "    $(lang_pick "python3-venv 不可用，请先安装后再重建" "python3-venv is unavailable. Install it before rebuilding"): apt-get install python3-venv"
          svc_warn=1
        else
          python3 -m venv "${venv_path}" 2>/dev/null || {
            log_warn "    $(lang_pick "venv 创建失败，请手动执行" "venv creation failed. Run manually"): python3 -m venv ${venv_path}"
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
            local req_file_prepared="${req_file}.prepared"
            _prepare_python_requirement_file "${req_file}" "${req_file_prepared}" || cp -f "${req_file}" "${req_file_prepared}" 2>/dev/null || true
            log_info "    $(lang_pick "安装依赖" "Installing dependencies"): $(wc -l < "${req_file_prepared}" 2>/dev/null || echo '?') $(lang_pick "个包" "packages")..."
            "${venv_path}/bin/pip" install --disable-pip-version-check -U pip setuptools wheel >/dev/null 2>&1 || true
            "${venv_path}/bin/pip" install --disable-pip-version-check -r "${req_file_prepared}" 2>/dev/null || {
              log_warn "    $(lang_pick "pip install 部分失败，请检查" "pip install partially failed. Check"): ${req_file}"
              svc_warn=1
            }
          fi
        fi
      else
        log_warn "    $(lang_pick "python3 未安装，请先安装后手动重建 venv" "python3 is not installed. Install it before rebuilding the venv manually")"
        svc_warn=1
      fi
    fi

    # 读取状态
    if [[ -f "${svc_dir}/status.env" ]]; then
      local enabled_state=""
      local manual_start=0
      enabled_state="$(_read_env_value "${svc_dir}/status.env" "ENABLED")"
      if _systemd_service_requires_manual_start "${svc_name}" "${svc_dir}"; then
        manual_start=1
        _mark_restore_systemd_manual "${svc_name}"
      fi
      # 恢复启用状态
      systemctl daemon-reload 2>/dev/null || true
      if (( manual_start == 1 )); then
        log_info "    $(lang_pick "单实例服务，已恢复但不自动启动" "Single-instance service restored but not started automatically"): ${svc_name}"
        ((deferred_count+=1))
      elif [[ "${enabled_state}" == "enabled" ]]; then
        systemctl enable "${svc_name}" 2>/dev/null || true
        systemctl start "${svc_name}" 2>/dev/null || {
          log_warn "    $(lang_pick "服务启动失败" "Service failed to start"): ${svc_name}"
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
  elif (( deferred_count > 0 )); then
    summary_add "ok" "恢复 Systemd" "${restored_count} 个服务已恢复，${deferred_count} 个待切换后启动"
  else
    summary_add "ok" "恢复 Systemd" "${restored_count} 个服务已恢复"
  fi
}

_restore_reverse_proxy() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复反向代理配置..." "Restoring reverse proxy configuration...")"
  local restored_count=0
  local warning_count=0
  local deferred_count=0
  local auto_activate_proxy=0
  local enabled_state=""
  local active_state=""
  local caddy_tls_probe_started_at=""

  # Nginx
  if [[ -f "${mod_dir}/nginx/etc_nginx.tar.gz" ]]; then
    _mark_restore_proxy_expected
    _register_restore_proxy_service "nginx"
    log_info "  $(lang_pick "恢复 Nginx 配置..." "Restoring Nginx configuration...")"
    if ! log_dry_run "$(lang_pick "恢复 Nginx" "Restore Nginx")"; then
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
            log_warn "  $(lang_pick "Nginx 启动失败，请手动检查" "Failed to start Nginx. Check it manually.")"
            ((warning_count+=1))
          }
        fi
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
      elif (( auto_activate_proxy == 1 )); then
        log_warn "  $(lang_pick "未发现 Nginx 服务单元，请手动检查" "Nginx service unit not found. Check it manually.")"
        ((warning_count+=1))
      else
        log_info "  $(lang_pick "Nginx 在源机未启用，仅恢复配置" "Nginx was not enabled on the source host. Restored configuration only.")"
        ((deferred_count+=1))
      fi
    fi
    ((restored_count+=1))
  fi

  # Caddy
  if [[ -f "${mod_dir}/caddy/etc_caddy.tar.gz" ]]; then
    _mark_restore_proxy_expected
    _register_restore_proxy_service "caddy"
    log_info "  $(lang_pick "恢复 Caddy 配置..." "Restoring Caddy configuration...")"
    if ! log_dry_run "$(lang_pick "恢复 Caddy" "Restore Caddy")"; then
      tar -xzf "${mod_dir}/caddy/etc_caddy.tar.gz" -C /etc 2>/dev/null || true
      enabled_state="$(_read_env_value "${mod_dir}/caddy/status.env" "ENABLED")"
      active_state="$(_read_env_value "${mod_dir}/caddy/status.env" "ACTIVE")"
      auto_activate_proxy=0
      [[ "${enabled_state}" == "enabled" || "${active_state}" == "active" ]] && auto_activate_proxy=1

      if (( auto_activate_proxy == 1 )) && ! _systemd_unit_exists "caddy"; then
        _ensure_proxy_service_package "caddy" || true
      fi
      if (( auto_activate_proxy == 1 )) && _systemd_unit_exists "caddy"; then
        caddy_tls_probe_started_at="$(date +%s)"
        systemctl enable caddy 2>/dev/null || true
        if ! systemctl is-active caddy >/dev/null 2>&1; then
          systemctl start caddy 2>/dev/null || {
            log_warn "  $(lang_pick "Caddy 启动失败，请手动检查" "Failed to start Caddy. Check it manually.")"
            ((warning_count+=1))
          }
        fi
        systemctl reload caddy 2>/dev/null || true
        _maybe_repair_caddy_tls_state "${caddy_tls_probe_started_at}"
      elif (( auto_activate_proxy == 1 )); then
        log_warn "  $(lang_pick "未发现 Caddy 服务单元，请手动检查" "Caddy service unit not found. Check it manually.")"
        ((warning_count+=1))
      else
        log_info "  $(lang_pick "Caddy 在源机未启用，仅恢复配置" "Caddy was not enabled on the source host. Restored configuration only.")"
        ((deferred_count+=1))
      fi
    fi
    ((restored_count+=1))
  fi

  # Apache
  if [[ -f "${mod_dir}/apache/etc_apache2.tar.gz" ]]; then
    _mark_restore_proxy_expected
    _register_restore_proxy_service "apache2"
    log_info "  $(lang_pick "恢复 Apache 配置..." "Restoring Apache configuration...")"
    if ! log_dry_run "$(lang_pick "恢复 Apache" "Restore Apache")"; then
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
            log_warn "  $(lang_pick "Apache 启动失败，请手动检查" "Failed to start Apache. Check it manually.")"
            ((warning_count+=1))
          }
        fi
        systemctl reload apache2 2>/dev/null || true
      elif (( auto_activate_proxy == 1 )); then
        log_warn "  $(lang_pick "未发现 Apache 服务单元，请手动检查" "Apache service unit not found. Check it manually.")"
        ((warning_count+=1))
      else
        log_info "  $(lang_pick "Apache 在源机未启用，仅恢复配置" "Apache was not enabled on the source host. Restored configuration only.")"
        ((deferred_count+=1))
      fi
    fi
    ((restored_count+=1))
  fi

  if (( restored_count == 0 )); then
    summary_add "skip" "恢复反向代理" "$(lang_pick "未发现可恢复配置" "no restorable configuration found")"
  elif (( warning_count > 0 )); then
    summary_add "warn" "恢复反向代理" "$(lang_pick "${restored_count} 项已处理，${warning_count} 项需手动检查" "${restored_count} entries processed, ${warning_count} require manual review")"
  elif (( deferred_count > 0 )); then
    summary_add "ok" "恢复反向代理" "$(lang_pick "${restored_count} 项配置已恢复，${deferred_count} 项未启用" "${restored_count} configurations restored, ${deferred_count} were not enabled")"
  else
    summary_add "ok" "恢复反向代理" "$(lang_pick "${restored_count} 项配置已恢复" "${restored_count} configurations restored")"
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
  log_step "$(lang_pick "恢复 SSL 证书..." "Restoring SSL certificates...")"

  if [[ -f "${mod_dir}/letsencrypt.tar.gz" ]]; then
    log_info "  $(lang_pick "恢复 Let's Encrypt..." "Restoring Let's Encrypt...")"
    if ! log_dry_run "$(lang_pick "恢复 Let's Encrypt" "Restore Let's Encrypt")"; then
      tar -xzf "${mod_dir}/letsencrypt.tar.gz" -C /etc 2>/dev/null || true
    fi
  fi

  # acme.sh
  if [[ -f "${mod_dir}/_acme_paths.txt" ]]; then
    while IFS= read -r acme_path; do
      local safe_name
      safe_name="acme_$(echo "${acme_path}" | tr '/' '_' | sed 's/^_//')"
      if [[ -f "${mod_dir}/${safe_name}.tar.gz" ]]; then
        log_info "  $(lang_pick "恢复 acme.sh" "Restoring acme.sh"): ${acme_path}"
        if ! log_dry_run "$(lang_pick "恢复 acme.sh" "Restore acme.sh")"; then
          safe_mkdir "$(dirname "${acme_path}")"
          tar -xzf "${mod_dir}/${safe_name}.tar.gz" -C "$(dirname "${acme_path}")" 2>/dev/null || true
        fi
      fi
    done < "${mod_dir}/_acme_paths.txt"
  fi

  summary_add "ok" "恢复 SSL" "$(lang_pick "证书已恢复" "certificates restored")"
}

_restore_crontab() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复 Crontab..." "Restoring crontab...")"

  for cron_file in "${mod_dir}"/user_*.crontab; do
    [[ -f "${cron_file}" ]] || continue
    local username
    username="$(basename "${cron_file}" .crontab | sed 's/^user_//')"
    log_info "  $(lang_pick "恢复 ${username} 的 crontab" "Restoring ${username}'s crontab")"
    if ! log_dry_run "$(lang_pick "恢复 crontab" "Restore crontab"): ${username}"; then
      crontab -u "${username}" "${cron_file}" 2>/dev/null || {
        log_warn "    $(lang_pick "${username} 的 crontab 恢复失败" "Failed to restore ${username}'s crontab")"
      }
    fi
  done

  # 系统 cron 目录
  for cron_archive in "${mod_dir}"/*.tar.gz; do
    [[ -f "${cron_archive}" ]] || continue
    local dir_name
    dir_name="$(basename "${cron_archive}" .tar.gz)"
    log_info "  $(lang_pick "恢复系统 cron" "Restoring system cron"): ${dir_name}"
    if ! log_dry_run "$(lang_pick "恢复" "Restore"): ${dir_name}"; then
      tar -xzf "${cron_archive}" -C /etc 2>/dev/null || true
    fi
  done

  # /etc/crontab
  if [[ -f "${mod_dir}/crontab" ]]; then
    if ! log_dry_run "$(lang_pick "恢复 /etc/crontab" "Restore /etc/crontab")"; then
      cp -a "${mod_dir}/crontab" /etc/crontab 2>/dev/null || true
    fi
  fi

  summary_add "ok" "恢复 Crontab" "$(lang_pick "已恢复" "restored")"
}

_restore_firewall() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复防火墙规则..." "Restoring firewall rules...")"

  if [[ -f "${mod_dir}/iptables.rules" ]]; then
    log_info "  $(lang_pick "恢复 iptables 规则" "Restoring iptables rules")"
    if ! log_dry_run "$(lang_pick "恢复 iptables" "Restore iptables")"; then
      iptables-restore < "${mod_dir}/iptables.rules" 2>/dev/null || true
    fi
  fi

  if [[ -f "${mod_dir}/ip6tables.rules" ]]; then
    if ! log_dry_run "$(lang_pick "恢复 ip6tables" "Restore ip6tables")"; then
      ip6tables-restore < "${mod_dir}/ip6tables.rules" 2>/dev/null || true
    fi
  fi

  if [[ -d "${mod_dir}" ]] && ls "${mod_dir}/etc_ufw.tar.gz" >/dev/null 2>&1; then
    log_info "  $(lang_pick "恢复 UFW 配置" "Restoring UFW configuration")"
    if ! log_dry_run "$(lang_pick "恢复 UFW" "Restore UFW")"; then
      tar -xzf "${mod_dir}/etc_ufw.tar.gz" -C /etc 2>/dev/null || true
      ufw reload >/dev/null 2>&1 || true
    fi
  fi

  if [[ -f "${mod_dir}/nftables.rules" ]]; then
    log_info "  $(lang_pick "恢复 nftables 规则" "Restoring nftables rules")"
    if ! log_dry_run "$(lang_pick "恢复 nftables" "Restore nftables")"; then
      nft -f "${mod_dir}/nftables.rules" 2>/dev/null || true
    fi
  fi

  if ls "${mod_dir}/etc_firewalld.tar.gz" >/dev/null 2>&1; then
    log_info "  $(lang_pick "恢复 firewalld" "Restoring firewalld")"
    if ! log_dry_run "$(lang_pick "恢复 firewalld" "Restore firewalld")"; then
      tar -xzf "${mod_dir}/etc_firewalld.tar.gz" -C /etc 2>/dev/null || true
      systemctl reload firewalld 2>/dev/null || true
    fi
  fi

  if ls "${mod_dir}/etc_fail2ban.tar.gz" >/dev/null 2>&1; then
    log_info "  $(lang_pick "恢复 fail2ban" "Restoring fail2ban")"
    if ! log_dry_run "$(lang_pick "恢复 fail2ban" "Restore fail2ban")"; then
      tar -xzf "${mod_dir}/etc_fail2ban.tar.gz" -C /etc 2>/dev/null || true
      systemctl restart fail2ban 2>/dev/null || true
    fi
  fi

  if ! log_dry_run "$(lang_pick "保留 SSH 访问" "Preserve SSH access")"; then
    _preserve_ssh_access_after_firewall_restore
  fi

  summary_add "ok" "恢复防火墙" "$(lang_pick "规则已恢复" "rules restored")"
}

_restore_user_home() {
  local mod_dir="$1"
  log_step "$(lang_pick "恢复用户目录..." "Restoring user homes...")"
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

    log_info "  $(lang_pick "恢复用户" "Restoring user"): ${username} -> ${home}"

    if log_dry_run "$(lang_pick "恢复用户目录" "Restore user home"): ${username}"; then continue; fi

    safe_mkdir "${home}"

    # 还原 dotfiles
    while IFS= read -r f; do
      local rel
      rel="$(relative_child_path "${user_root}" "${f}")"
      if [[ -n "${rel}" ]]; then
        local target="${home}/${rel}"
        if [[ "${rel}" == ".ssh/authorized_keys" ]]; then
          log_info "    $(lang_pick "保留当前 authorized_keys" "Keeping current authorized_keys"): ${target}"
          continue
        fi
        safe_mkdir "$(dirname "${target}")"
        cp -a "${f}" "${target}" 2>/dev/null || true
        ((restored_files+=1))
        if [[ "${rel}" == ".config/rclone/rclone.conf" ]]; then
          if ! command -v rclone >/dev/null 2>&1; then
            _ensure_rclone_installed >/dev/null 2>&1 || true
          fi
        fi
      fi
    done < <(find "${user_dir}" -type f ! -name "user_info.env" ! -name "crontab.bak")

    # 修正所有权
    chown -R "${username}:" "${home}" 2>/dev/null || true
    ((restored_users+=1))
    _RESTORE_HEALTH_CHECK_USER_HOME=1
  done

  if (( restored_users == 0 )); then
    summary_add "skip" "恢复用户目录" "$(lang_pick "未发现可恢复用户" "no restorable users found")"
  else
    summary_add "ok" "恢复用户目录" "$(lang_pick "${restored_users} 个用户，${restored_files} 个文件" "${restored_users} users, ${restored_files} files")"
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
      echo "  $(_manifest_display_key "${key}"): ${value}"
    done < "${backup_data_dir}/manifest.txt"
    echo
  fi

  # ==================== 确认恢复范围 ====================
  log_step "$(lang_pick "第4步: 确认恢复范围..." "Step 4: Confirm restore scope...")"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "备份包含以下模块" "Backup contains these modules"):${_CLR_NC}"
  local -a restore_modules=()
  local -a ordered_restore_modules=()
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
    if ! confirm_exact "$(lang_pick "输入 yes 确认开始恢复（恢复前建议先备份当前环境）" "Type yes to start the restore (back up the current environment first)")" "yes"; then
      log_warn "$(lang_pick "用户取消恢复。" "Restore canceled by user.")"
      return 0
    fi
  else
    log_info "$(lang_pick "自动确认模式，开始恢复。" "Auto-confirm mode enabled. Starting restore.")"
  fi

  _order_restore_modules restore_modules ordered_restore_modules

  local snapshot_dir=""
  snapshot_dir="$(_create_restore_snapshot "${backup_data_dir}" "${selected}")"
  [[ -n "${snapshot_dir}" ]] && log_info "$(lang_pick "已创建恢复前轻量快照" "Created lightweight pre-restore snapshot"): ${snapshot_dir}"

  # ==================== 执行恢复 ====================
  log_step "$(lang_pick "第5步: 执行恢复..." "Step 5: Run restore...")"

  for mod in "${ordered_restore_modules[@]}"; do
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
  _finalize_restore_result \
    "${selected}" \
    "${elapsed}" \
    "${snapshot_dir}" \
    "$(lang_pick "恢复完成! (本地文件模式)" "Restore completed! (local file mode)")" \
    "$(lang_pick "恢复失败! (本地文件模式)" "Restore failed! (local file mode)")" || return 1

  echo -e "${_CLR_BOLD}${_CLR_YELLOW}$(lang_pick "建议操作" "Recommended actions"):${_CLR_NC}"
  echo "  1. $(lang_pick "检查所有服务是否正常运行" "Check whether all services are running normally")"
  echo "  2. $(lang_pick "验证域名和 SSL 证书" "Verify domains and SSL certificates")"
  echo "  3. $(lang_pick "测试数据库连接" "Test database connections")"
  echo "  4. $(lang_pick "配置新的定时备份" "Configure scheduled backups"): vpsmagic schedule install"
  echo
}
