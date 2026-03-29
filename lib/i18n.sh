#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 轻量语言切换
# ============================================================

[[ -n "${_VPSMAGIC_I18N_LOADED:-}" ]] && return 0
_VPSMAGIC_I18N_LOADED=1

UI_LANG="${UI_LANG:-}"

normalize_ui_lang() {
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="${raw%%.*}"
  raw="${raw%%_*}"
  raw="${raw%%-*}"
  case "${raw}" in
    en) echo "en" ;;
    zh|cn) echo "zh" ;;
    *) echo "zh" ;;
  esac
}

set_ui_language() {
  local requested="${1:-${UI_LANG:-${VPSMAGIC_LANG:-${LANG:-zh}}}}"
  UI_LANG="$(normalize_ui_lang "${requested}")"
}

is_lang_en() {
  [[ "${UI_LANG:-zh}" == "en" ]]
}

lang_pick() {
  local zh_text="${1:-}"
  local en_text="${2:-}"
  if is_lang_en; then
    printf '%s' "${en_text}"
  else
    printf '%s' "${zh_text}"
  fi
}

prompt_default_label() {
  lang_pick "默认" "default"
}

bool_label() {
  local value="${1:-}"
  case "${value}" in
    true|1|yes|enabled)
      lang_pick "已启用" "enabled"
      ;;
    false|0|no|disabled)
      lang_pick "未启用" "disabled"
      ;;
    *)
      printf '%s' "${value}"
      ;;
  esac
}

install_status_label() {
  local value="${1:-0}"
  if [[ "${value}" == "1" || "${value}" == "true" ]]; then
    lang_pick "已安装" "installed"
  else
    lang_pick "未安装" "not installed"
  fi
}

module_display_name() {
  case "${1:-}" in
    DOCKER_COMPOSE) lang_pick "Docker Compose 项目" "Docker Compose projects" ;;
    DOCKER_STANDALONE) lang_pick "独立 Docker 容器" "Standalone Docker containers" ;;
    SYSTEMD) lang_pick "Systemd 服务" "Systemd services" ;;
    REVERSE_PROXY) lang_pick "反向代理配置" "Reverse proxy configs" ;;
    DATABASE) lang_pick "数据库" "Databases" ;;
    SSL_CERTS) lang_pick "SSL 证书" "SSL certificates" ;;
    CRONTAB) lang_pick "Crontab 定时任务" "Crontab jobs" ;;
    FIREWALL) lang_pick "防火墙规则" "Firewall rules" ;;
    USER_HOME) lang_pick "用户目录" "User home directories" ;;
    CUSTOM_PATHS) lang_pick "自定义路径" "Custom paths" ;;
    *)
      printf '%s' "${1:-}"
      ;;
  esac
}

