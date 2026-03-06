#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 主入口脚本
# 版本: v1.0.0
#
# 一套面向个人/小团队 VPS 运维的全栈备份与灾难恢复工具。
# 支持 Docker Compose / 独立容器 / Systemd / 反代 / 数据库 /
# SSL / Crontab / 防火墙 / 用户目录 / 自定义路径 的备份与恢复。
#
# 用法:
#   vpsmagic backup   [--dry-run] [--config path]
#   vpsmagic upload   [--dry-run] [--config path]
#   vpsmagic restore  [--dry-run] [--config path]
#   vpsmagic schedule [install|remove|status]
#   vpsmagic status
#   vpsmagic init
#   vpsmagic help | --help | -h
#   vpsmagic --version | -v
# ============================================================

set -euo pipefail

# ---------- 定位脚本目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 全局运行选项 ----------
DRY_RUN=0
VERBOSE=0
CONFIG_FILE=""
SUBCOMMAND=""
SUBCMD_ARGS=()

# ---------- 加载库文件 ----------
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/notify.sh
source "${SCRIPT_DIR}/lib/notify.sh"

# ---------- 加载采集器 ----------
# shellcheck source=collectors/docker_compose.sh
source "${SCRIPT_DIR}/collectors/docker_compose.sh"
# shellcheck source=collectors/docker_standalone.sh
source "${SCRIPT_DIR}/collectors/docker_standalone.sh"
# shellcheck source=collectors/systemd_service.sh
source "${SCRIPT_DIR}/collectors/systemd_service.sh"
# shellcheck source=collectors/reverse_proxy.sh
source "${SCRIPT_DIR}/collectors/reverse_proxy.sh"
# shellcheck source=collectors/database.sh
source "${SCRIPT_DIR}/collectors/database.sh"
# shellcheck source=collectors/ssl_certs.sh
source "${SCRIPT_DIR}/collectors/ssl_certs.sh"
# shellcheck source=collectors/crontab.sh
source "${SCRIPT_DIR}/collectors/crontab.sh"
# shellcheck source=collectors/firewall.sh
source "${SCRIPT_DIR}/collectors/firewall.sh"
# shellcheck source=collectors/user_home.sh
source "${SCRIPT_DIR}/collectors/user_home.sh"
# shellcheck source=collectors/custom_paths.sh
source "${SCRIPT_DIR}/collectors/custom_paths.sh"

# ---------- 加载功能模块 ----------
# shellcheck source=modules/backup.sh
source "${SCRIPT_DIR}/modules/backup.sh"
# shellcheck source=modules/upload.sh
source "${SCRIPT_DIR}/modules/upload.sh"
# shellcheck source=modules/restore.sh
source "${SCRIPT_DIR}/modules/restore.sh"
# shellcheck source=modules/schedule.sh
source "${SCRIPT_DIR}/modules/schedule.sh"

# ---------- 帮助信息 ----------
show_help() {
  cat <<'EOF'

  ╔══════════════════════════════════════════════════╗
  ║          VPS Magic Backup  v1.0.0               ║
  ║   全栈备份与灾难恢复 · 让 VPS 迁移如丝般顺滑     ║
  ╚══════════════════════════════════════════════════╝

  用法:
    vpsmagic <命令> [选项]

  命令:
    backup          执行全量备份 (采集 + 打包 + 上传)
    upload          仅上传最新的本地备份到远端
    restore         从远端下载并恢复备份
    schedule        管理定时备份任务
      install         安装 cron 定时任务
      remove          移除 cron 定时任务
      status          查看调度状态
    status          查看系统与备份状态概览
    init            交互式初始化配置文件
    help            显示此帮助信息

  全局选项:
    --config <path>   指定配置文件路径
    --dry-run         模拟运行 (不实际执行任何修改)
    --verbose         显示详细调试信息
    --version, -v     显示版本号

  示例:
    # 首次使用：交互式创建配置
    vpsmagic init

    # 执行备份
    vpsmagic backup

    # 模拟备份 (不实际操作)
    vpsmagic backup --dry-run

    # 使用指定配置备份
    vpsmagic backup --config /etc/vpsmagic/config.env

    # 安装每天凌晨3点自动备份
    vpsmagic schedule install

    # 在新 VPS 上恢复
    vpsmagic restore

  文档: https://github.com/your/VPSMagicBackup

EOF
}

