#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: Systemd 服务
# 增强: 自动探测 Python venv, 导出 pip freeze, 备份环境变量
# ============================================================

[[ -n "${_COLLECTOR_SYSTEMD_LOADED:-}" ]] && return 0
_COLLECTOR_SYSTEMD_LOADED=1

_systemd_service_requires_manual_start() {
  local svc_name="$1"
  local svc_dir="$2"

  if [[ -f "${svc_dir}/requirements_freeze.txt" ]] && grep -qi '^python-telegram-bot==' "${svc_dir}/requirements_freeze.txt" 2>/dev/null; then
    return 0
  fi
  if [[ -f "${svc_dir}/requirements.txt" ]] && grep -qi '^python-telegram-bot==' "${svc_dir}/requirements.txt" 2>/dev/null; then
    return 0
  fi
  if [[ -f "${svc_dir}/_workdir_path.txt" ]] && grep -Eqi '/telegram[_-]?bot([/$]|$)' "${svc_dir}/_workdir_path.txt" 2>/dev/null; then
    return 0
  fi
  if [[ -f "${svc_dir}/_program_path.txt" ]] && grep -Eqi '/telegram[_-]?bot([/$]|$)' "${svc_dir}/_program_path.txt" 2>/dev/null; then
    return 0
  fi
  if [[ "${svc_name}" =~ (^|[-_])bot($|[-_]) ]] && [[ -f "${svc_dir}/requirements_freeze.txt" ]] && grep -qi '^python-telegram-bot==' "${svc_dir}/requirements_freeze.txt" 2>/dev/null; then
    return 0
  fi

  return 1
}