summary_module_name() {
  case "${1:-}" in
    "MySQL") lang_pick "MySQL" "MySQL" ;;
    "PostgreSQL") lang_pick "PostgreSQL" "PostgreSQL" ;;
    "SQLite") lang_pick "SQLite" "SQLite" ;;
    "数据库") lang_pick "数据库" "Databases" ;;
    "用户目录") lang_pick "用户目录" "User homes" ;;
    "防火墙") lang_pick "防火墙" "Firewall" ;;
    "反向代理") lang_pick "反向代理" "Reverse proxy" ;;
    "Docker Compose") lang_pick "Docker Compose" "Docker Compose" ;;
    "独立容器") lang_pick "独立容器" "Standalone containers" ;;
    "Systemd 服务") lang_pick "Systemd 服务" "Systemd services" ;;
    "SSL 证书") lang_pick "SSL 证书" "SSL certificates" ;;
    "Crontab") lang_pick "Crontab" "Crontab" ;;
    "自定义路径") lang_pick "自定义路径" "Custom paths" ;;
    "本地备份") lang_pick "本地备份" "Local backup" ;;
    "SSH 传输") lang_pick "SSH 传输" "SSH transfer" ;;
    "远端上传") lang_pick "远端上传" "Remote upload" ;;
    "打包") lang_pick "打包" "Packaging" ;;
    "恢复自定义路径") lang_pick "恢复自定义路径" "Restore custom paths" ;;
    "恢复数据库") lang_pick "恢复数据库" "Restore databases" ;;
    "恢复 Docker Compose") lang_pick "恢复 Docker Compose" "Restore Docker Compose" ;;
    "恢复独立容器") lang_pick "恢复独立容器" "Restore standalone containers" ;;
    "恢复 Systemd") lang_pick "恢复 Systemd" "Restore Systemd" ;;
    "恢复反向代理") lang_pick "恢复反向代理" "Restore reverse proxy" ;;
    "恢复 SSL") lang_pick "恢复 SSL" "Restore SSL" ;;
    "恢复 Crontab") lang_pick "恢复 Crontab" "Restore crontab" ;;
    "恢复防火墙") lang_pick "恢复防火墙" "Restore firewall" ;;
    "恢复用户目录") lang_pick "恢复用户目录" "Restore user homes" ;;
    "恢复 SSH 访问") lang_pick "恢复 SSH 访问" "Restore SSH access" ;;
    "恢复总体状态") lang_pick "恢复总体状态" "Restore overall status" ;;
    "恢复回滚") lang_pick "恢复回滚" "Restore rollback" ;;
    "健康检查 / Docker Compose") lang_pick "健康检查 / Docker Compose" "Health check / Docker Compose" ;;
    "健康检查 / Compose 端口") lang_pick "健康检查 / Compose 端口" "Health check / Compose ports" ;;
    "健康检查 / Compose 出网") lang_pick "健康检查 / Compose 出网" "Health check / Compose egress" ;;
    "健康检查 / Systemd") lang_pick "健康检查 / Systemd" "Health check / Systemd" ;;
    "健康检查 / 反向代理") lang_pick "健康检查 / 反向代理" "Health check / Reverse proxy" ;;
    "健康检查 / 代理端口") lang_pick "健康检查 / 代理端口" "Health check / Proxy ports" ;;
    "健康检查 / rclone") lang_pick "健康检查 / rclone" "Health check / rclone" ;;
    *)
      printf '%s' "${1:-}"
      ;;
  esac
}

summary_detail_text() {
  local detail="${1:-}"
  if ! is_lang_en; then
    printf '%s' "${detail}"
    return 0
  fi

  case "${detail}" in
    "未发现") printf '%s' "none found" ;;
    "未发现项目") printf '%s' "no projects found" ;;
    "未发现自定义服务") printf '%s' "no custom services found" ;;
    "无独立容器") printf '%s' "no standalone containers" ;;
    "未配置") printf '%s' "not configured" ;;
    "未找到有效用户") printf '%s' "no valid users found" ;;
    "已恢复") printf '%s' "restored" ;;
    "已处理") printf '%s' "processed" ;;
    "已备份") printf '%s' "backed up" ;;
    "配置已备份") printf '%s' "configuration backed up" ;;
    "规则已备份") printf '%s' "rules backed up" ;;
    "命令不可用") printf '%s' "command unavailable" ;;
    "systemctl 不可用") printf '%s' "systemctl unavailable" ;;
    "Docker 未安装") printf '%s' "Docker is not installed" ;;
    "dry-run") printf '%s' "dry-run" ;;
    "目标模式为 local") printf '%s' "destination mode is local" ;;
    *)
      if [[ "${detail}" =~ ^([0-9]+)[[:space:]]*项$ ]]; then
        printf '%s items' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个数据库$ ]]; then
        printf '%s databases' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个容器需手动重建$ ]]; then
        printf '%s containers require manual recreation' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个项目$ ]]; then
        printf '%s projects' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个用户$ ]]; then
        printf '%s users' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个服务$ ]]; then
        printf '%s services' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个容器$ ]]; then
        printf '%s containers' "${BASH_REMATCH[1]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个服务已恢复，([0-9]+)[[:space:]]*个待切换后启动$ ]]; then
        printf '%s services restored, %s pending manual start after cutover' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个服务已处理，([0-9]+)[[:space:]]*个需手动检查$ ]]; then
        printf '%s services processed, %s require manual review' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      elif [[ "${detail}" =~ ^([0-9]+)[[:space:]]*个服务已恢复$ ]]; then
        printf '%s services restored' "${BASH_REMATCH[1]}"
      else
        printf '%s' "${detail}"
      fi
      ;;
  esac
}
