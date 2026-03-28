#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 配置加载与校验
# ============================================================

[[ -n "${_VPSMAGIC_CONFIG_LOADED:-}" ]] && return 0
_VPSMAGIC_CONFIG_LOADED=1

# ---------- 默认值 ----------
VPSMAGIC_VERSION="1.0.2"
VPSMAGIC_HOME="${VPSMAGIC_HOME:-/opt/vpsmagic}"

# 备份
BACKUP_ROOT="${BACKUP_ROOT:-/opt/vpsmagic/backups}"
BACKUP_KEEP_LOCAL="${BACKUP_KEEP_LOCAL:-3}"
BACKUP_KEEP_REMOTE="${BACKUP_KEEP_REMOTE:-30}"
BACKUP_PREFIX="${BACKUP_PREFIX:-vpsmagic}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
BACKUP_DESTINATION="${BACKUP_DESTINATION:-remote}"
BACKUP_REMOTE_OVERRIDE="${BACKUP_REMOTE_OVERRIDE:-}"

# rclone
BACKUP_TARGETS="${BACKUP_TARGETS:-}"
BACKUP_PRIMARY_TARGET="${BACKUP_PRIMARY_TARGET:-}"
BACKUP_ASYNC_TARGET="${BACKUP_ASYNC_TARGET:-}"
BACKUP_INTERACTIVE_TARGETS="${BACKUP_INTERACTIVE_TARGETS:-true}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_CONF="${RCLONE_CONF:-}"
RCLONE_BW_LIMIT="${RCLONE_BW_LIMIT:-}"
RESTORE_ROLLBACK_ON_FAILURE="${RESTORE_ROLLBACK_ON_FAILURE:-false}"

# 通知
NOTIFY_ENABLED="${NOTIFY_ENABLED:-false}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

# 备份模块开关 (all default on)
ENABLE_DOCKER_COMPOSE="${ENABLE_DOCKER_COMPOSE:-true}"
ENABLE_DOCKER_STANDALONE="${ENABLE_DOCKER_STANDALONE:-true}"
ENABLE_SYSTEMD="${ENABLE_SYSTEMD:-true}"
ENABLE_REVERSE_PROXY="${ENABLE_REVERSE_PROXY:-true}"
ENABLE_DATABASE="${ENABLE_DATABASE:-true}"
ENABLE_SSL_CERTS="${ENABLE_SSL_CERTS:-true}"
ENABLE_CRONTAB="${ENABLE_CRONTAB:-true}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"
ENABLE_USER_HOME="${ENABLE_USER_HOME:-true}"
ENABLE_CUSTOM_PATHS="${ENABLE_CUSTOM_PATHS:-true}"

# 模块参数
COMPOSE_PROJECTS="${COMPOSE_PROJECTS:-auto}"
SYSTEMD_SERVICES="${SYSTEMD_SERVICES:-auto}"
EXTRA_PATHS="${EXTRA_PATHS:-}"
BACKUP_USERS="${BACKUP_USERS:-root}"

# 数据库
DB_MYSQL_CONTAINERS="${DB_MYSQL_CONTAINERS:-}"
DB_MYSQL_HOST_USER="${DB_MYSQL_HOST_USER:-}"
DB_MYSQL_HOST_PASS="${DB_MYSQL_HOST_PASS:-}"
DB_POSTGRES_CONTAINERS="${DB_POSTGRES_CONTAINERS:-}"
DB_SQLITE_PATHS="${DB_SQLITE_PATHS:-}"

# 日志
LOG_FILE="${LOG_FILE:-/var/log/vpsmagic.log}"
UI_LANG="${UI_LANG:-}"

# 调度
SCHEDULE_CRON="${SCHEDULE_CRON:-0 3 * * *}"