# ---------- 版本信息 ----------
show_version() {
  echo "VPS Magic Backup v${VPSMAGIC_VERSION}"
}

# ---------- 状态概览 ----------
show_status() {
  log_banner "VPS Magic Backup — 系统状态"

  echo -e "${_CLR_BOLD}系统信息:${_CLR_NC}"
  echo "  主机名:     $(hostname 2>/dev/null || echo "unknown")"
  echo "  操作系统:   $(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '"' || uname -s)"
  echo "  内核:       $(uname -r 2>/dev/null)"
  echo "  IP:         $(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"
  echo

  echo -e "${_CLR_BOLD}依赖检测:${_CLR_NC}"
  local deps=("docker:Docker" "docker compose:Docker Compose" "rclone:Rclone" "nginx:Nginx" "caddy:Caddy" "mysql:MySQL" "psql:PostgreSQL" "sqlite3:SQLite" "curl:curl" "tar:tar" "openssl:OpenSSL")
  for dep_entry in "${deps[@]}"; do
    local cmd="${dep_entry%%:*}"
    local label="${dep_entry#*:}"
    if command -v ${cmd} >/dev/null 2>&1; then
      local ver=""
      case "${cmd}" in
        docker) ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" ;;
        rclone) ver="$(rclone version 2>/dev/null | head -1 | awk '{print $2}')" ;;
        nginx) ver="$(nginx -v 2>&1 | awk -F/ '{print $2}')" ;;
      esac
      echo -e "  ${_CLR_GREEN}✓${_CLR_NC} ${label} ${ver:+(${ver})}"
    else
      echo -e "  ${_CLR_DIM}✗ ${label}${_CLR_NC}"
    fi
  done
  echo

  print_config

  # 备份状态
  local archive_dir="${BACKUP_ROOT}/archives"
  if [[ -d "${archive_dir}" ]]; then
    local count
    count="$(find "${archive_dir}" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.gz.enc" \) -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo -e "${_CLR_BOLD}本地备份:${_CLR_NC}"
    echo "  存储目录: ${archive_dir}"
    echo "  备份数量: ${count} 份"
    if (( count > 0 )); then
      local newest
      newest="$(ls -t "${archive_dir}"/*.tar.gz* 2>/dev/null | head -1)"
      if [[ -n "${newest}" ]]; then
        echo "  最新备份: $(basename "${newest}")"
        echo "  最新大小: $(human_size "$(get_file_size "${newest}")")"
      fi
      local total_size
      total_size="$(du -sh "${archive_dir}" 2>/dev/null | awk '{print $1}')"
      echo "  总占用:   ${total_size}"
    fi
  else
    echo -e "${_CLR_BOLD}本地备份:${_CLR_NC} 无"
  fi
  echo

  # 远端状态
  if [[ -n "${RCLONE_REMOTE:-}" ]] && command -v rclone >/dev/null 2>&1; then
    echo -e "${_CLR_BOLD}远端备份:${_CLR_NC}"
    echo "  远端路径: ${RCLONE_REMOTE}"
    local remote_count
    remote_count="$(rclone lsf "${RCLONE_REMOTE}/" 2>/dev/null | grep -c '\.tar\.gz' || echo "0")"
    echo "  备份数量: ${remote_count} 份"
  fi
  echo

  # 调度状态
  if crontab -l 2>/dev/null | grep -qF "# VPSMagicBackup"; then
    echo -e "  📅 定时备份: ${_CLR_GREEN}已安装${_CLR_NC}"
  else
    echo -e "  📅 定时备份: ${_CLR_DIM}未安装${_CLR_NC}"
  fi
  echo
}

