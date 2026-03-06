#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 配置加载与校验
# ============================================================

[[ -n "${_VPSMAGIC_CONFIG_LOADED:-}" ]] && return 0
_VPSMAGIC_CONFIG_LOADED=1

# ---------- 默认值 ----------
VPSMAGIC_VERSION="1.0.0"
VPSMAGIC_HOME="${VPSMAGIC_HOME:-/opt/vpsmagic}"

# 备份
BACKUP_ROOT="${BACKUP_ROOT:-/opt/vpsmagic/backups}"
BACKUP_KEEP_LOCAL="${BACKUP_KEEP_LOCAL:-3}"
BACKUP_KEEP_REMOTE="${BACKUP_KEEP_REMOTE:-30}"
BACKUP_PREFIX="${BACKUP_PREFIX:-vpsmagic}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

# rclone
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_CONF="${RCLONE_CONF:-}"
RCLONE_BW_LIMIT="${RCLONE_BW_LIMIT:-}"

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

# 调度
SCHEDULE_CRON="${SCHEDULE_CRON:-0 3 * * *}"

# ---------- 配置加载 ----------
load_config() {
  local config_file="${1:-}"

  # 搜索配置文件的优先顺序
  local search_paths=(
    "${config_file}"
    "${VPSMAGIC_HOME}/config.env"
    "/etc/vpsmagic/config.env"
    "${HOME}/.vpsmagic.env"
    "./config.env"
  )

  local found=""
  for path in "${search_paths[@]}"; do
    if [[ -n "${path}" && -f "${path}" ]]; then
      found="${path}"
      break
    fi
  done

  if [[ -z "${found}" ]]; then
    log_warn "未找到配置文件，将使用默认值和交互式输入。"
    return 0
  fi

  log_info "加载配置文件: ${found}"

  # 安全检查：配置文件不应该有过于宽松的权限
  if is_linux; then
    local perms
    perms="$(stat -c '%a' "${found}" 2>/dev/null || echo "unknown")"
    if [[ "${perms}" != "unknown" && "${perms}" != "600" && "${perms}" != "400" && "${perms}" != "640" && "${perms}" != "644" ]]; then
      log_warn "配置文件权限为 ${perms}，建议设为 600: chmod 600 ${found}"
    fi
  fi

  # shellcheck disable=SC1090
  if ! source "${found}"; then
    log_error "配置文件加载失败: ${found}"
    return 1
  fi

  _VPSMAGIC_CONFIG_FILE="${found}"
  log_success "配置加载完成"
  return 0
}

# ---------- 配置校验 ----------
validate_config() {
  local mode="${1:-backup}"
  local errors=0

  case "${mode}" in
    backup|upload|restore)
      if [[ -z "${RCLONE_REMOTE}" ]]; then
        log_error "RCLONE_REMOTE 未配置。请在配置文件中设置远端路径。"
        log_info "  示例: RCLONE_REMOTE=\"mywebdav:backup/vps1\""
        ((errors++))
      fi
      if ! command -v rclone >/dev/null 2>&1; then
        log_error "rclone 未安装。"
        log_info "  安装: curl https://rclone.org/install.sh | sudo bash"
        ((errors++))
      fi
      ;;
  esac

  if [[ "${NOTIFY_ENABLED}" == "true" ]]; then
    if [[ -z "${TG_BOT_TOKEN}" || -z "${TG_CHAT_ID}" ]]; then
      log_warn "Telegram 通知已启用但 Token/ChatID 未配置，将跳过通知。"
      NOTIFY_ENABLED="false"
    fi
  fi

  if (( errors > 0 )); then
    log_error "配置校验发现 ${errors} 个错误，请修复后重试。"
    return 1
  fi

  log_debug "配置校验通过"
  return 0
}

# ---------- 模块启用检查 ----------
is_module_enabled() {
  local module="$1"
  local var_name="ENABLE_${module^^}"

  # 动态读取变量值
  local val="${!var_name:-true}"
  [[ "${val}" == "true" || "${val}" == "1" || "${val}" == "yes" ]]
}

# ---------- 打印当前配置 ----------
print_config() {
  echo
  echo -e "${_CLR_BOLD}当前配置:${_CLR_NC}"
  echo "  备份根目录:       ${BACKUP_ROOT}"
  echo "  远端路径:         ${RCLONE_REMOTE:-未配置}"
  echo "  本地保留:         ${BACKUP_KEEP_LOCAL} 份"
  echo "  远端保留:         ${BACKUP_KEEP_REMOTE} 份"
  echo "  加密:             ${BACKUP_ENCRYPTION_KEY:+已启用}${BACKUP_ENCRYPTION_KEY:-未启用}"
  echo "  通知:             ${NOTIFY_ENABLED}"
  echo "  日志文件:         ${LOG_FILE}"
  echo
  echo -e "${_CLR_BOLD}启用的备份模块:${_CLR_NC}"

  local modules=(
    "DOCKER_COMPOSE:Docker Compose 项目"
    "DOCKER_STANDALONE:独立 Docker 容器"
    "SYSTEMD:Systemd 服务"
    "REVERSE_PROXY:反向代理配置"
    "DATABASE:数据库"
    "SSL_CERTS:SSL 证书"
    "CRONTAB:Crontab 定时任务"
    "FIREWALL:防火墙规则"
    "USER_HOME:用户目录"
    "CUSTOM_PATHS:自定义路径"
  )

  for entry in "${modules[@]}"; do
    local key="${entry%%:*}"
    local label="${entry#*:}"
    if is_module_enabled "${key}"; then
      echo -e "  ${_CLR_GREEN}✓${_CLR_NC} ${label}"
    else
      echo -e "  ${_CLR_DIM}✗ ${label}${_CLR_NC}"
    fi
  done
  echo
}