# 迁移
MIGRATE_SSH_PORT="${MIGRATE_SSH_PORT:-22}"
MIGRATE_SSH_KEY="${MIGRATE_SSH_KEY:-}"
MIGRATE_BW_LIMIT="${MIGRATE_BW_LIMIT:-}"
MIGRATE_TARGET="${MIGRATE_TARGET:-}"
MIGRATE_SKIP_RESTORE="${MIGRATE_SKIP_RESTORE:-0}"
MIGRATE_AUTO_CONFIRM="${MIGRATE_AUTO_CONFIRM:-0}"

# ---------- 安全配置解析 ----------
_is_allowed_config_key() {
  local key="$1"
  case "${key}" in
    VPSMAGIC_HOME|BACKUP_ROOT|BACKUP_KEEP_LOCAL|BACKUP_KEEP_REMOTE|BACKUP_PREFIX|BACKUP_ENCRYPTION_KEY|BACKUP_DESTINATION|BACKUP_REMOTE_OVERRIDE|\
    BACKUP_TARGETS|BACKUP_PRIMARY_TARGET|BACKUP_ASYNC_TARGET|BACKUP_INTERACTIVE_TARGETS|RCLONE_REMOTE|RCLONE_CONF|RCLONE_BW_LIMIT|RESTORE_ROLLBACK_ON_FAILURE|\
    NOTIFY_ENABLED|TG_BOT_TOKEN|TG_CHAT_ID|\
    ENABLE_DOCKER_COMPOSE|ENABLE_DOCKER_STANDALONE|ENABLE_SYSTEMD|ENABLE_REVERSE_PROXY|ENABLE_DATABASE|\
    ENABLE_SSL_CERTS|ENABLE_CRONTAB|ENABLE_FIREWALL|ENABLE_USER_HOME|ENABLE_CUSTOM_PATHS|\
    COMPOSE_PROJECTS|SYSTEMD_SERVICES|EXTRA_PATHS|BACKUP_USERS|\
    DB_MYSQL_CONTAINERS|DB_MYSQL_HOST_USER|DB_MYSQL_HOST_PASS|DB_POSTGRES_CONTAINERS|DB_SQLITE_PATHS|\
    LOG_FILE|UI_LANG|SCHEDULE_CRON|\
    MIGRATE_SSH_PORT|MIGRATE_SSH_KEY|MIGRATE_BW_LIMIT|MIGRATE_TARGET|MIGRATE_SKIP_RESTORE|MIGRATE_AUTO_CONFIRM)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_trim_spaces() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