# ---------- 交互式初始化 ----------
run_init() {
  log_banner "VPS Magic Backup — 初始化配置"

  local target_config="${VPSMAGIC_HOME}/config.env"

  echo "本向导将帮助你创建备份配置文件。"
  echo
  read_with_default target_config "配置文件保存路径" "${target_config}"

  if [[ -f "${target_config}" ]]; then
    if ! confirm "配置文件已存在，是否覆盖？" "n"; then
      log_info "保留现有配置。"
      return 0
    fi
  fi

  safe_mkdir "$(dirname "${target_config}")"

  # ---- 远端存储 ----
  echo
  echo -e "${_CLR_BOLD}第1步: 远端存储配置${_CLR_NC}"
  echo "  VPS Magic 使用 rclone 将备份推送到远端存储。"
  echo "  支持: WebDAV (OpenList/AList)、Google Drive、OneDrive、S3 等"
  echo

  local rclone_remote=""
  if command -v rclone >/dev/null 2>&1; then
    log_info "检测到 rclone，列出已配置的 remote:"
    rclone listremotes 2>/dev/null | while read -r r; do
      echo "    ${r}"
    done
    echo
  else
    log_warn "rclone 未安装。安装方法: curl https://rclone.org/install.sh | sudo bash"
    echo "  安装后，运行 'rclone config' 配置远端存储。"
    echo
  fi

  read_with_default rclone_remote "请输入 rclone remote 路径 (例如: mywebdav:backup/vps1)" ""

  # ---- 备份目录 ----
  echo
  echo -e "${_CLR_BOLD}第2步: 备份存储${_CLR_NC}"
  local backup_root="/opt/vpsmagic/backups"
  read_with_default backup_root "本地备份临时目录" "${backup_root}"

  local keep_local="3"
  read_with_default keep_local "本地保留备份份数" "${keep_local}"

  local keep_remote="30"
  read_with_default keep_remote "远端保留备份份数" "${keep_remote}"

  # ---- 模块选择 ----
  echo
  echo -e "${_CLR_BOLD}第3步: 选择备份模块${_CLR_NC}"
  echo "  按 Enter 保留默认值 (全部启用)，输入 n 禁用。"
  echo

  local -A module_flags=(
    ["ENABLE_DOCKER_COMPOSE"]="Docker Compose 项目"
    ["ENABLE_DOCKER_STANDALONE"]="独立 Docker 容器"
    ["ENABLE_SYSTEMD"]="Systemd 服务"
    ["ENABLE_REVERSE_PROXY"]="反向代理 (Nginx/Caddy)"
    ["ENABLE_DATABASE"]="数据库 (MySQL/PostgreSQL/SQLite)"
    ["ENABLE_SSL_CERTS"]="SSL 证书"
    ["ENABLE_CRONTAB"]="Crontab 定时任务"
    ["ENABLE_FIREWALL"]="防火墙规则"
    ["ENABLE_USER_HOME"]="用户目录"
    ["ENABLE_CUSTOM_PATHS"]="自定义路径"
  )

  local config_content="# ============================================
# VPS Magic Backup 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================

# ---------- 远端存储 (必填) ----------
RCLONE_REMOTE=\"${rclone_remote}\"
# RCLONE_CONF=\"\"            # rclone 配置路径 (留空使用默认)
# RCLONE_BW_LIMIT=\"\"        # 带宽限制 (例如: 10M)

# ---------- 备份存储 ----------
BACKUP_ROOT=\"${backup_root}\"
BACKUP_KEEP_LOCAL=${keep_local}
BACKUP_KEEP_REMOTE=${keep_remote}
BACKUP_PREFIX=\"vpsmagic\"

# ---------- 加密 (可选) ----------
# BACKUP_ENCRYPTION_KEY=\"\"  # 设置后启用 AES-256 加密

# ---------- 备份模块开关 ----------
"

  for key in ENABLE_DOCKER_COMPOSE ENABLE_DOCKER_STANDALONE ENABLE_SYSTEMD ENABLE_REVERSE_PROXY ENABLE_DATABASE ENABLE_SSL_CERTS ENABLE_CRONTAB ENABLE_FIREWALL ENABLE_USER_HOME ENABLE_CUSTOM_PATHS; do
    local label="${module_flags[${key}]}"
    local enabled="true"
    if ! confirm "  启用 ${label}？" "y"; then
      enabled="false"
    fi
    config_content+="${key}=${enabled}
"
  done

  config_content+="
# ---------- 模块参数 ----------
# Docker Compose 项目路径 (auto=自动探测, 或逗号分隔: /opt/app1, /opt/app2)
COMPOSE_PROJECTS=auto

# Systemd 服务列表 (auto=自动探测, 或逗号分隔: myapp, mybot)
SYSTEMD_SERVICES=auto

# 需要备份的用户 (逗号分隔)
BACKUP_USERS=\"root\"

# 自定义备份路径 (逗号分隔)
# EXTRA_PATHS=\"/opt/mydata, /srv/configs\"

# ---------- 数据库 ----------
# MySQL 容器名 (逗号分隔, 留空跳过)
# DB_MYSQL_CONTAINERS=\"\"
# DB_MYSQL_HOST_USER=\"\"
# DB_MYSQL_HOST_PASS=\"\"

# PostgreSQL 容器名
# DB_POSTGRES_CONTAINERS=\"\"

# SQLite 文件路径 (逗号分隔)
# DB_SQLITE_PATHS=\"\"

# ---------- 通知 (可选) ----------
NOTIFY_ENABLED=false
# TG_BOT_TOKEN=\"\"
# TG_CHAT_ID=\"\"

# ---------- 日志 ----------
LOG_FILE=\"/var/log/vpsmagic.log\"

# ---------- 定时备份 ----------
SCHEDULE_CRON=\"0 3 * * *\"
"

  # ---- 通知 ----
  echo
  echo -e "${_CLR_BOLD}第4步: 通知配置 (可选)${_CLR_NC}"
  if confirm "是否启用 Telegram 通知？" "n"; then
    local tg_token=""
    local tg_chat=""
    read_with_default tg_token "Telegram Bot Token" ""
    read_with_default tg_chat "Telegram Chat ID" ""
    config_content="$(echo "${config_content}" | sed "s/NOTIFY_ENABLED=false/NOTIFY_ENABLED=true/")"
    config_content="$(echo "${config_content}" | sed "s|# TG_BOT_TOKEN=\"\"|TG_BOT_TOKEN=\"${tg_token}\"|")"
    config_content="$(echo "${config_content}" | sed "s|# TG_CHAT_ID=\"\"|TG_CHAT_ID=\"${tg_chat}\"|")"
  fi

  # ---- 写入配置文件 ----
  echo "${config_content}" > "${target_config}"
  chmod 600 "${target_config}"

  echo
  log_success "配置文件已生成: ${target_config}"
  echo
  echo -e "${_CLR_BOLD}下一步:${_CLR_NC}"
  echo "  1. 检查并按需调整配置: vim ${target_config}"
  echo "  2. 测试备份 (模拟):    vpsmagic backup --dry-run --config ${target_config}"
  echo "  3. 执行真实备份:        vpsmagic backup --config ${target_config}"
  echo "  4. 安装定时备份:        vpsmagic schedule install"
  echo
}

