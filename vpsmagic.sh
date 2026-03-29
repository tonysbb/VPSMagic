#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 主入口脚本
# 版本: v1.0.4
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
#   vpsmagic doctor
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
RESTORE_ROLLBACK_ON_FAILURE="${RESTORE_ROLLBACK_ON_FAILURE:-false}"
RESTORE_SOURCE_HOSTNAME="${RESTORE_SOURCE_HOSTNAME:-}"
CLI_BACKUP_DESTINATION=""
CLI_BACKUP_REMOTE_OVERRIDE=""
CLI_UI_LANG=""
CLI_RESTORE_ROLLBACK_ON_FAILURE=""
CLI_RESTORE_SOURCE_HOSTNAME=""

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
  ║          VPS Magic Backup  v1.0.4               ║
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
    doctor          Classify this VPS and suggest a safe adoption path
    init            Create config interactively
    help            Show this help

  Global options:
    --config <path>   Use a specific config file
    --dry-run         Simulate actions without making changes
    --dest <mode>     Backup destination mode: local or remote
    --remote <path>   Use a temporary rclone remote path for this run
    --lang <lang>     Interface language: zh or en
    --auto-confirm    Skip interactive confirmation prompts during restore
    --rollback-on-failure
                      Auto-run lightweight rollback if restore fails
    --source-hostname <name>
                      Use this source hostname when expanding {hostname} during restore
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

    # Unattended restore with lightweight auto-rollback on failure
    vpsmagic restore --auto-confirm --rollback-on-failure

    # Cross-host restore: resolve {hostname} as the source host
    vpsmagic restore --source-hostname source-vps

    # Online migration to a new VPS
    vpsmagic migrate root@new-vps
    vpsmagic migrate root@new-vps -p 2222 --bwlimit 10m
    vpsmagic migrate root@new-vps --skip-restore

  Docs: https://github.com/tonysbb/VPSMagic

EOF
  else
    cat <<'EOF'

  ╔══════════════════════════════════════════════════╗
  ║          VPS Magic Backup  v1.0.4               ║
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
    doctor          识别当前 VPS 画像并给出接入建议
    init            交互式初始化配置文件
    help            显示此帮助信息

  全局选项:
    --config <path>   指定配置文件路径
    --dry-run         模拟运行 (不实际执行任何修改)
    --dest <mode>     备份目标模式: local 或 remote
    --remote <path>   本次执行使用指定 rclone 远端路径
    --lang <lang>     界面语言: zh 或 en
    --auto-confirm    restore 时跳过交互确认
    --rollback-on-failure
                      restore 失败后自动执行轻量回滚
    --source-hostname <name>
                      restore 时将 {hostname} 按源主机名展开
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

    # 无人值守恢复，失败后自动轻量回滚
    vpsmagic restore --auto-confirm --rollback-on-failure

    # 跨机恢复：将 {hostname} 按源主机名展开
    vpsmagic restore --source-hostname source-vps

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

  local status_mode="backup"
  if [[ -n "${RESTORE_SOURCE_HOSTNAME:-}" ]]; then
    status_mode="restore"
  fi
  print_config "${status_mode}"

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
    if [[ "${status_mode}" == "restore" ]]; then
      get_restore_targets backup_targets
    else
      get_backup_targets backup_targets
    fi
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

# ---------- 接入识别 ----------
_doctor_has_docker_compose() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

_doctor_count_compose_projects() {
  local seen="" sdir compose_file dir

  if _doctor_has_docker_compose; then
    local compose_ls_json=""
    compose_ls_json="$(docker compose ls --format json 2>/dev/null || true)"
    if [[ -n "${compose_ls_json}" ]]; then
      while IFS= read -r dir; do
        [[ -z "${dir}" ]] && continue
        if [[ "${seen}" != *$'\n'"${dir}"$'\n'* ]]; then
          seen+=$'\n'"${dir}"$'\n'
        fi
      done < <(printf '%s' "${compose_ls_json}" | grep -o '"ConfigFiles":"[^"]*"' | sed -E 's/^"ConfigFiles":"//; s/"$//' | tr ',' '\n' | xargs -I{} dirname "{}" 2>/dev/null || true)
    fi
  fi

  for sdir in /opt /srv /root /home; do
    [[ -d "${sdir}" ]] || continue
    while IFS= read -r compose_file; do
      [[ -z "${compose_file}" ]] && continue
      dir="$(dirname "${compose_file}")"
      if [[ "${seen}" != *$'\n'"${dir}"$'\n'* ]]; then
        seen+=$'\n'"${dir}"$'\n'
      fi
    done < <(find "${sdir}" -maxdepth 4 \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null || true)
  done

  printf '%s' "${seen}" | sed '/^$/d' | wc -l | tr -d ' '
}

_doctor_count_standalone_containers() {
  local count=0 cid label
  command -v docker >/dev/null 2>&1 || { echo "0"; return; }

  while IFS= read -r cid; do
    [[ -z "${cid}" ]] && continue
    label="$(docker inspect "${cid}" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
    [[ -n "${label}" ]] && continue
    count=$((count + 1))
  done < <(docker ps -aq 2>/dev/null || true)

  echo "${count}"
}