_load_config_file_safely() {
  local file="$1"
  local line_no=0
  local line=""

  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((line_no+=1))
    line="${line%$'\r'}"

    # 跳过空行和注释
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    # 支持 export KEY=VALUE
    if [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
      line="$(echo "${line}" | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
    fi

    if [[ "${line}" != *"="* ]]; then
      log_warn "配置第 ${line_no} 行格式无效，已跳过。"
      continue
    fi

    local key="${line%%=*}"
    local value="${line#*=}"
    key="$(_trim_spaces "${key}")"
    value="$(_trim_spaces "${value}")"

    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_warn "配置第 ${line_no} 行键名非法 (${key})，已跳过。"
      continue
    fi

    if ! _is_allowed_config_key "${key}"; then
      log_warn "配置项 ${key} 不在允许列表中，已跳过。"
      continue
    fi

    # 去除未加引号值的行尾注释: VALUE # comment
    if [[ ! "${value}" =~ ^\".*\"$ && ! "${value}" =~ ^\'.*\'$ ]]; then
      value="${value%%[[:space:]]#*}"
      value="$(_trim_spaces "${value}")"
    fi

    # 去除外层引号
    if [[ "${value}" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
      value="${value//\\\"/\"}"
      value="${value//\\\\/\\}"
    elif [[ "${value}" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "${key}" '%s' "${value}"
  done < "${file}"
}

# ---------- 配置加载 ----------
load_config() {
  local config_file="${1:-}"
  local log_lang="${UI_LANG:-}"

  # 搜索配置文件的优先顺序
  local search_paths=(
    "${config_file}"
    "${VPSMAGIC_HOME}/config.env"
    "/etc/vpsmagic/config.env"
    "${HOME}/.vpsmagic.env"
  )

  local found=""
  for path in "${search_paths[@]}"; do
    if [[ -n "${path}" && -f "${path}" ]]; then
      found="${path}"
      break
    fi
  done

  if [[ -z "${found}" ]]; then
    log_warn "$(lang_pick "未找到配置文件，将使用默认值和交互式输入。" "No config file found. Falling back to defaults and interactive input.")"
    return 0
  fi

  log_info "$(lang_pick "加载配置文件" "Loading config file"): ${found}"

  # 安全检查：配置文件不应该有过于宽松的权限
  if is_linux; then
    local perms
    perms="$(get_file_mode "${found}")"
    if [[ "${perms}" != "unknown" && "${perms}" != "600" && "${perms}" != "400" && "${perms}" != "640" && "${perms}" != "644" ]]; then
      log_warn "$(lang_pick "配置文件权限为" "Config file permissions are") ${perms}，$(lang_pick "建议设为 600" "recommended: 600"): chmod 600 ${found}"
    fi
  fi

  if ! _load_config_file_safely "${found}"; then
    log_error "$(lang_pick "配置文件解析失败" "Failed to parse config file"): ${found}"
    return 1
  fi

  local loaded_ui_lang="${UI_LANG:-}"
  UI_LANG="${log_lang:-${loaded_ui_lang}}"
  _VPSMAGIC_CONFIG_FILE="${found}"
  log_success "$(lang_pick "配置加载完成" "Config loaded successfully")"
  UI_LANG="${loaded_ui_lang}"
  return 0
}

# ---------- 配置校验 ----------
validate_config() {
  local mode="${1:-backup}"
  local errors=0
  local -a configured_targets=()
  local target=""
  local found=0

  get_backup_targets configured_targets

  case "${mode}" in
    backup|upload)
      if [[ "${mode}" == "upload" || "$(should_use_remote_backup && echo yes || echo no)" == "yes" ]]; then
        if ! command -v rclone >/dev/null 2>&1; then
          log_error "$(lang_pick "rclone 未安装。" "rclone is not installed.")"
          log_info "  $(lang_pick "安装" "Install"): curl https://rclone.org/install.sh | sudo bash"
          ((errors+=1))
        fi
      fi
      ;;
    restore)
      # restore 模式现在支持 --local，仅在非 local 模式时检查 rclone
      if [[ -z "${RESTORE_LOCAL_FILE:-}" ]]; then
        if ! command -v rclone >/dev/null 2>&1; then
          log_error "$(lang_pick "rclone 未安装。" "rclone is not installed.")"
          log_info "  $(lang_pick "安装" "Install"): curl https://rclone.org/install.sh | sudo bash"
          ((errors+=1))
        fi
      fi
      ;;
    migrate)
      # 迁移模式不需要 rclone，但需要 SSH
      if ! command -v ssh >/dev/null 2>&1; then
        log_error "$(lang_pick "ssh 未安装。" "ssh is not installed.")"
        ((errors+=1))
      fi
      if ! command -v rsync >/dev/null 2>&1; then
        log_warn "$(lang_pick "rsync 未安装，将回退使用 scp。建议安装 rsync 获得更好的体验。" "rsync is not installed. Migration will fall back to scp. Installing rsync is recommended.")"
      fi
      ;;
  esac

  if [[ "${NOTIFY_ENABLED}" == "true" ]]; then
    if [[ -z "${TG_BOT_TOKEN}" || -z "${TG_CHAT_ID}" ]]; then
      log_warn "$(lang_pick "Telegram 通知已启用但 Token/ChatID 未配置，将跳过通知。" "Telegram notifications are enabled but Token/Chat ID is missing. Notifications will be skipped.")"
      NOTIFY_ENABLED="false"
    fi
  fi

  if [[ -n "${BACKUP_PRIMARY_TARGET:-}" ]]; then
    local expanded_primary=""
    expanded_primary="$(get_backup_primary_target)"
    if [[ -n "${expanded_primary}" && ${#configured_targets[@]} -gt 0 ]]; then
      found=0
      for target in "${configured_targets[@]}"; do
        if [[ "${target}" == "${expanded_primary}" ]]; then
          found=1
          break
        fi
      done
      if (( found == 0 )); then
        log_error "$(lang_pick "BACKUP_PRIMARY_TARGET 必须包含在 BACKUP_TARGETS / RCLONE_REMOTE 中" "BACKUP_PRIMARY_TARGET must also exist in BACKUP_TARGETS / RCLONE_REMOTE"): ${expanded_primary}"
        ((errors+=1))
      fi
    fi
  fi

  if [[ -n "${BACKUP_ASYNC_TARGET:-}" ]]; then
    local expanded_async=""
    expanded_async="$(get_backup_async_target)"
    if [[ -n "${expanded_async}" && ${#configured_targets[@]} -gt 0 ]]; then
      found=0
      for target in "${configured_targets[@]}"; do
        if [[ "${target}" == "${expanded_async}" ]]; then
          found=1
          break
        fi
      done
      if (( found == 0 )); then
        log_error "$(lang_pick "BACKUP_ASYNC_TARGET 必须包含在 BACKUP_TARGETS / RCLONE_REMOTE 中" "BACKUP_ASYNC_TARGET must also exist in BACKUP_TARGETS / RCLONE_REMOTE"): ${expanded_async}"
        ((errors+=1))
      fi
    fi
  fi

  if (( errors > 0 )); then
    log_error "$(lang_pick "配置校验发现" "Configuration validation found") ${errors} $(lang_pick "个错误，请修复后重试。" "error(s). Please fix them and try again.")"
    return 1
  fi

  log_debug "配置校验通过"
  return 0
}

normalize_backup_destination() {
  local destination="${BACKUP_DESTINATION:-remote}"
  case "${destination}" in
    local|remote)
      echo "${destination}"
      ;;
    *)
      log_warn "未知 BACKUP_DESTINATION=${destination}，已回退为 remote"
      echo "remote"
      ;;
  esac
}

should_use_remote_backup() {
  [[ "$(normalize_backup_destination)" == "remote" ]]
}

# ---------- 模块启用检查 ----------
is_module_enabled() {
  local module="$1"
  local module_upper
  module_upper="$(printf '%s' "${module}" | tr '[:lower:]' '[:upper:]')"
  local var_name="ENABLE_${module_upper}"

  # 动态读取变量值
  local val="${!var_name:-true}"
  [[ "${val}" == "true" || "${val}" == "1" || "${val}" == "yes" ]]
}

get_backup_targets() {
  local result_var="$1"
  eval "${result_var}=()"

  if [[ -n "${BACKUP_REMOTE_OVERRIDE:-}" ]]; then
    local override_expanded=""
    override_expanded="$(expand_backup_target_template "${BACKUP_REMOTE_OVERRIDE}")"
    eval "${result_var}+=(\"\${override_expanded}\")"
    return 0
  fi

  if [[ -n "${BACKUP_TARGETS:-}" ]]; then
    local -a raw_targets=()
    parse_list "${BACKUP_TARGETS}" raw_targets
    local raw_target=""
    for raw_target in "${raw_targets[@]}"; do
      local expanded_target=""
      expanded_target="$(expand_backup_target_template "${raw_target}")"
      eval "${result_var}+=(\"\${expanded_target}\")"
    done
    return 0
  fi

  if [[ -n "${RCLONE_REMOTE:-}" ]]; then
    local legacy_expanded=""
    legacy_expanded="$(expand_backup_target_template "${RCLONE_REMOTE}")"
    eval "${result_var}+=(\"\${legacy_expanded}\")"
    return 0
  fi

  local host_name="$(hostname 2>/dev/null || echo 'vps')"
  eval "${result_var}+=(
    \"gdrive:VPSMagicBackup/${host_name}\"
    \"onedrive:VPSMagicBackup/${host_name}\"
    \"openlist_webdav:backup/${host_name}\"
  )"
}

expand_backup_target_template() {
  local target="${1:-}"
  local host_name=""
  host_name="$(hostname 2>/dev/null || echo 'vps')"
  target="${target//\{hostname\}/${host_name}}"
  printf '%s\n' "${target}"
}

get_backup_primary_target() {
  if [[ -n "${BACKUP_PRIMARY_TARGET:-}" ]]; then
    expand_backup_target_template "${BACKUP_PRIMARY_TARGET}"
    return 0
  fi
  local -a backup_targets=()
  get_backup_targets backup_targets
  if (( ${#backup_targets[@]} > 0 )); then
    printf '%s\n' "${backup_targets[0]}"
  fi
}

get_backup_async_target() {
  if [[ -n "${BACKUP_ASYNC_TARGET:-}" ]]; then
    expand_backup_target_template "${BACKUP_ASYNC_TARGET}"
    return 0
  fi
}

# ---------- 打印当前配置 ----------
print_config() {
  local -a backup_targets=()
  get_backup_targets backup_targets

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "当前配置" "Current configuration"):${_CLR_NC}"
  echo "  $(lang_pick "备份根目录" "Backup root"):       ${BACKUP_ROOT}"
  echo "  $(lang_pick "备份目标模式" "Backup destination"):     $(normalize_backup_destination)"
  echo "  $(lang_pick "界面语言" "Interface language"):       ${UI_LANG:-zh}"
  echo "  $(lang_pick "远端目标策略" "Remote target strategy"):"
  local idx=1
  for target in "${backup_targets[@]}"; do
    echo "    ${idx}. ${target}"
    ((idx+=1))
  done
  if [[ -n "${BACKUP_PRIMARY_TARGET:-}" ]]; then
    echo "  $(lang_pick "默认主目标" "Default primary target"): $(get_backup_primary_target)"
  fi
  if [[ -n "${BACKUP_ASYNC_TARGET:-}" ]]; then
    echo "  $(lang_pick "异步副本目标" "Async replica target"): $(get_backup_async_target)"
  fi
  echo "  $(lang_pick "远端交互选择" "Interactive remote selection"): ${BACKUP_INTERACTIVE_TARGETS}"
  echo "  $(lang_pick "失败后自动回滚" "Auto rollback on failure"): ${RESTORE_ROLLBACK_ON_FAILURE}"
  echo "  $(lang_pick "本地保留" "Local retention"):         ${BACKUP_KEEP_LOCAL} $(lang_pick "份" "copies")"
  echo "  $(lang_pick "远端保留" "Remote retention"):         ${BACKUP_KEEP_REMOTE} $(lang_pick "份" "copies")"
  if [[ -n "${BACKUP_ENCRYPTION_KEY}" ]]; then
    echo "  $(lang_pick "加密" "Encryption"):             $(lang_pick "已启用" "enabled")"
  else
    echo "  $(lang_pick "加密" "Encryption"):             $(lang_pick "未启用" "disabled")"
  fi
  echo "  $(lang_pick "通知" "Notifications"):             ${NOTIFY_ENABLED}"
  echo "  $(lang_pick "日志文件" "Log file"):         ${LOG_FILE}"
  echo
  echo -e "${_CLR_BOLD}$(lang_pick "启用的备份模块" "Enabled backup modules"):${_CLR_NC}"

  local modules=(
    "DOCKER_COMPOSE"
    "DOCKER_STANDALONE"
    "SYSTEMD"
    "REVERSE_PROXY"
    "DATABASE"
    "SSL_CERTS"
    "CRONTAB"
    "FIREWALL"
    "USER_HOME"
    "CUSTOM_PATHS"
  )

  for key in "${modules[@]}"; do
    local label
    label="$(module_display_name "${key}")"
    if is_module_enabled "${key}"; then
      echo -e "  ${_CLR_GREEN}✓${_CLR_NC} ${label}"
    else
      echo -e "  ${_CLR_DIM}✗ ${label}${_CLR_NC}"
    fi
  done
  echo
}