# ---------- 参数解析 ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      backup|upload|restore|schedule|status|init|help)
        SUBCOMMAND="$1"
        shift
        # 收集子命令参数
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry-run)  DRY_RUN=1; shift ;;
            --verbose)  VERBOSE=1; shift ;;
            --config)
              [[ $# -ge 2 ]] || { log_error "--config 需要一个参数"; exit 1; }
              CONFIG_FILE="$2"; shift 2 ;;
            *)
              SUBCMD_ARGS+=("$1"); shift ;;
          esac
        done
        ;;
      --dry-run)  DRY_RUN=1; shift ;;
      --verbose)  VERBOSE=1; shift ;;
      --config)
        [[ $# -ge 2 ]] || { log_error "--config 需要一个参数"; exit 1; }
        CONFIG_FILE="$2"; shift 2 ;;
      --version|-v)
        show_version; exit 0 ;;
      --help|-h)
        show_help; exit 0 ;;
      *)
        log_error "未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

# ---------- 主函数 ----------
main() {
  parse_args "$@"

  # 无子命令时显示帮助
  if [[ -z "${SUBCOMMAND}" ]]; then
    show_help
    exit 0
  fi

  # 特殊子命令不需要配置
  case "${SUBCOMMAND}" in
    help)
      show_help
      exit 0
      ;;
    init)
      run_init
      exit 0
      ;;
  esac

  # 加载配置
  load_config "${CONFIG_FILE}"

  # dry-run 提示
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo
    log_warn "══════ DRY-RUN 模式: 不会执行任何实际操作 ══════"
    echo
  fi

  # 路由子命令
  case "${SUBCOMMAND}" in
    backup)
      validate_config "backup" || exit 1
      run_backup
      ;;
    upload)
      validate_config "upload" || exit 1
      run_upload
      ;;
    restore)
      validate_config "restore" || exit 1
      run_restore
      ;;
    schedule)
      run_schedule "${SUBCMD_ARGS[0]:-status}"
      ;;
    status)
      show_status
      ;;
    *)
      log_error "未知命令: ${SUBCOMMAND}"
      show_help
      exit 1
      ;;
  esac
}

# ---------- 执行 ----------
main "$@"