_doctor_count_custom_systemd_services() {
  local count=0 svc_name
  [[ -d /etc/systemd/system ]] || { echo "0"; return; }

  while IFS= read -r svc_name; do
    [[ -z "${svc_name}" ]] && continue
    if [[ "${svc_name}" =~ ^(dbus|ssh|sshd|rsyslog|cron|systemd-|getty|network|snap|cloud-|plymouth-|chrony|ufw) ]]; then
      continue
    fi
    count=$((count + 1))
  done < <(find /etc/systemd/system -maxdepth 1 -name "*.service" -type f 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.service$//' || true)

  echo "${count}"
}

_doctor_detect_reverse_proxy() {
  local found=()
  [[ -d /etc/caddy ]] && found+=("Caddy")
  [[ -d /etc/nginx ]] && found+=("Nginx")
  [[ -d /etc/apache2 ]] && found+=("Apache")
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "$(lang_pick "未发现" "none detected")"
  else
    local IFS=", "
    echo "${found[*]}"
  fi
}

_doctor_detect_databases() {
  local found=()
  if [[ -d /etc/mysql || -d /var/lib/mysql ]]; then
    found+=("MySQL")
  fi
  if [[ -d /etc/postgresql || -d /var/lib/postgresql ]]; then
    found+=("PostgreSQL")
  fi
  if find /opt /srv /var/www /root -maxdepth 4 \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) -type f 2>/dev/null | head -n 1 | grep -q .; then
    found+=("SQLite")
  fi
  if [[ ${#found[@]} -eq 0 ]]; then
    echo ""
  else
    local IFS=", "
    echo "${found[*]}"
  fi
}

_doctor_count_user_home_candidates() {
  local count
  count="$(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  [[ -d /root ]] && count=$((count + 1))
  echo "${count}"
}

_doctor_detect_profile() {
  local compose_count="${1:-0}"
  local standalone_count="${2:-0}"
  local systemd_count="${3:-0}"
  local has_db="${4:-0}"

  if (( compose_count > 0 && standalone_count == 0 && has_db == 0 )); then
    echo "$(lang_pick "标准 Compose 应用型" "Standard Compose app VPS")"
  elif (( compose_count > 0 && has_db == 1 )); then
    echo "$(lang_pick "带数据库的 Compose 应用型" "Compose app VPS with databases")"
  elif (( standalone_count > 0 )); then
    echo "$(lang_pick "混合 Docker 业务型" "Mixed Docker workload VPS")"
  elif (( systemd_count > 0 )); then
    echo "$(lang_pick "Systemd 服务型" "Systemd service VPS")"
  else
    echo "$(lang_pick "轻量通用 VPS" "Lightweight general-purpose VPS")"
  fi
}

_doctor_risk_label() {
  case "${1:-1}" in
    3) echo "$(lang_pick "高" "High")" ;;
    2) echo "$(lang_pick "中" "Medium")" ;;
    *) echo "$(lang_pick "低" "Low")" ;;
  esac
}