collect_systemd_services() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/systemd"

  if ! command -v systemctl >/dev/null 2>&1; then
    log_info "systemctl 未找到，跳过 Systemd 采集。"
    summary_add "skip" "Systemd 服务" "systemctl 不可用"
    return 0
  fi

  log_step "采集 Systemd 服务..."

  local -a services=()
  if [[ "${SYSTEMD_SERVICES}" == "auto" ]]; then
    log_info "自动探测用户自定义的 Systemd 服务..."
    while IFS= read -r svc_file; do
      local svc_name
      svc_name="$(basename "${svc_file}")"
      # 跳过系统默认服务
      if [[ "${svc_name}" =~ ^(dbus|ssh|sshd|rsyslog|cron|systemd-|getty|network|snap|cloud-|plymouth-|chrony|ufw) ]]; then
        continue
      fi
      services+=("${svc_name}")
    done < <(find /etc/systemd/system/ -maxdepth 1 -name "*.service" -type f 2>/dev/null)
  else
    parse_list "${SYSTEMD_SERVICES}" services
  fi

  if [[ ${#services[@]} -eq 0 ]]; then
    log_info "未发现自定义 Systemd 服务。"
    summary_add "skip" "Systemd 服务" "未发现自定义服务"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0

  for svc in "${services[@]}"; do
    local svc_name="${svc%.service}"
    [[ -z "${svc_name}" ]] && continue

    local svc_dir="${target_dir}/${svc_name}"
    safe_mkdir "${svc_dir}"

    log_info "  备份服务: ${svc_name}"

    if log_dry_run "备份 Systemd 服务: ${svc_name}"; then
      ((count+=1))
      continue
    fi

    # 复制 service 文件
    local svc_path="/etc/systemd/system/${svc_name}.service"
    [[ ! -f "${svc_path}" ]] && svc_path="/etc/systemd/system/${svc}"
    safe_copy "${svc_path}" "${svc_dir}/"

    # 也检查 override 目录
    local override_dir="/etc/systemd/system/${svc_name}.service.d"
    if [[ -d "${override_dir}" ]]; then
      safe_copy_dir "${override_dir}" "${svc_dir}/overrides"
    fi

    # 记录状态信息
    {
      echo "SERVICE_NAME=${svc_name}"
      echo "ENABLED=$(systemctl is-enabled "${svc_name}" 2>/dev/null || echo "unknown")"
      echo "ACTIVE=$(systemctl is-active "${svc_name}" 2>/dev/null || echo "unknown")"
    } > "${svc_dir}/status.env"

    # systemctl show 导出完整属性
    systemctl show "${svc_name}" > "${svc_dir}/properties.txt" 2>/dev/null || true

    # 提取 Environment 和 EnvironmentFile 配置
    local env_file
    env_file="$(systemctl show "${svc_name}" -p EnvironmentFiles --value 2>/dev/null || true)"
    if [[ -n "${env_file}" && "${env_file}" != "(null)" ]]; then
      local env_path
      env_path="$(echo "${env_file}" | awk '{print $1}')"
      if [[ -f "${env_path}" ]]; then
        safe_copy "${env_path}" "${svc_dir}/"
        log_debug "    备份环境文件: ${env_path}"
      fi
    fi

    # 提取 ExecStart 指向的程序路径
    local exec_start
    exec_start="$(systemctl show "${svc_name}" -p ExecStart --value 2>/dev/null || true)"
    local exec_path
    exec_path="$(echo "${exec_start}" | sed -n 's/.*path=\([^;[:space:]]*\).*/\1/p' | head -1)"
    if [[ -z "${exec_path}" ]]; then
      exec_path="$(echo "${exec_start}" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) {print $i; exit}}')"
    fi

    if [[ -n "${exec_path}" && "${exec_path}" == /* ]]; then
      local exec_dir
      exec_dir="$(dirname "${exec_path}")"
      # 仅备份非系统目录
      if [[ "${exec_dir}" != "/usr/bin" && "${exec_dir}" != "/usr/sbin" && "${exec_dir}" != "/bin" && "${exec_dir}" != "/sbin" ]]; then
        if [[ -d "${exec_dir}" ]]; then
          log_debug "    备份程序目录: ${exec_dir}"
          tar -czf "${svc_dir}/program.tar.gz" -C "$(dirname "${exec_dir}")" "$(basename "${exec_dir}")" 2>/dev/null || true
          echo "${exec_dir}" > "${svc_dir}/_program_path.txt"
        fi
      fi
    fi

    # 查找并备份关联的 WorkingDirectory
    local work_dir
    work_dir="$(systemctl show "${svc_name}" -p WorkingDirectory --value 2>/dev/null || true)"
    if [[ -n "${work_dir}" && "${work_dir}" == /* && -d "${work_dir}" ]]; then
      if [[ "${work_dir}" != "/" && "${work_dir}" != "${exec_dir:-}" ]]; then
        log_debug "    备份工作目录: ${work_dir}"

        # 智能备份：排除 .venv、node_modules 等大型依赖目录
        tar -czf "${svc_dir}/workdir.tar.gz" \
          --exclude='.venv' --exclude='venv' --exclude='__pycache__' \
          --exclude='node_modules' --exclude='.git' \
          -C "$(dirname "${work_dir}")" "$(basename "${work_dir}")" 2>/dev/null || true
        echo "${work_dir}" > "${svc_dir}/_workdir_path.txt"

        # ---- Python venv 探测 (如 downnow-bot.service 使用 .venv/bin/python) ----
        local venv_dir=""
        # 方法1: ExecStart 路径中包含 .venv 或 venv
        if [[ "${exec_path}" == */.venv/bin/* ]]; then
          venv_dir="${exec_path%%/.venv/bin/*}/.venv"
        elif [[ "${exec_path}" == */venv/bin/* ]]; then
          venv_dir="${exec_path%%/venv/bin/*}/venv"
        fi
        # 方法2: WorkingDirectory 下存在 .venv 或 venv
        if [[ -z "${venv_dir}" ]]; then
          for vd in "${work_dir}/.venv" "${work_dir}/venv"; do
            if [[ -d "${vd}" ]]; then
              venv_dir="${vd}"
              break
            fi
          done
        fi

        if [[ -n "${venv_dir}" && -d "${venv_dir}" ]]; then
          log_info "    探测到 Python venv: ${venv_dir}"

          # 导出 pip freeze (比备份整个 venv 更可靠且更小)
          if [[ -x "${venv_dir}/bin/pip" ]]; then
            "${venv_dir}/bin/pip" freeze > "${svc_dir}/requirements_freeze.txt" 2>/dev/null || true
            log_debug "    导出 pip freeze: $(wc -l < "${svc_dir}/requirements_freeze.txt" 2>/dev/null || echo 0) 个包"
          fi

          # 也备份原始 requirements.txt (如果存在)
          for req in requirements.txt requirements-dev.txt pyproject.toml setup.py setup.cfg; do
            safe_copy "${work_dir}/${req}" "${svc_dir}/" 2>/dev/null
          done

          # 记录 Python 版本
          if [[ -x "${venv_dir}/bin/python" ]]; then
            "${venv_dir}/bin/python" --version > "${svc_dir}/_python_version.txt" 2>/dev/null || true
          fi

          echo "${venv_dir}" > "${svc_dir}/_venv_path.txt"
          echo "HAS_VENV=true" >> "${svc_dir}/status.env"
        fi

        # ---- 备份 config.yaml / .env 等配置文件 ----
        for cfg in config.yaml config.yml config.json .env config.env config.toml; do
          safe_copy "${work_dir}/${cfg}" "${svc_dir}/" 2>/dev/null
        done
      fi
    fi

    if _systemd_service_requires_manual_start "${svc_name}" "${svc_dir}"; then
      echo "START_POLICY=manual" >> "${svc_dir}/status.env"
      echo "START_REASON=single-instance-bot" >> "${svc_dir}/status.env"
    fi

    ((count+=1))
  done

  log_success "Systemd 服务: 已备份 ${count} 个"
  summary_add "ok" "Systemd 服务" "${count} 个服务"
}
