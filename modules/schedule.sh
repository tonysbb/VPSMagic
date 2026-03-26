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
      log_error "$(lang_pick "未知调度操作" "Unknown schedule action"): ${action}"
      echo "$(lang_pick "用法" "Usage"): vpsmagic schedule [install|remove|status]"
      return 1
      ;;
  esac
}

_schedule_install() {
  log_step "$(lang_pick "安装定时备份任务..." "Installing scheduled backup job...")"

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
      log_error "$(lang_pick "找不到 vpsmagic.sh 脚本。" "Unable to find vpsmagic.sh.")"
      return 1
    fi
  fi

  echo
  echo -e "${_CLR_BOLD}$(lang_pick "配置定时备份" "Configure scheduled backup"):${_CLR_NC}"
  echo "  $(lang_pick "当前调度" "Current schedule"): ${cron_expr}"
  echo "  $(lang_pick "脚本路径" "Script path"): ${vpsmagic_path}"
  echo "  $(lang_pick "配置文件" "Config file"): ${config_path}"
  echo

  if ! confirm "$(lang_pick "是否使用以上配置安装定时任务？" "Install scheduled job with the configuration above?")" "y"; then
    read_with_default cron_expr "$(lang_pick "请输入 cron 表达式" "Enter cron expression")" "${cron_expr}"
  fi

  local escaped_vpsmagic_path
  local escaped_config_path
  printf -v escaped_vpsmagic_path '%q' "${vpsmagic_path}"
  printf -v escaped_config_path '%q' "${config_path}"

  local cron_cmd="${cron_expr} /usr/bin/env bash ${escaped_vpsmagic_path} backup --config ${escaped_config_path} >> /var/log/vpsmagic_cron.log 2>&1 ${CRON_MARKER}"

  if log_dry_run "安装 cron: ${cron_cmd}"; then return 0; fi

  # 检查是否已存在
  if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    log_info "$(lang_pick "检测到已有定时任务，将更新..." "Existing scheduled job detected. Updating...")"
    # 删除旧的
    ((crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}") || true) | crontab - 2>/dev/null
  fi

  # 添加新的
  (crontab -l 2>/dev/null; echo "${cron_cmd}") | crontab - 2>/dev/null || {
    log_error "$(lang_pick "安装 cron 任务失败!" "Failed to install cron job!")"
    return 1
  }

  log_success "$(lang_pick "定时备份任务已安装" "Scheduled backup job installed")"
  echo
  echo "  📅 $(lang_pick "调度" "Schedule"): ${cron_expr}"
  echo "  📋 $(lang_pick "日志" "Log"): /var/log/vpsmagic_cron.log"
  echo
  echo -e "${_CLR_DIM}$(lang_pick "提示: 使用 'vpsmagic schedule status' 查看状态" "Tip: use 'vpsmagic schedule status' to inspect the scheduler")${_CLR_NC}"
  echo -e "${_CLR_DIM}      $(lang_pick "使用 'vpsmagic schedule remove' 移除任务" "use 'vpsmagic schedule remove' to remove the job")${_CLR_NC}"
}

_schedule_remove() {
  log_step "$(lang_pick "移除定时备份任务..." "Removing scheduled backup job...")"

  if ! crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    log_info "$(lang_pick "未找到 VPSMagic 定时任务。" "No VPSMagic cron job found.")"
    return 0
  fi

  if log_dry_run "移除 cron 任务"; then return 0; fi

  ((crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}") || true) | crontab - 2>/dev/null || {
    log_error "$(lang_pick "移除 cron 任务失败!" "Failed to remove cron job!")"
    return 1
  }

  log_success "$(lang_pick "定时备份任务已移除" "Scheduled backup job removed")"
}

_schedule_status() {
  log_step "$(lang_pick "定时备份状态" "Scheduled backup status")"
  echo

  local has_cron=0
  if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    has_cron=1
    echo -e "  🟢 $(lang_pick "状态" "Status"): ${_CLR_GREEN}$(install_status_label 1)${_CLR_NC}"
    echo "  📅 $(lang_pick "规则" "Rules"):"
    crontab -l 2>/dev/null | grep -F "${CRON_MARKER}" | while read -r line; do
      # 提取 cron 表达式
      local expr
      expr="$(echo "${line}" | awk '{print $1, $2, $3, $4, $5}')"
      echo "     ${expr}"
    done
  else
    echo -e "  🔴 $(lang_pick "状态" "Status"): ${_CLR_RED}$(install_status_label 0)${_CLR_NC}"
    echo -e "  ${_CLR_DIM}$(lang_pick "使用 'vpsmagic schedule install' 安装" "Use 'vpsmagic schedule install' to install it")${_CLR_NC}"
  fi

  echo

  # 显示最近的备份记录
  local log_file="/var/log/vpsmagic_cron.log"
  if [[ -f "${log_file}" ]]; then
    echo "  📋 $(lang_pick "最近执行日志 (最后 5 行)" "Recent execution log (last 5 lines)"):"
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
    echo "  📦 $(lang_pick "本地备份" "Local backups"): ${count} $(lang_pick "份" "copies") (${total_size})"
    if (( count > 0 )); then
      echo "     $(lang_pick "最新" "Latest"):"
      list_archive_files_sorted "${archive_dir}" "" "desc" | head -3 | while read -r archive_path; do
        [[ -n "${archive_path}" ]] || continue
        echo "       $(basename "${archive_path}")"
      done
    fi
  fi
  echo
}