run_doctor() {
  log_banner "$(lang_pick "VPS Magic Backup — 接入识别" "VPS Magic Backup — Adoption Doctor")"

  local compose_count standalone_count systemd_count user_home_count remote_count
  local reverse_proxy db_list has_db profile
  local has_explicit_remote_config=0
  local requires_oci_credentials=0
  local has_non_oci_target=0
  local has_docker=0
  local has_docker_compose=0
  local has_rclone=0
  local has_oci_config=0
  local risk_score=1
  local recommendation=""
  local -a configured_restore_targets=()
  local -a blocking_items=()
  local -a caution_items=()

  compose_count="$(_doctor_count_compose_projects)"
  standalone_count="$(_doctor_count_standalone_containers)"
  systemd_count="$(_doctor_count_custom_systemd_services)"
  user_home_count="$(_doctor_count_user_home_candidates)"
  reverse_proxy="$(_doctor_detect_reverse_proxy)"
  db_list="$(_doctor_detect_databases)"
  has_db=0
  [[ -n "${db_list}" ]] && has_db=1
  profile="$(_doctor_detect_profile "${compose_count}" "${standalone_count}" "${systemd_count}" "${has_db}")"

  remote_count=0
  command -v docker >/dev/null 2>&1 && has_docker=1
  _doctor_has_docker_compose && has_docker_compose=1
  [[ -f /root/.oci/config ]] && has_oci_config=1
  if command -v rclone >/dev/null 2>&1; then
    has_rclone=1
    remote_count="$(rclone listremotes 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -n "${BACKUP_REMOTE_OVERRIDE:-}" || -n "${BACKUP_TARGETS:-}" || -n "${RCLONE_REMOTE:-}" || -n "${BACKUP_PRIMARY_TARGET:-}" || -n "${BACKUP_ASYNC_TARGET:-}" ]]; then
    has_explicit_remote_config=1
    get_restore_targets configured_restore_targets
    local configured_target=""
    for configured_target in "${configured_restore_targets[@]}"; do
      if [[ "${configured_target}" == OOS:* || "${configured_target}" == oos:* ]]; then
        requires_oci_credentials=1
      else
        has_non_oci_target=1
      fi
    done
  fi

  if (( has_explicit_remote_config == 1 )); then
    if (( has_rclone == 0 )); then
      blocking_items+=("$(lang_pick "当前已配置远端恢复，但目标机还没有安装 rclone" "Remote restore is configured, but rclone is not installed on this host yet")")
      risk_score=3
    elif (( remote_count == 0 )); then
      blocking_items+=("$(lang_pick "当前已配置远端恢复，但 rclone 里还没有可用 remote" "Remote restore is configured, but no usable rclone remotes are available yet")")
      risk_score=3
    fi
    if (( requires_oci_credentials == 1 )) && (( has_oci_config == 0 )); then
      if (( has_non_oci_target == 1 )); then
        caution_items+=("$(lang_pick "OCI 主目标当前不可用；如已配置其他远端，可先走备用远端或本地恢复" "The OCI primary target is not ready; if another remote is configured, use the fallback remote or local restore first")")
        (( risk_score < 2 )) && risk_score=2
      else
        blocking_items+=("$(lang_pick "当前远端路径依赖 OCI，但目标机缺少 /root/.oci/config" "The configured remote path depends on OCI, but /root/.oci/config is missing on this host")")
        risk_score=3
      fi
    fi
  else
    if (( has_rclone == 0 )); then
      recommendation="$(lang_pick "先走仅本地初始化和本地恢复演练，远端访问后续再配置" "Start with local-only init and a local restore rehearsal; add remote access later")"
    else
      recommendation="$(lang_pick "先完成一次本地恢复演练，再决定是否启用远端备份/恢复" "Complete one local restore rehearsal first, then decide whether to enable remote backup/restore")"
    fi
  fi

  if (( compose_count > 0 )) && (( has_docker == 0 || has_docker_compose == 0 )); then
    caution_items+=("$(lang_pick "检测到 Compose 业务，但当前机还缺 Docker / Compose；恢复时会依赖自动补齐" "Compose workloads were detected, but Docker / Compose is currently missing; restore will rely on dependency bootstrap")")
    (( risk_score < 2 )) && risk_score=2
  fi
  if (( systemd_count > 0 )); then
    caution_items+=("$(lang_pick "存在自定义 Systemd 服务，恢复后仍需人工确认服务行为" "Custom Systemd services are present; service behavior still needs manual verification after restore")")
    (( risk_score < 2 )) && risk_score=2
  fi
  if (( has_db == 1 )); then
    caution_items+=("$(lang_pick "存在数据库，恢复后还需要业务侧一致性校验" "Databases are present; business-level consistency still needs validation after restore")")
    (( risk_score < 2 )) && risk_score=2
  fi
  if (( standalone_count > 0 )); then
    caution_items+=("$(lang_pick "存在独立 Docker 容器，这类场景更适合作为重建线索而非承诺自动恢复" "Standalone Docker containers are present; treat them as rebuild-oriented clues rather than guaranteed automatic recovery")")
    risk_score=3
  fi

  if [[ -z "${recommendation}" ]]; then
    if (( ${#blocking_items[@]} > 0 )); then
      recommendation="$(lang_pick "当前不建议直接正式恢复；先补齐阻塞项，再执行一次恢复前置检查" "Do not start a real restore yet; clear the blocking items first, then rerun restore preflight")"
    elif (( risk_score >= 3 )); then
      recommendation="$(lang_pick "可继续评估，但正式切换前必须先完成一次恢复演练" "You may continue evaluation, but a restore rehearsal is required before real cutover")"
    elif (( has_explicit_remote_config == 1 )); then
      recommendation="$(lang_pick "可以先做一次远端恢复前置检查；正式切换前仍建议先完成本地恢复演练" "You can run one remote restore preflight now; a local restore rehearsal is still recommended before cutover")"
    else
      recommendation="$(lang_pick "先完成一次本地恢复演练，再决定是否进入远端路径" "Complete one local restore rehearsal first, then decide whether to move to the remote path")"
    fi
  fi

  echo -e "${_CLR_BOLD}$(lang_pick "机器画像" "Machine profile"):${_CLR_NC}"
  echo "  $(lang_pick "判断结果" "Classification"): ${profile}"
  echo

  echo -e "${_CLR_BOLD}$(lang_pick "发现的业务形态" "Detected workload shape"):${_CLR_NC}"
  echo "  $(lang_pick "Docker Compose 项目" "Docker Compose projects"): ${compose_count}"
  echo "  $(lang_pick "独立 Docker 容器" "Standalone Docker containers"): ${standalone_count}"
  echo "  $(lang_pick "自定义 Systemd 服务" "Custom Systemd services"): ${systemd_count}"
  echo "  $(lang_pick "反向代理" "Reverse proxy"): ${reverse_proxy}"
  if [[ -n "${db_list}" ]]; then
    echo "  $(lang_pick "数据库" "Databases"): ${db_list}"
  else
    echo "  $(lang_pick "数据库" "Databases"): $(lang_pick "未发现" "none detected")"
  fi
  echo "  $(lang_pick "用户目录候选" "User home candidates"): ${user_home_count}"
  echo

  echo -e "${_CLR_BOLD}$(lang_pick "依赖与远端条件" "Dependencies and remote readiness"):${_CLR_NC}"
  if (( has_docker == 1 )); then
    echo -e "  ${_CLR_GREEN}✓${_CLR_NC} Docker"
  else
    echo -e "  ${_CLR_DIM}✗ Docker${_CLR_NC}"
  fi
  if (( has_docker_compose == 1 )); then
    echo -e "  ${_CLR_GREEN}✓${_CLR_NC} Docker Compose"
  else
    echo -e "  ${_CLR_DIM}✗ Docker Compose${_CLR_NC}"
  fi
  if (( has_rclone == 1 )); then
    echo -e "  ${_CLR_GREEN}✓${_CLR_NC} rclone (${remote_count} $(lang_pick "个 remote" "remotes"))"
  else
    echo -e "  ${_CLR_DIM}✗ rclone${_CLR_NC}"
  fi
  if (( has_oci_config == 1 )); then
    echo -e "  ${_CLR_GREEN}✓${_CLR_NC} $(lang_pick "OCI 凭据" "OCI credentials")"
  else
    echo -e "  ${_CLR_DIM}✗ $(lang_pick "OCI 凭据" "OCI credentials")${_CLR_NC}"
  fi
  echo

  echo -e "${_CLR_BOLD}$(lang_pick "恢复前风险评估" "Pre-restore risk assessment"):${_CLR_NC}"
  echo "  $(lang_pick "当前建议" "Current recommendation"): ${recommendation}"
  echo "  $(lang_pick "风险等级" "Risk level"): $(_doctor_risk_label "${risk_score}")"
  echo "  $(lang_pick "阻塞项" "Blocking items"):"
  if (( ${#blocking_items[@]} == 0 )); then
    echo "    $(lang_pick "无" "none")"
  else
    local blocking_item=""
    for blocking_item in "${blocking_items[@]}"; do
      echo "    - ${blocking_item}"
    done
  fi
  echo "  $(lang_pick "注意项" "Caution items"):"
  if (( ${#caution_items[@]} == 0 )); then
    echo "    $(lang_pick "无明显额外风险" "no significant additional cautions")"
  else
    local caution_item=""
    for caution_item in "${caution_items[@]}"; do
      echo "    - ${caution_item}"
    done
  fi
  echo

  echo -e "${_CLR_BOLD}$(lang_pick "恢复等级建议" "Suggested recovery grades"):${_CLR_NC}"
  (( compose_count > 0 )) && echo "  A  $(lang_pick "Docker Compose: 当前最成熟的自动恢复路径" "Docker Compose: currently the most mature auto-restore path")"
  [[ "${reverse_proxy}" != "$(lang_pick "未发现" "none detected")" ]] && echo "  A  $(lang_pick "反向代理: 标准 Caddy/Nginx/Apache 配置恢复较成熟" "Reverse proxy: standard Caddy/Nginx/Apache recovery is mature")"
  echo "  A  $(lang_pick "Crontab / 防火墙: 常规场景可自动恢复" "Crontab / firewall: common cases can be restored automatically")"
  (( systemd_count > 0 )) && echo "  B  $(lang_pick "Systemd: 常见服务可恢复，但需要人工确认业务行为" "Systemd: common services can be restored, but business behavior still needs confirmation")"
  (( has_db == 1 )) && echo "  B  $(lang_pick "数据库: 可恢复导出与文件，但不承诺业务一致性" "Databases: dumps and files can be restored, but business consistency is not guaranteed")"
  (( standalone_count > 0 )) && echo "  C  $(lang_pick "独立容器: 建议视为重建线索，不承诺自动拉起" "Standalone containers: treat them as rebuild hints rather than guaranteed auto-start")"
  echo "  C  $(lang_pick "业务副作用回滚: 当前不承诺自动处理" "Business-side rollback effects are not automatically handled")"
  echo

  echo -e "${_CLR_BOLD}$(lang_pick "建议起步路径" "Recommended adoption path"):${_CLR_NC}"
  if (( has_explicit_remote_config == 1 )); then
    echo "  1. $(lang_pick "已检测到远端恢复配置，无需重新执行 init" "Remote restore configuration is already present. You do not need to run init again")"
    if ! command -v rclone >/dev/null 2>&1; then
      echo "  2. $(lang_pick "先安装 rclone，再导入 rclone.conf 或执行 rclone config" "Install rclone first, then import rclone.conf or run rclone config")"
    elif (( remote_count == 0 )); then
      echo "  2. $(lang_pick "rclone 已安装，但还没有可用 remote；请导入 rclone.conf 或执行 rclone config" "rclone is installed, but no remotes are available yet; import rclone.conf or run rclone config")"
    else
      echo "  2. $(lang_pick "先执行一次远端恢复前置检查，再决定走主远端还是备用远端" "Run one remote restore preflight first, then decide whether to use the primary or fallback remote")"
    fi
    if (( requires_oci_credentials == 1 )) && [[ ! -f /root/.oci/config ]]; then
      echo "  3. $(lang_pick "如需使用 OCI 主目标，还需准备 /root/.oci/config；否则可回退到其他已配置远端或 restore --local" "If you want to use the OCI primary target, also prepare /root/.oci/config; otherwise use another configured remote or restore --local")"
      echo "  4. $(lang_pick "正式切换前，仍建议先完成一次本地恢复演练" "Before real cutover, still complete one local restore rehearsal")"
    else
      echo "  3. $(lang_pick "正式切换前，仍建议先完成一次本地恢复演练" "Before real cutover, still complete one local restore rehearsal")"
    fi
  elif (( remote_count == 0 )); then
    echo "  1. $(lang_pick "先执行本地模式初始化: vpsmagic init" "Start with local-only init: vpsmagic init")"
    echo "  2. $(lang_pick "先跑通本地备份 + 本地恢复演练" "First complete local backup + local restore rehearsal")"
    echo "  3. $(lang_pick "后续再安装 rclone 并配置远端" "Install rclone and configure remote storage later")"
  else
    echo "  1. $(lang_pick "仍建议先跑通本地备份 + 本地恢复演练" "Still start with local backup + local restore rehearsal")"
    echo "  2. $(lang_pick "确认摘要与健康检查合理后，再测试远端备份/恢复" "After summary and health checks look right, test remote backup/restore")"
  fi
  if (( standalone_count > 0 || has_db == 1 )); then
    echo "  4. $(lang_pick "这台机器不是最简单画像，正式上线前必须做恢复演练" "This VPS is not a simple profile; do a restore rehearsal before production use")"
  fi
  echo
  echo "  $(lang_pick "进一步阅读" "Further reading"): [$(lang_pick "业务画像与适用场景" "Workload profiles and suitability")](${SCRIPT_DIR}/docs/$(lang_pick "zh/业务画像与适用场景.md" "en/workload-profiles-and-suitability.md"))"
  echo
}

# ---------- 交互式初始化 ----------
_init_choose_language() {
  if [[ -n "${CLI_UI_LANG:-}" ]]; then
    set_ui_language "${CLI_UI_LANG}"
    return 0
  fi

  local current_default
  current_default="$(normalize_ui_lang "${UI_LANG:-}")"
  local default_choice="1"
  [[ "${current_default}" == "en" ]] && default_choice="2"

  echo
  echo "Choose interface language / 选择界面语言"
  echo "  1) 中文"
  echo "  2) English"
  echo

  local lang_selection=""
  read -r -p "Select language / 请选择语言 [default: ${default_choice}]: " lang_selection
  lang_selection="${lang_selection:-${default_choice}}"

  case "${lang_selection}" in
    2|en|EN|english|English)
      set_ui_language "en"
      ;;
    *)
      set_ui_language "zh"
      ;;
  esac
}

run_init() {
  _init_choose_language
  log_banner "$(lang_pick "VPS Magic Backup — 初始化配置" "VPS Magic Backup — Initialize Config")"

  local target_config="${VPSMAGIC_HOME}/config.env"
  local init_mode="local"
  local backup_destination="local"
  local default_config_dir="${VPSMAGIC_HOME}"

  if [[ ! -d "${default_config_dir}" ]]; then
    default_config_dir="$(dirname "${default_config_dir}")"
  fi
  if [[ ! -w "${default_config_dir}" ]]; then
    target_config="${PWD}/config.env"
  fi

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
  echo -e "${_CLR_BOLD}$(lang_pick "第1步: 选择使用模式" "Step 1: Choose a usage mode")${_CLR_NC}"
  echo "  1) $(lang_pick "仅本地备份（推荐新手）" "Local backups only (recommended for first-time users)")"
  echo "  2) $(lang_pick "本地 + 云端备份" "Local + remote backups")"
  echo "  3) $(lang_pick "仅生成配置，稍后再完善" "Generate a config only and refine it later")"
  echo

  local mode_selection=""
  read -r -p "$(lang_pick "请选择模式编号" "Select a mode") [$(prompt_default_label): 1]: " mode_selection
  mode_selection="${mode_selection:-1}"
  case "${mode_selection}" in
    2)
      init_mode="remote"
      backup_destination="remote"
      ;;
    3)
      init_mode="config_only"
      backup_destination="local"
      ;;
    *)
      init_mode="local"
      backup_destination="local"
      ;;
  esac

  local backup_targets=""
  local backup_primary_target=""
  local backup_async_target=""
  local backup_interactive_targets="true"
  local remote_mode="manual"
  local detected_host
  detected_host="$(hostname 2>/dev/null || echo 'vps')"
  local -a configured_targets=()

  if [[ "${init_mode}" == "remote" ]]; then
    echo
    echo -e "${_CLR_BOLD}$(lang_pick "第2步: 远端存储配置" "Step 2: Remote storage")${_CLR_NC}"
    echo "  $(lang_pick "VPS Magic 使用 rclone 将备份推送到远端存储。" "VPS Magic uses rclone to push backups to remote storage.")"
    echo "  $(lang_pick "支持: WebDAV (OpenList/AList)、Google Drive、OneDrive、S3 等" "Supported: WebDAV (OpenList/AList), Google Drive, OneDrive, S3, and more")"
    echo

    if command -v rclone >/dev/null 2>&1; then
      log_info "$(lang_pick "检测到 rclone，列出已配置的 remote:" "rclone detected. Listing configured remotes:")"
      rclone listremotes 2>/dev/null | while read -r r; do
        echo "    ${r}"
      done
      echo
    else
      log_warn "$(lang_pick "rclone 未安装。你仍可先生成远端配置，但首次远端备份前需要先安装并配置 rclone。" "rclone is not installed. You can still generate a remote config now, but you must install and configure rclone before the first remote backup.")"
      echo "  $(lang_pick "安装方法: curl https://rclone.org/install.sh | sudo bash" "Install with: curl https://rclone.org/install.sh | sudo bash")"
      echo "  $(lang_pick "安装后运行: rclone config" "Then run: rclone config")"
      echo
    fi

    echo "  $(lang_pick "请选择你想使用的远端类型:" "Choose the remote type you want to use:")"
    echo "    1. $(lang_pick "WebDAV / OpenList / AList" "WebDAV / OpenList / AList")"
    echo "    2. $(lang_pick "S3 兼容对象存储" "S3-compatible object storage")"
    echo "    3. $(lang_pick "Google Drive / OneDrive" "Google Drive / OneDrive")"
    echo "    4. $(lang_pick "我已经有完整 rclone 路径，直接输入" "I already have a full rclone target path")"
    echo
    local remote_selection=""
    read -r -p "$(lang_pick "请选择远端类型编号" "Select the remote type") [$(prompt_default_label): 4]: " remote_selection
    remote_selection="${remote_selection:-4}"
    case "${remote_selection}" in
      1) remote_mode="webdav" ;;
      2) remote_mode="s3" ;;
      3) remote_mode="drive" ;;
      *) remote_mode="manual" ;;
    esac

    case "${remote_mode}" in
      webdav)
        echo
        echo "  $(lang_pick "示例格式:" "Example format:") openlist_webdav:backup/{hostname}"
        echo "  $(lang_pick "如果你只有一个 WebDAV/OpenList remote，可以先只填一个完整路径。" "If you only have one WebDAV/OpenList remote, start with a single full path.")"
        read_with_default backup_targets "$(lang_pick "请输入 WebDAV/OpenList 备份目标" "Enter the WebDAV/OpenList backup target")" "openlist_webdav:backup/{hostname}"
        ;;
      s3)
        echo
        echo "  $(lang_pick "示例格式:" "Example format:") s3:mybucket/vpsmagic/{hostname}"
        echo "  $(lang_pick "如果你使用 OCI / R2，也属于这一类，只是 remote 名称不同。" "OCI and R2 also belong to this category; only the remote name differs.")"
        read_with_default backup_targets "$(lang_pick "请输入 S3 兼容备份目标" "Enter the S3-compatible backup target")" "s3:mybucket/vpsmagic/{hostname}"
        ;;
      drive)
        echo
        echo "  $(lang_pick "示例格式:" "Example format:") gdrive:VPSMagicBackup/{hostname}"
        echo "  $(lang_pick "如果你用 OneDrive，也可以填 onedrive:VPSMagicBackup/{hostname}" "If you use OneDrive, you can also use onedrive:VPSMagicBackup/{hostname}")"
        read_with_default backup_targets "$(lang_pick "请输入网盘备份目标" "Enter the cloud drive backup target")" "gdrive:VPSMagicBackup/{hostname}"
        ;;
      manual)
        echo
        echo "  $(lang_pick "支持 {hostname} 占位符，例如 OOS:mybucket/vpsmagic/{hostname}" "The {hostname} placeholder is supported, for example OOS:mybucket/vpsmagic/{hostname}")"
        echo "  $(lang_pick "也可以输入多个完整路径，逗号分隔，按顺序尝试。" "You can also enter multiple full paths separated by commas.")"
        read_with_default backup_targets "$(lang_pick "请输入备份目标列表" "Enter backup targets")" ""
        ;;
    esac

    if [[ -n "${backup_targets}" ]]; then
      parse_list "${backup_targets}" configured_targets
    fi
    if (( ${#configured_targets[@]} > 0 )); then
      read_with_default backup_primary_target "$(lang_pick "默认主目标 (备份/恢复交互默认项)" "Default primary target (default selection for backup/restore)")" "${configured_targets[0]}"
      if (( ${#configured_targets[@]} > 1 )); then
        read_with_default backup_async_target "$(lang_pick "异步副本目标 (可留空)" "Async replica target (optional)")" "${configured_targets[1]}"
      else
        read_with_default backup_async_target "$(lang_pick "异步副本目标 (可留空)" "Async replica target (optional)")" ""
      fi
    else
      read_with_default backup_primary_target "$(lang_pick "默认主目标 (可留空)" "Default primary target (optional)")" ""
      read_with_default backup_async_target "$(lang_pick "异步副本目标 (可留空)" "Async replica target (optional)")" ""
    fi
    if ! confirm "$(lang_pick "备份 / 恢复时是否先交互列出远端路径？" "List remote targets interactively before backup / restore?")" "y"; then
      backup_interactive_targets="false"
    fi
  else
    echo
    if [[ "${init_mode}" == "local" ]]; then
      log_info "$(lang_pick "已选择仅本地备份模式。当前不会要求 rclone 或远端存储。" "Local-only mode selected. rclone and remote storage are not required right now.")"
    else
      log_info "$(lang_pick "已选择仅生成配置。默认会生成一份安全的本地模式配置，你可以稍后再补远端。" "Config-only mode selected. A safe local-mode config will be generated and you can add remote settings later.")"
    fi
  fi

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "第3步: 备份存储" "Step 3: Backup storage")${_CLR_NC}"
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
  echo -e "${_CLR_BOLD}$(lang_pick "第4步: 选择备份模块" "Step 4: Select backup modules")${_CLR_NC}"
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

  local config_content=""
  config_content="$(cat <<EOF
# ============================================
# VPS Magic Backup config
# Generated at: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================

UI_LANG="${UI_LANG:-zh}"

# ---------- Remote storage ----------
BACKUP_TARGETS="${backup_targets}"
BACKUP_PRIMARY_TARGET="${backup_primary_target}"
BACKUP_ASYNC_TARGET="${backup_async_target}"
BACKUP_INTERACTIVE_TARGETS="${backup_interactive_targets}"
RCLONE_REMOTE=""
# RCLONE_CONF=""
# RCLONE_BW_LIMIT=""
RESTORE_ROLLBACK_ON_FAILURE=false
RESTORE_SOURCE_HOSTNAME=""

# ---------- Backup storage ----------
BACKUP_ROOT="${backup_root}"
BACKUP_KEEP_LOCAL=${keep_local}
BACKUP_KEEP_REMOTE=${keep_remote}
BACKUP_PREFIX="vpsmagic"
BACKUP_DESTINATION="${backup_destination}"
# BACKUP_REMOTE_OVERRIDE=""

# ---------- Encryption (optional) ----------
# BACKUP_ENCRYPTION_KEY=""

EOF
)"
  config_content+=$'\n\n# ---------- Backup modules ----------\n'

  local entry key label enabled
  for entry in "${module_flags[@]}"; do
    key="${entry%%:*}"
    label="${entry#*:}"
    enabled="true"
    if ! confirm "$(lang_pick "  启用" "  Enable") ${label}?" "y"; then
      enabled="false"
    fi
    config_content+="${key}=${enabled}"$'\n'
  done

  config_content+="$(cat <<'EOF'
# ---------- Module options ----------
COMPOSE_PROJECTS=auto
SYSTEMD_SERVICES=auto
BACKUP_USERS="root"
# EXTRA_PATHS="/opt/mydata, /srv/configs"

# ---------- Databases ----------
# DB_MYSQL_CONTAINERS=""
# DB_MYSQL_HOST_USER=""
# DB_MYSQL_HOST_PASS=""
# DB_POSTGRES_CONTAINERS=""
# DB_SQLITE_PATHS=""

# ---------- Notifications ----------
NOTIFY_ENABLED=false
# TG_BOT_TOKEN=""
# TG_CHAT_ID=""

# ---------- Logging ----------
LOG_FILE="/var/log/vpsmagic.log"

# ---------- Schedule ----------
SCHEDULE_CRON="0 3 * * *"
EOF
)"

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "第5步: 通知配置 (可选)" "Step 5: Notifications (optional)")${_CLR_NC}"
  if confirm "$(lang_pick "是否启用 Telegram 通知？" "Enable Telegram notifications?")" "n"; then
    local tg_token=""
    local tg_chat=""
    read_with_default tg_token "Telegram Bot Token" ""
    read_with_default tg_chat "Telegram Chat ID" ""
    config_content="$(echo "${config_content}" | sed 's/NOTIFY_ENABLED=false/NOTIFY_ENABLED=true/')"
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
  if [[ "${init_mode}" == "config_only" ]]; then
    echo "  2. $(lang_pick "先决定要走本地还是远端备份" "Decide whether you want local-only or remote backups first")"
    echo "  3. $(lang_pick "准备好后再执行备份" "Run backup when ready"): vpsmagic backup --config ${target_config}"
  else
    echo "  2. $(lang_pick "测试备份 (模拟)" "Test backup (dry-run)"):    vpsmagic backup --dry-run --config ${target_config}"
    echo "  3. $(lang_pick "执行真实备份" "Run a real backup"):        vpsmagic backup --config ${target_config}"
  fi
  if [[ "${init_mode}" != "remote" ]]; then
    echo "  4. $(lang_pick "以后如需异地备份，再配置 rclone 和远端目标" "Configure rclone and remote targets later if you want off-site backups")"
  else
    echo "  4. $(lang_pick "安装定时备份" "Install schedule"):        vpsmagic schedule install"
  fi
  echo
}

# ---------- 参数解析 ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      backup|upload|restore|schedule|status|doctor|init|help|migrate)
        SUBCOMMAND="$1"
        shift
        # 收集子命令参数
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry-run)  DRY_RUN=1; shift ;;
            --verbose)  VERBOSE=1; shift ;;
            --config)
              [[ $# -ge 2 ]] || { log_error "$(lang_pick "--config 需要一个参数" "--config requires an argument")"; exit 1; }
              CONFIG_FILE="$2"; shift 2 ;;
            --dest)
              [[ $# -ge 2 ]] || { log_error "$(lang_pick "--dest 需要一个参数" "--dest requires an argument")"; exit 1; }
              CLI_BACKUP_DESTINATION="$2"; shift 2 ;;
            --remote)
              [[ $# -ge 2 ]] || { log_error "$(lang_pick "--remote 需要一个参数" "--remote requires an argument")"; exit 1; }
              CLI_BACKUP_REMOTE_OVERRIDE="$2"; shift 2 ;;
            --lang)
              [[ $# -ge 2 ]] || { log_error "$(lang_pick "--lang 需要一个参数" "--lang requires an argument")"; exit 1; }
              CLI_UI_LANG="$2"; set_ui_language "$2"; shift 2 ;;
            --local)
              # restore --local <path>
              [[ $# -ge 2 ]] || { log_error "$(lang_pick "--local 需要指定备份文件路径" "--local requires a backup file path")"; exit 1; }
              RESTORE_LOCAL_FILE="$2"; shift 2 ;;
            --auto-confirm)
              RESTORE_AUTO_CONFIRM=1; shift ;;
            --rollback-on-failure)
              CLI_RESTORE_ROLLBACK_ON_FAILURE=true; shift ;;
            --source-hostname)
              [[ $# -ge 2 ]] || { log_error "$(lang_pick "--source-hostname 需要一个参数" "--source-hostname requires an argument")"; exit 1; }
              CLI_RESTORE_SOURCE_HOSTNAME="$2"; shift 2 ;;
            *)
              SUBCMD_ARGS+=("$1"); shift ;;
          esac
        done
        ;;
      --dry-run)  DRY_RUN=1; shift ;;
      --verbose)  VERBOSE=1; shift ;;
      --config)
        [[ $# -ge 2 ]] || { log_error "$(lang_pick "--config 需要一个参数" "--config requires an argument")"; exit 1; }
        CONFIG_FILE="$2"; shift 2 ;;
      --dest)
        [[ $# -ge 2 ]] || { log_error "$(lang_pick "--dest 需要一个参数" "--dest requires an argument")"; exit 1; }
        CLI_BACKUP_DESTINATION="$2"; shift 2 ;;
      --remote)
        [[ $# -ge 2 ]] || { log_error "$(lang_pick "--remote 需要一个参数" "--remote requires an argument")"; exit 1; }
        CLI_BACKUP_REMOTE_OVERRIDE="$2"; shift 2 ;;
      --lang)
        [[ $# -ge 2 ]] || { log_error "$(lang_pick "--lang 需要一个参数" "--lang requires an argument")"; exit 1; }
        CLI_UI_LANG="$2"; set_ui_language "$2"; shift 2 ;;
      --version|-v)
        SHOW_VERSION_ONLY=1; shift ;;
      --help|-h)
        SHOW_HELP_ONLY=1; shift ;;
      --source-hostname)
        [[ $# -ge 2 ]] || { log_error "$(lang_pick "--source-hostname 需要一个参数" "--source-hostname requires an argument")"; exit 1; }
        CLI_RESTORE_SOURCE_HOSTNAME="$2"; shift 2 ;;
      *)
        log_error "$(lang_pick "未知参数" "Unknown argument"): $1"
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
    doctor)
      load_config "${CONFIG_FILE}"
      set_ui_language "${CLI_UI_LANG:-${UI_LANG:-}}"
      if [[ -n "${CLI_UI_LANG}" ]]; then
        UI_LANG="${CLI_UI_LANG}"
        set_ui_language "${UI_LANG}"
      fi
      run_doctor
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
  if [[ -n "${CLI_RESTORE_ROLLBACK_ON_FAILURE}" ]]; then
    RESTORE_ROLLBACK_ON_FAILURE="${CLI_RESTORE_ROLLBACK_ON_FAILURE}"
  fi
  if [[ -n "${CLI_RESTORE_SOURCE_HOSTNAME}" ]]; then
    RESTORE_SOURCE_HOSTNAME="${CLI_RESTORE_SOURCE_HOSTNAME}"
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
    doctor)
      run_doctor
      ;;
    *)
      log_error "$(lang_pick "未知命令" "Unknown command"): ${SUBCOMMAND}"
      show_help
      exit 1
      ;;
  esac
}

# ---------- 执行 ----------
main "$@"
