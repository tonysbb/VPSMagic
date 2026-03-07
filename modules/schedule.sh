#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 调度模块 (cron 管理)
# ============================================================

[[ -n "${_MODULE_SCHEDULE_LOADED:-}" ]] && return 0
_MODULE_SCHEDULE_LOADED=1

CRON_MARKER="# VPSMagicBackup auto-backup"

run_schedule() {
  local action="${1:-status}"

  case "${action}" in
    install)
      _schedule_install
      ;;
    remove)
      _schedule_remove
      ;;
    status)
      _schedule_status
      ;;
    *)
      log_error "未知调度操作: ${action}"
      echo "用法: vpsmagic schedule [install|remove|status]"
      return 1
      ;;
  esac
}

_schedule_install() {
  log_step "安装定时备份任务..."

  local cron_expr="${SCHEDULE_CRON:-0 3 * * *}"
  local vpsmagic_path="${VPSMAGIC_HOME}/vpsmagic.sh"
  local config_path="${_VPSMAGIC_CONFIG_FILE:-${VPSMAGIC_HOME}/config.env}"

  # 确保脚本路径有效
  if [[ ! -f "${vpsmagic_path}" ]]; then
    # 尝试查找当前脚本位置
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -f "${script_dir}/vpsmagic.sh" ]]; then
      vpsmagic_path="${script_dir}/vpsmagic.sh"
    else
      log_error "找不到 vpsmagic.sh 脚本。"
      return 1
    fi
  fi

  echo
  echo -e "${_CLR_BOLD}配置定时备份:${_CLR_NC}"
  echo "  当前调度: ${cron_expr}"
  echo "  脚本路径: ${vpsmagic_path}"
  echo "  配置文件: ${config_path}"
  echo

  if ! confirm "是否使用以上配置安装定时任务？" "y"; then
    read_with_default cron_expr "请输入 cron 表达式" "${cron_expr}"
  fi

  local escaped_vpsmagic_path
  local escaped_config_path
  printf -v escaped_vpsmagic_path '%q' "${vpsmagic_path}"
  printf -v escaped_config_path '%q' "${config_path}"

  local cron_cmd="${cron_expr} /usr/bin/env bash ${escaped_vpsmagic_path} backup --config ${escaped_config_path} >> /var/log/vpsmagic_cron.log 2>&1 ${CRON_MARKER}"

  if log_dry_run "安装 cron: ${cron_cmd}"; then return 0; fi

  # 检查是否已存在
  if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    log_info "检测到已有定时任务，将更新..."
    # 删除旧的
    (crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}") | crontab - 2>/dev/null
  fi

  # 添加新的
  (crontab -l 2>/dev/null; echo "${cron_cmd}") | crontab - 2>/dev/null || {
    log_error "安装 cron 任务失败!"
    return 1
  }

  log_success "定时备份任务已安装"
  echo
  echo "  📅 调度: ${cron_expr}"
  echo "  📋 日志: /var/log/vpsmagic_cron.log"
  echo
  echo -e "${_CLR_DIM}提示: 使用 'vpsmagic schedule status' 查看状态${_CLR_NC}"
  echo -e "${_CLR_DIM}      使用 'vpsmagic schedule remove' 移除任务${_CLR_NC}"
}

_schedule_remove() {
  log_step "移除定时备份任务..."

  if ! crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    log_info "未找到 VPSMagic 定时任务。"
    return 0
  fi

  if log_dry_run "移除 cron 任务"; then return 0; fi

  (crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}") | crontab - 2>/dev/null || {
    log_error "移除 cron 任务失败!"
    return 1
  }

  log_success "定时备份任务已移除"
}

_schedule_status() {
  log_step "定时备份状态"
  echo

  local has_cron=0
  if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    has_cron=1
    echo -e "  🟢 状态: ${_CLR_GREEN}已安装${_CLR_NC}"
    echo "  📅 规则:"
    crontab -l 2>/dev/null | grep -F "${CRON_MARKER}" | while read -r line; do
      # 提取 cron 表达式
      local expr
      expr="$(echo "${line}" | awk '{print $1, $2, $3, $4, $5}')"
      echo "     ${expr}"
    done
  else
    echo -e "  🔴 状态: ${_CLR_RED}未安装${_CLR_NC}"
    echo -e "  ${_CLR_DIM}使用 'vpsmagic schedule install' 安装${_CLR_NC}"
  fi

  echo

  # 显示最近的备份记录
  local log_file="/var/log/vpsmagic_cron.log"
  if [[ -f "${log_file}" ]]; then
    echo "  📋 最近执行日志 (最后 5 行):"
    tail -5 "${log_file}" | while read -r line; do
      echo "     ${line}"
    done
  fi

  # 本地备份情况
  local archive_dir="${BACKUP_ROOT}/archives"
  if [[ -d "${archive_dir}" ]]; then
    local count
    count="$(find "${archive_dir}" -maxdepth 1 -name "*.tar.gz*" ! -name "*.sha256" -type f 2>/dev/null | wc -l | tr -d ' ')"
    local total_size
    total_size="$(du -sh "${archive_dir}" 2>/dev/null | awk '{print $1}' || echo "0")"
    echo
    echo "  📦 本地备份: ${count} 份 (共 ${total_size})"
    if (( count > 0 )); then
      echo "     最新:"
      find "${archive_dir}" -maxdepth 1 -name "*.tar.gz*" ! -name "*.sha256" -type f -printf '%T@ %f\n' 2>/dev/null | \
        sort -rn | head -3 | while read -r _ name; do
          echo "       ${name}"
        done
    fi
  fi
  echo
}
