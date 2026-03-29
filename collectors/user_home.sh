#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 用户目录
# ============================================================

[[ -n "${_COLLECTOR_USER_HOME_LOADED:-}" ]] && return 0
_COLLECTOR_USER_HOME_LOADED=1

collect_user_home() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/user_home"

  log_step "$(lang_pick "采集用户目录..." "Collecting user home directories...")"

  local -a users=()
  parse_list "${BACKUP_USERS:-root}" users

  if [[ ${#users[@]} -eq 0 ]]; then
    log_info "$(lang_pick "未配置需要备份的用户。" "No users configured for backup.")"
    summary_add "skip" "用户目录" "未配置"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0
  local en_user_label="users"

  for username in "${users[@]}"; do
    local home_dir=""

    # 获取用户 home 目录
    if [[ "${username}" == "root" ]]; then
      home_dir="/root"
    else
      home_dir="$(getent passwd "${username}" 2>/dev/null | cut -d: -f6)"
    fi

    if [[ -z "${home_dir}" || ! -d "${home_dir}" ]]; then
      log_warn "  $(lang_pick "用户" "User") ${username} $(lang_pick "的 home 目录不存在" "home directory does not exist"): ${home_dir:-unknown}"
      continue
    fi

    log_info "  $(lang_pick "备份用户目录" "Backing up user home"): ${username} (${home_dir})"

    if log_dry_run "$(lang_pick "备份用户目录: ${home_dir}" "Back up user home: ${home_dir}")"; then
      ((count+=1))
      continue
    fi

    local user_dir="${target_dir}/${username}"
    safe_mkdir "${user_dir}"

    # 备份配置文件（dotfiles）
    local dotfiles=(
      ".bashrc" ".bash_profile" ".bash_aliases" ".profile"
      ".zshrc" ".zprofile"
      ".vimrc" ".tmux.conf"
      ".ssh/authorized_keys" ".ssh/config"
      ".gitconfig"
      ".env" ".local/share/env"
    )

    for df in "${dotfiles[@]}"; do
      local src="${home_dir}/${df}"
      if [[ -f "${src}" ]]; then
        local df_dir
        df_dir="$(dirname "${user_dir}/${df}")"
        safe_mkdir "${df_dir}"
        safe_copy "${src}" "${user_dir}/${df}"
      fi
    done

    # 备份 .config 目录下的关键配置
    local config_dirs=(
      "rclone"
      "systemd/user"
    )
    for cdir in "${config_dirs[@]}"; do
      local src="${home_dir}/.config/${cdir}"
      if [[ -d "${src}" ]]; then
        local dst="${user_dir}/.config/${cdir}"
        safe_mkdir "$(dirname "${dst}")"
        safe_copy_dir "${src}" "${dst}"
      fi
    done

    # 备份用户的 cron（如果 crontab collector 未覆盖）
    if crontab -u "${username}" -l >/dev/null 2>&1; then
      crontab -u "${username}" -l > "${user_dir}/crontab.bak" 2>/dev/null || true
    fi

    # 记录用户信息
    {
      echo "USERNAME=${username}"
      echo "HOME=${home_dir}"
      echo "SHELL=$(getent passwd "${username}" 2>/dev/null | cut -d: -f7 || echo "unknown")"
      echo "GROUPS=$(id -Gn "${username}" 2>/dev/null || echo "unknown")"
    } > "${user_dir}/user_info.env"

    ((count+=1))
  done

  if (( count > 0 )); then
    (( count == 1 )) && en_user_label="user"
    log_success "$(lang_pick "用户目录: 已备份 ${count} 个用户" "User homes: backed up ${count} ${en_user_label}")"
    summary_add "ok" "用户目录" "${count} 个用户"
  else
    summary_add "skip" "用户目录" "未找到有效用户"
  fi
}
