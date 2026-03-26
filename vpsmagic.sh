#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 主入口脚本
# 版本: v1.0.2
#
# 一套面向个人/小团队 VPS 运维的全栈备份与灾难恢复工具。
# 支持 Docker Compose / 独立容器 / Systemd / 反代 / 数据库 /
# SSL / Crontab / 防火墙 / 用户目录 / 自定义路径 的备份与恢复。
#
# 用法:
#   vpsmagic backup   [--dry-run] [--config path]
#                     [--dest local|remote] [--remote rclone:path]
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
resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  while [[ -L "${source}" ]]; do
    local dir
    dir="$(cd -P "$(dirname "${source}")" && pwd)"
    source="$(readlink "${source}")"
    [[ "${source}" != /* ]] && source="${dir}/${source}"
  done
  cd -P "$(dirname "${source}")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"

# ---------- 全局运行选项 ----------
DRY_RUN=0
VERBOSE=0
CONFIG_FILE=""
SUBCOMMAND=""
SUBCMD_ARGS=()
SHOW_HELP_ONLY=0
SHOW_VERSION_ONLY=0
RESTORE_LOCAL_FILE="${RESTORE_LOCAL_FILE:-}"
RESTORE_AUTO_CONFIRM="${RESTORE_AUTO_CONFIRM:-0}"
CLI_BACKUP_DESTINATION=""
CLI_BACKUP_REMOTE_OVERRIDE=""
CLI_UI_LANG=""

# ---------- 加载库文件 ----------
# shellcheck source=lib/i18n.sh
source "${SCRIPT_DIR}/lib/i18n.sh"
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
# shellcheck source=modules/migrate.sh
source "${SCRIPT_DIR}/modules/migrate.sh"

# ---------- 帮助信息 ----------
show_help() {
  if is_lang_en; then
    cat <<'EOF'

  ╔══════════════════════════════════════════════════╗
  ║          VPS Magic Backup  v1.0.2               ║
  ║   Full-stack backup and disaster recovery       ║
  ╚══════════════════════════════════════════════════╝

  Usage:
    vpsmagic <command> [options]

  Commands:
    backup          Run full backup (collect + package + upload)
    upload          Upload the latest local backup to remote only
    restore         Download and restore from remote backup
    migrate         Migrate online to another VPS over SSH
    schedule        Manage scheduled backup jobs
      install         Install cron job
      remove          Remove cron job
      status          Show scheduler status
    status          Show system, config, and backup overview
    init            Create config interactively
    help            Show this help

  Global options:
    --config <path>   Use a specific config file
    --dry-run         Simulate actions without making changes
    --dest <mode>     Backup destination mode: local or remote
    --remote <path>   Use a temporary rclone remote path for this run
    --lang <lang>     Interface language: zh or en
    --verbose         Show verbose debug logs
    --version, -v     Show version

  Examples:
    # First run: create config interactively
    vpsmagic init

    # Run backup
    vpsmagic backup

    # Local archive only, skip remote upload
    vpsmagic backup --dest local

    # Upload to a temporary remote target for this run
    vpsmagic backup --remote oracle:bucket/vps1

    # Dry-run
    vpsmagic backup --dry-run

    # Use a specific config file
    vpsmagic backup --config /etc/vpsmagic/config.env

    # Install daily backup at 03:00
    vpsmagic schedule install

    # Restore on a new VPS (from remote)
    vpsmagic restore

    # Restore from a local archive
    vpsmagic restore --local /path/to/backup.tar.gz

    # Online migration to a new VPS
    vpsmagic migrate root@new-vps
    vpsmagic migrate root@new-vps -p 2222 --bwlimit 10m
    vpsmagic migrate root@new-vps --skip-restore

  Docs: https://github.com/tonysbb/VPSMagic

EOF
  else
    cat <<'EOF'

  ╔══════════════════════════════════════════════════╗
  ║          VPS Magic Backup  v1.0.2               ║
  ║   全栈备份与灾难恢复 · 让 VPS 迁移如丝般顺滑     ║
  ╚══════════════════════════════════════════════════╝

  用法:
    vpsmagic <命令> [选项]

  命令:
    backup          执行全量备份 (采集 + 打包 + 上传)
    upload          仅上传最新的本地备份到远端
    restore         从远端下载并恢复备份
    migrate         在线迁移到另一台 VPS (直推模式)
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
    --dest <mode>     备份目标模式: local 或 remote
    --remote <path>   本次执行使用指定 rclone 远端路径
    --lang <lang>     界面语言: zh 或 en
    --verbose         显示详细调试信息
    --version, -v     显示版本号

  示例:
    # 首次使用：交互式创建配置
    vpsmagic init

    # 执行备份
    vpsmagic backup

    # 仅做本地归档，不上传远端
    vpsmagic backup --dest local

    # 本次临时上传到指定远端
    vpsmagic backup --remote oracle:bucket/vps1

    # 模拟备份 (不实际操作)
    vpsmagic backup --dry-run

    # 使用指定配置备份
    vpsmagic backup --config /etc/vpsmagic/config.env

    # 安装每天凌晨3点自动备份
    vpsmagic schedule install

    # 在新 VPS 上恢复 (从远端)
    vpsmagic restore

    # 从本地文件恢复
    vpsmagic restore --local /path/to/backup.tar.gz

    # 在线迁移到新 VPS
    vpsmagic migrate root@new-vps
    vpsmagic migrate root@new-vps -p 2222 --bwlimit 10m
    vpsmagic migrate root@new-vps --skip-restore

  文档: https://github.com/tonysbb/VPSMagic

EOF
  fi
}

# ---------- 版本信息 ----------
show_version() {
  echo "VPS Magic Backup v${VPSMAGIC_VERSION}"
}

# ---------- 状态概览 ----------
show_status() {
  log_banner "$(lang_pick "VPS Magic Backup — 系统状态" "VPS Magic Backup — System Status")"

  echo -e "${_CLR_BOLD}$(lang_pick "系统信息" "System info"):${_CLR_NC}"
  echo "  $(lang_pick "主机名" "Hostname"):     $(hostname 2>/dev/null || echo "unknown")"
  echo "  $(lang_pick "操作系统" "Operating system"):   $(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '"' || uname -s)"
  echo "  $(lang_pick "内核" "Kernel"):       $(uname -r 2>/dev/null)"
  echo "  IP:         $(get_primary_ip)"
  echo

  echo -e "${_CLR_BOLD}$(lang_pick "依赖检测" "Dependency check"):${_CLR_NC}"
  local deps=("docker:Docker" "docker compose:Docker Compose" "rclone:Rclone" "rsync:Rsync" "nginx:Nginx" "caddy:Caddy" "mysql:MySQL" "psql:PostgreSQL" "sqlite3:SQLite" "curl:curl" "tar:tar" "openssl:OpenSSL")
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
    echo -e "${_CLR_BOLD}$(lang_pick "本地备份" "Local backups"):${_CLR_NC}"
    echo "  $(lang_pick "存储目录" "Storage path"): ${archive_dir}"
    echo "  $(lang_pick "备份数量" "Backup count"): ${count} $(lang_pick "份" "copies")"
    if (( count > 0 )); then
      local newest
      newest="$(get_newest_archive_file "${archive_dir}")"
      if [[ -n "${newest}" ]]; then
        echo "  $(lang_pick "最新备份" "Latest backup"): $(basename "${newest}")"
        echo "  $(lang_pick "最新大小" "Latest size"): $(human_size "$(get_file_size "${newest}")")"
      fi
      local total_size
      total_size="$(du -sh "${archive_dir}" 2>/dev/null | awk '{print $1}')"
      echo "  $(lang_pick "总占用" "Total size"):   ${total_size}"
    fi
  else
    echo -e "${_CLR_BOLD}$(lang_pick "本地备份" "Local backups"):${_CLR_NC} $(lang_pick "无" "none")"
  fi
  echo

  # 远端状态
  if command -v rclone >/dev/null 2>&1; then
    local -a backup_targets=()
    get_backup_targets backup_targets
    if [[ ${#backup_targets[@]} -gt 0 ]]; then
      echo -e "${_CLR_BOLD}$(lang_pick "远端备份" "Remote backups"):${_CLR_NC}"
      local remote_target=""
      for remote_target in "${backup_targets[@]}"; do
        local remote_count
        remote_count="$(rclone lsf "${remote_target}/" 2>/dev/null | awk '/\.tar\.gz(\.enc)?$/ {count+=1} END {print count+0}')"
        echo "  ${remote_target}: ${remote_count} $(lang_pick "份" "copies")"
      done
    fi
  fi
  echo

  # 调度状态
  if crontab -l 2>/dev/null | grep -qF "# VPSMagicBackup"; then
    echo -e "  📅 $(lang_pick "定时备份" "Scheduled backup"): ${_CLR_GREEN}$(install_status_label 1)${_CLR_NC}"
  else
    echo -e "  📅 $(lang_pick "定时备份" "Scheduled backup"): ${_CLR_DIM}$(install_status_label 0)${_CLR_NC}"
  fi
  echo
}

# ---------- 交互式初始化 ----------
run_init() {
  log_banner "$(lang_pick "VPS Magic Backup — 初始化配置" "VPS Magic Backup — Initialize Config")"

  local target_config="${VPSMAGIC_HOME}/config.env"

  echo "$(lang_pick "本向导将帮助你创建备份配置文件。" "This wizard will help you create a backup config file.")"
  echo
  read_with_default target_config "$(lang_pick "配置文件保存路径" "Config file path")" "${target_config}"

  if [[ -f "${target_config}" ]]; then
    if ! confirm "$(lang_pick "配置文件已存在，是否覆盖？" "Config file already exists. Overwrite?")" "n"; then
      log_info "$(lang_pick "保留现有配置。" "Keeping the existing config.")"
      return 0
    fi
  fi

  safe_mkdir "$(dirname "${target_config}")"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "第1步: 远端存储配置" "Step 1: Remote storage")${_CLR_NC}"
  echo "  $(lang_pick "VPS Magic 使用 rclone 将备份推送到远端存储。" "VPS Magic uses rclone to push backups to remote storage.")"
  echo "  $(lang_pick "支持: WebDAV (OpenList/AList)、Google Drive、OneDrive、S3 等" "Supported: WebDAV (OpenList/AList), Google Drive, OneDrive, S3, and more")"
  echo

  local backup_targets=""
  local detected_host
  detected_host="$(hostname 2>/dev/null || echo 'vps')"
  if command -v rclone >/dev/null 2>&1; then
    log_info "$(lang_pick "检测到 rclone，列出已配置的 remote:" "rclone detected. Listing configured remotes:")"
    rclone listremotes 2>/dev/null | while read -r r; do
      echo "    ${r}"
    done
    echo
  else
    log_warn "$(lang_pick "rclone 未安装。安装方法: curl https://rclone.org/install.sh | sudo bash" "rclone is not installed. Install with: curl https://rclone.org/install.sh | sudo bash")"
    echo "  $(lang_pick "安装后，运行 'rclone config' 配置远端存储。" "After installation, run 'rclone config' to configure remote storage.")"
    echo
  fi

  echo "  $(lang_pick "留空 = 使用默认优先级:" "Leave empty to use the default priority order:")"
  echo "    1. gdrive:VPSMagicBackup/${detected_host}"
  echo "    2. onedrive:VPSMagicBackup/${detected_host}"
  echo "    3. openlist_webdav:backup/${detected_host}"
  echo "  $(lang_pick "也可以输入多个完整路径，逗号分隔，按顺序尝试。" "You can also enter multiple full paths separated by commas.")"
  read_with_default backup_targets "$(lang_pick "请输入备份目标列表 (可留空使用默认策略)" "Enter backup targets (optional, leave empty for defaults)")" ""

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "第2步: 备份存储" "Step 2: Backup storage")${_CLR_NC}"
  local backup_root="/opt/vpsmagic/backups"
  read_with_default backup_root "$(lang_pick "本地备份临时目录" "Local backup workspace")" "${backup_root}"

  local disk_avail
  disk_avail="$(get_disk_avail_bytes "${backup_root}" 2>/dev/null || echo "0")"
  local disk_total
  disk_total="$(get_disk_total_bytes "${backup_root}" 2>/dev/null || echo "0")"
  local recommended_keep
  recommended_keep="$(recommend_local_keep "${backup_root}" 2>/dev/null || echo "3")"

  echo
  echo -e "  ${_CLR_DIM}$(lang_pick "📊 磁盘空间分析" "📊 Disk capacity analysis"):${_CLR_NC}"
  if (( disk_total > 0 )); then
    echo "     $(lang_pick "总容量" "Total"): $(human_size "${disk_total}")"
    echo "     $(lang_pick "可用" "Available"):   $(human_size "${disk_avail}")"
    echo "     $(lang_pick "💡 基于可用空间，推荐本地保留" "💡 Recommended local retention based on free space"): ${recommended_keep} $(lang_pick "份" "copies")"
    echo "     $(lang_pick "(留 20% 安全余量给系统，旧备份自动滚动删除)" "(keeps a 20% safety margin and rotates old backups automatically)")"
  else
    echo "     $(lang_pick "无法检测磁盘空间，使用默认值: 3 份" "Unable to detect disk size. Using default retention: 3 copies")"
    recommended_keep="3"
  fi
  echo

  local keep_local="${recommended_keep}"
  read_with_default keep_local "$(lang_pick "本地保留备份份数" "Local retention copies")" "${keep_local}"

  local keep_remote="30"
  read_with_default keep_remote "$(lang_pick "远端保留备份份数" "Remote retention copies")" "${keep_remote}"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "第3步: 选择备份模块" "Step 3: Select backup modules")${_CLR_NC}"
  echo "  $(lang_pick "按 Enter 保留默认值 (全部启用)，输入 n 禁用。" "Press Enter to keep the default (enabled), or type n to disable.")"
  echo

  local module_flags=(
    "ENABLE_DOCKER_COMPOSE:$(module_display_name "DOCKER_COMPOSE")"
    "ENABLE_DOCKER_STANDALONE:$(module_display_name "DOCKER_STANDALONE")"
    "ENABLE_SYSTEMD:$(module_display_name "SYSTEMD")"
    "ENABLE_REVERSE_PROXY:$(lang_pick "反向代理 (Nginx/Caddy)" "Reverse proxy (Nginx/Caddy)")"
    "ENABLE_DATABASE:$(lang_pick "数据库 (MySQL/PostgreSQL/SQLite)" "Databases (MySQL/PostgreSQL/SQLite)")"
    "ENABLE_SSL_CERTS:$(module_display_name "SSL_CERTS")"
    "ENABLE_CRONTAB:$(module_display_name "CRONTAB")"
    "ENABLE_FIREWALL:$(module_display_name "FIREWALL")"
    "ENABLE_USER_HOME:$(module_display_name "USER_HOME")"
    "ENABLE_CUSTOM_PATHS:$(module_display_name "CUSTOM_PATHS")"
  )

  local config_content="# ============================================
# VPS Magic Backup config
# Generated at: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================

UI_LANG=\"${UI_LANG:-zh}\"

# ---------- Remote storage ----------
BACKUP_TARGETS=\"${backup_targets}\"
RCLONE_REMOTE=\"\"
# RCLONE_CONF=\"\"
# RCLONE_BW_LIMIT=\"\"

# ---------- Backup storage ----------
BACKUP_ROOT=\"${backup_root}\"
BACKUP_KEEP_LOCAL=${keep_local}
BACKUP_KEEP_REMOTE=${keep_remote}
BACKUP_PREFIX=\"vpsmagic\"
BACKUP_DESTINATION=\"remote\"
# BACKUP_REMOTE_OVERRIDE=\"\"

# ---------- Encryption (optional) ----------
# BACKUP_ENCRYPTION_KEY=\"\"

# ---------- Backup modules ----------
"

  local entry key label enabled
  for entry in "${module_flags[@]}"; do
    key="${entry%%:*}"
    label="${entry#*:}"
    enabled="true"
    if ! confirm "$(lang_pick "  启用" "  Enable") ${label}?" "y"; then
      enabled="false"
    fi
    config_content+="${key}=${enabled}
"
  done

  config_content+="
# ---------- Module options ----------
COMPOSE_PROJECTS=auto
SYSTEMD_SERVICES=auto
BACKUP_USERS=\"root\"
# EXTRA_PATHS=\"/opt/mydata, /srv/configs\"

# ---------- Databases ----------
# DB_MYSQL_CONTAINERS=\"\"
# DB_MYSQL_HOST_USER=\"\"
# DB_MYSQL_HOST_PASS=\"\"
# DB_POSTGRES_CONTAINERS=\"\"
# DB_SQLITE_PATHS=\"\"

# ---------- Notifications ----------
NOTIFY_ENABLED=false
# TG_BOT_TOKEN=\"\"
# TG_CHAT_ID=\"\"

# ---------- Logging ----------
LOG_FILE=\"/var/log/vpsmagic.log\"

# ---------- Schedule ----------
SCHEDULE_CRON=\"0 3 * * *\"
"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "第4步: 通知配置 (可选)" "Step 4: Notifications (optional)")${_CLR_NC}"
  if confirm "$(lang_pick "是否启用 Telegram 通知？" "Enable Telegram notifications?")" "n"; then
    local tg_token=""
    local tg_chat=""
    read_with_default tg_token "Telegram Bot Token" ""
    read_with_default tg_chat "Telegram Chat ID" ""
    config_content="$(echo "${config_content}" | sed "s/NOTIFY_ENABLED=false/NOTIFY_ENABLED=true/")"
    config_content="$(echo "${config_content}" | sed "s|# TG_BOT_TOKEN=\"\"|TG_BOT_TOKEN=\"${tg_token}\"|")"
    config_content="$(echo "${config_content}" | sed "s|# TG_CHAT_ID=\"\"|TG_CHAT_ID=\"${tg_chat}\"|")"
  fi

  echo "${config_content}" > "${target_config}"
  chmod 600 "${target_config}"

  echo
  log_success "$(lang_pick "配置文件已生成" "Config file created"): ${target_config}"
  echo
  echo -e "${_CLR_BOLD}$(lang_pick "下一步" "Next steps"):${_CLR_NC}"
  echo "  1. $(lang_pick "检查并按需调整配置" "Review and adjust config"): vim ${target_config}"
  echo "  2. $(lang_pick "测试备份 (模拟)" "Test backup (dry-run)"):    vpsmagic backup --dry-run --config ${target_config}"
  echo "  3. $(lang_pick "执行真实备份" "Run a real backup"):        vpsmagic backup --config ${target_config}"
  echo "  4. $(lang_pick "安装定时备份" "Install schedule"):        vpsmagic schedule install"
  echo
}

# ---------- 参数解析 ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      backup|upload|restore|schedule|status|init|help|migrate)
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
            --dest)
              [[ $# -ge 2 ]] || { log_error "--dest 需要一个参数"; exit 1; }
              CLI_BACKUP_DESTINATION="$2"; shift 2 ;;
            --remote)
              [[ $# -ge 2 ]] || { log_error "--remote 需要一个参数"; exit 1; }
              CLI_BACKUP_REMOTE_OVERRIDE="$2"; shift 2 ;;
            --lang)
              [[ $# -ge 2 ]] || { log_error "--lang 需要一个参数"; exit 1; }
              CLI_UI_LANG="$2"; set_ui_language "$2"; shift 2 ;;
            --local)
              # restore --local <path>
              [[ $# -ge 2 ]] || { log_error "--local 需要指定备份文件路径"; exit 1; }
              RESTORE_LOCAL_FILE="$2"; shift 2 ;;
            --auto-confirm)
              RESTORE_AUTO_CONFIRM=1; shift ;;
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
      --dest)
        [[ $# -ge 2 ]] || { log_error "--dest 需要一个参数"; exit 1; }
        CLI_BACKUP_DESTINATION="$2"; shift 2 ;;
      --remote)
        [[ $# -ge 2 ]] || { log_error "--remote 需要一个参数"; exit 1; }
        CLI_BACKUP_REMOTE_OVERRIDE="$2"; shift 2 ;;
      --lang)
        [[ $# -ge 2 ]] || { log_error "--lang 需要一个参数"; exit 1; }
        CLI_UI_LANG="$2"; set_ui_language "$2"; shift 2 ;;
      --version|-v)
        SHOW_VERSION_ONLY=1; shift ;;
      --help|-h)
        SHOW_HELP_ONLY=1; shift ;;
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
  set_ui_language "${CLI_UI_LANG:-}"

  if [[ "${SHOW_VERSION_ONLY}" == "1" ]]; then
    show_version
    exit 0
  fi

  if [[ "${SHOW_HELP_ONLY}" == "1" ]]; then
    show_help
    exit 0
  fi

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
  set_ui_language "${CLI_UI_LANG:-${UI_LANG:-}}"

  # 命令行参数优先于配置文件
  if [[ -n "${CLI_BACKUP_DESTINATION}" ]]; then
    BACKUP_DESTINATION="${CLI_BACKUP_DESTINATION}"
  fi
  if [[ -n "${CLI_BACKUP_REMOTE_OVERRIDE}" ]]; then
    BACKUP_REMOTE_OVERRIDE="${CLI_BACKUP_REMOTE_OVERRIDE}"
  fi
  if [[ -n "${CLI_UI_LANG}" ]]; then
    UI_LANG="${CLI_UI_LANG}"
    set_ui_language "${UI_LANG}"
  fi

  # 高权限命令保护，避免非 root 运行产生不完整结果
  case "${SUBCOMMAND}" in
    backup|upload|restore|migrate)
      require_root
      ;;
    schedule)
      local schedule_action="${SUBCMD_ARGS[0]:-status}"
      [[ "${schedule_action}" != "status" ]] && require_root
      ;;
  esac

  # dry-run 提示
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo
    log_warn "$(lang_pick "══════ DRY-RUN 模式: 不会执行任何实际操作 ══════" "══════ DRY-RUN mode: no real changes will be made ══════")"
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
    migrate)
      validate_config "migrate" || exit 1
      run_migrate
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
