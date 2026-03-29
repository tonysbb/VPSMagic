#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: Crontab 定时任务
# ============================================================

[[ -n "${_COLLECTOR_CRONTAB_LOADED:-}" ]] && return 0
_COLLECTOR_CRONTAB_LOADED=1

collect_crontab() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/crontab"

  log_step "$(lang_pick "采集 Crontab 定时任务..." "Collecting Crontab jobs...")"

  if ! command -v crontab >/dev/null 2>&1; then
    log_info "$(lang_pick "crontab 命令不可用，跳过采集。" "crontab is unavailable. Skipping collection.")"
    summary_add "skip" "Crontab" "命令不可用"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local found=0

  if log_dry_run "$(lang_pick "备份 crontab" "Back up crontab")"; then return 0; fi

  # 导出当前用户的 crontab
  local current_user
  current_user="$(whoami)"
  if crontab -l >/dev/null 2>&1; then
    crontab -l > "${target_dir}/user_${current_user}.crontab" 2>/dev/null
    found=1
    log_info "  $(lang_pick "导出" "Exported") ${current_user} $(lang_pick "的 crontab" "crontab")"
  fi

  # 如果是 root，尝试导出其他用户
  if [[ "$(id -u)" -eq 0 ]]; then
    while IFS=: read -r username _ uid _ _ home _; do
      # 跳过系统用户，只关注 uid >= 1000 或 root
      if (( uid >= 1000 )) || [[ "${username}" == "root" ]]; then
        [[ "${username}" == "${current_user}" ]] && continue
        if crontab -u "${username}" -l >/dev/null 2>&1; then
          crontab -u "${username}" -l > "${target_dir}/user_${username}.crontab" 2>/dev/null
          found=1
          log_info "  $(lang_pick "导出" "Exported") ${username} $(lang_pick "的 crontab" "crontab")"
        fi
      fi
    done < /etc/passwd
  fi

  # 备份系统级 cron 目录
  local cron_dirs=(
    "/etc/crontab"
    "/etc/cron.d"
    "/etc/cron.daily"
    "/etc/cron.hourly"
    "/etc/cron.weekly"
    "/etc/cron.monthly"
  )

  for cpath in "${cron_dirs[@]}"; do
    if [[ -e "${cpath}" ]]; then
      if [[ -f "${cpath}" ]]; then
        safe_copy "${cpath}" "${target_dir}/"
        found=1
      elif [[ -d "${cpath}" ]] && [[ "$(ls -A "${cpath}" 2>/dev/null)" ]]; then
        local dir_name
        dir_name="$(basename "${cpath}")"
        tar -czf "${target_dir}/${dir_name}.tar.gz" -C "$(dirname "${cpath}")" "${dir_name}" 2>/dev/null || true
        found=1
      fi
    fi
  done

  # systemd timer 单元 (作为 cron 替代)
  if command -v systemctl >/dev/null 2>&1; then
    local timers
    timers="$(systemctl list-timers --no-pager --no-legend 2>/dev/null || true)"
    if [[ -n "${timers}" ]]; then
      echo "${timers}" > "${target_dir}/systemd_timers.txt"
      # 备份自定义 timer 文件
      while IFS= read -r timer_file; do
        safe_copy "${timer_file}" "${target_dir}/" 2>/dev/null
      done < <(find /etc/systemd/system/ -maxdepth 1 -name "*.timer" -type f 2>/dev/null)
      found=1
    fi
  fi

  if (( found == 0 )); then
    log_info "$(lang_pick "未发现定时任务。" "No scheduled jobs found.")"
    summary_add "skip" "Crontab" "未发现"
  else
    log_success "$(lang_pick "定时任务采集完成" "Scheduled job collection completed")"
    summary_add "ok" "Crontab" "已备份"
  fi
}
