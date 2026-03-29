#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: Docker Compose 项目
# ============================================================

[[ -n "${_COLLECTOR_DOCKER_COMPOSE_LOADED:-}" ]] && return 0
_COLLECTOR_DOCKER_COMPOSE_LOADED=1

collect_docker_compose() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/docker_compose"

  if ! command -v docker >/dev/null 2>&1; then
    log_info "$(lang_pick "Docker 未安装，跳过 Docker Compose 采集。" "Docker is not installed. Skipping Docker Compose collection.")"
    summary_add "skip" "Docker Compose" "Docker 未安装"
    return 0
  fi

  log_step "$(lang_pick "采集 Docker Compose 项目..." "Collecting Docker Compose projects...")"

  # 探测 Compose 项目
  local -a projects=()
  if [[ "${COMPOSE_PROJECTS}" == "auto" ]]; then
    log_info "$(lang_pick "自动探测 Docker Compose 项目..." "Auto-detecting Docker Compose projects...")"

    # 方法1: docker compose ls (优先运行中的项目，也兼容多项目 JSON 输出)
    local compose_ls_json=""
    compose_ls_json="$(docker compose ls --format json 2>/dev/null || true)"
    if [[ -n "${compose_ls_json}" ]]; then
      while IFS= read -r config_entry; do
        local config_files
        config_files="$(echo "${config_entry}" | sed 's/^"ConfigFiles":"//; s/"$//')"
        IFS=',' read -r -a _config_items <<< "${config_files}"
        local cfg_file=""
        for cfg_file in "${_config_items[@]}"; do
          cfg_file="$(echo "${cfg_file}" | xargs)"
          [[ -z "${cfg_file}" ]] && continue
          local proj_dir
          proj_dir="$(dirname "${cfg_file}")"
          if [[ -d "${proj_dir}" ]] && ! in_array "${proj_dir}" "${projects[@]}"; then
            projects+=("${proj_dir}")
          fi
        done
      done < <(printf '%s' "${compose_ls_json}" | grep -o '"ConfigFiles":"[^"]*"' || true)
    fi

    # 方法1.5: 从运行中容器的 compose labels 反查项目目录
    local container_id=""
    while IFS= read -r container_id; do
      [[ -n "${container_id}" ]] || continue
      local working_dir=""
      local config_files=""
      working_dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "${container_id}" 2>/dev/null || true)"
      config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "${container_id}" 2>/dev/null || true)"

      if [[ -n "${working_dir}" && -d "${working_dir}" ]] && ! in_array "${working_dir}" "${projects[@]}"; then
        projects+=("${working_dir}")
      fi

      if [[ -n "${config_files}" ]]; then
        IFS=',' read -r -a _config_items <<< "${config_files}"
        local cfg_file=""
        for cfg_file in "${_config_items[@]}"; do
          cfg_file="$(echo "${cfg_file}" | xargs)"
          [[ -z "${cfg_file}" ]] && continue
          local proj_dir=""
          proj_dir="$(dirname "${cfg_file}")"
          if [[ -d "${proj_dir}" ]] && ! in_array "${proj_dir}" "${projects[@]}"; then
            projects+=("${proj_dir}")
          fi
        done
      fi
    done < <(docker ps -q 2>/dev/null)

    # 方法2: 查找常见路径下的 compose 文件，补足未运行或 ls 未列出的项目
    local search_dirs=("/opt" "/srv" "/home" "/root" "/var/docker" "/app" "/apps" "/data" "/var/www" "/usr/local")
    local sdir=""
    for sdir in "${search_dirs[@]}"; do
      if [[ -d "${sdir}" ]]; then
        while IFS= read -r f; do
          local proj_d
          proj_d="$(dirname "${f}")"
          if ! in_array "${proj_d}" "${projects[@]}"; then
            projects+=("${proj_d}")
          fi
        done < <(find "${sdir}" -maxdepth 4 \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null)
      fi
    done
  else
    parse_list "${COMPOSE_PROJECTS}" projects
  fi

  if [[ ${#projects[@]} -eq 0 ]]; then
    log_info "$(lang_pick "未发现 Docker Compose 项目。" "No Docker Compose projects found.")"
    summary_add "skip" "Docker Compose" "未发现项目"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0
  local total_services=0

  for proj_path in "${projects[@]}"; do
    if [[ ! -d "${proj_path}" ]]; then
      log_warn "$(lang_pick "项目目录不存在" "Project directory does not exist"): ${proj_path}"
      continue
    fi

    local compose_project_name
    compose_project_name="$(basename "${proj_path}")"

    local backup_key="${compose_project_name}"
    local proj_backup="${target_dir}/${backup_key}"
    if [[ -d "${proj_backup}" ]]; then
      local suffix=""
      if command -v sha256sum >/dev/null 2>&1; then
        suffix="$(printf '%s' "${proj_path}" | sha256sum | awk '{print substr($1,1,8)}')"
      elif command -v shasum >/dev/null 2>&1; then
        suffix="$(printf '%s' "${proj_path}" | shasum -a 256 | awk '{print substr($1,1,8)}')"
      else
        suffix="$(date +%s)"
      fi
      backup_key="${compose_project_name}__${suffix}"
      proj_backup="${target_dir}/${backup_key}"
    fi
    safe_mkdir "${proj_backup}"

    if [[ "${backup_key}" == "${compose_project_name}" ]]; then
      log_info "  $(lang_pick "备份项目" "Backing up project"): ${compose_project_name} (${proj_path})"
    else
      log_info "  $(lang_pick "备份项目" "Backing up project"): ${compose_project_name} (${proj_path}) -> ${backup_key}"
    fi

    local project_services=0
    project_services="$(cd "${proj_path}" && docker compose config --services 2>/dev/null | awk 'NF {count+=1} END {print count+0}')"
    total_services=$(( total_services + project_services ))

    if log_dry_run "$(lang_pick "备份 Docker Compose 项目: ${proj_path}" "Back up Docker Compose project: ${proj_path}")"; then
      ((count+=1))
      continue
    fi

    # 记录原始 compose 项目名，恢复卷名前缀时使用
    echo "${compose_project_name}" > "${proj_backup}/_compose_project_name.txt"

    # 复制 compose 文件
    for cf in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
      safe_copy "${proj_path}/${cf}" "${proj_backup}/"
    done

    # 复制 .env 和 Dockerfile
    safe_copy "${proj_path}/.env" "${proj_backup}/"
    find "${proj_path}" -maxdepth 2 -name "Dockerfile*" -exec cp {} "${proj_backup}/" \; 2>/dev/null || true

    # 记录项目路径 (恢复时需要)
    echo "${proj_path}" > "${proj_backup}/_original_path.txt"

    # 导出使用的镜像列表
    (cd "${proj_path}" && docker compose config --images 2>/dev/null) > "${proj_backup}/_images.txt" 2>/dev/null || true

    # 备份命名卷数据
    local -a volumes=()
    while IFS= read -r vol; do
      vol="$(echo "${vol}" | xargs)"
      [[ -n "${vol}" ]] && volumes+=("${vol}")
    done < <(cd "${proj_path}" && docker compose config --volumes 2>/dev/null)

    if [[ ${#volumes[@]} -gt 0 ]]; then
      local vol_dir="${proj_backup}/volumes"
      safe_mkdir "${vol_dir}"
      for vol_name in "${volumes[@]}"; do
        # 查找卷的实际路径
        local vol_mount
        vol_mount="$(docker volume inspect "${compose_project_name}_${vol_name}" --format '{{ .Mountpoint }}' 2>/dev/null || \
                     docker volume inspect "${vol_name}" --format '{{ .Mountpoint }}' 2>/dev/null || true)"
        if [[ -n "${vol_mount}" && -d "${vol_mount}" ]]; then
          log_debug "    $(lang_pick "备份卷" "Backing up volume"): ${vol_name} (${vol_mount})"
          tar -czf "${vol_dir}/${vol_name}.tar.gz" -C "${vol_mount}" . 2>/dev/null || {
            log_warn "    $(lang_pick "卷" "Volume") ${vol_name} $(lang_pick "备份失败" "backup failed")"
          }
        fi
      done
    fi

    # 备份 bind mount 的主机目录
    local bind_mounts_dir="${proj_backup}/bind_mounts"
    while IFS= read -r mount_line; do
      mount_line="$(echo "${mount_line}" | xargs)"
      if [[ "${mount_line}" == /* ]]; then
        # 绝对路径的 bind mount
        local mount_src="${mount_line%%:*}"
        if [[ -d "${mount_src}" || -f "${mount_src}" ]]; then
          safe_mkdir "${bind_mounts_dir}"
          local safe_name
          safe_name="$(echo "${mount_src}" | tr '/' '_' | sed 's/^_//')"
          if [[ -d "${mount_src}" ]]; then
            tar -czf "${bind_mounts_dir}/${safe_name}.tar.gz" -C "$(dirname "${mount_src}")" "$(basename "${mount_src}")" 2>/dev/null || true
          else
            cp -a "${mount_src}" "${bind_mounts_dir}/${safe_name}" 2>/dev/null || true
          fi
          echo "${mount_line}" >> "${bind_mounts_dir}/_mount_map.txt"
        fi
      fi
    done < <(cd "${proj_path}" && docker compose config 2>/dev/null | grep -E 'source:|device:' | awk '{print $2}' || true)

    # 记录项目目录及子目录的权限/属主信息 (恢复时关键，如 aria2 temp 需要 65534:65534)
    local perms_file="${proj_backup}/_permissions.txt"
    {
      echo "# $(lang_pick "项目目录权限快照 (恢复时用于修复属主和权限)" "Project directory permission snapshot (used to restore owner and mode)")"
      echo "# $(lang_pick "格式: 权限 属主:属组 路径" "Format: mode owner:group path")"
      while IFS= read -r snap_path; do
        local perms owner_group
        perms="$(get_file_mode "${snap_path}")"
        owner_group="$(get_file_owner_group "${snap_path}")"
        [[ "${perms}" == "unknown" || "${owner_group}" == "unknown:unknown" ]] && continue
        printf '%s %s %s\n' "${perms}" "${owner_group}" "${snap_path}"
      done < <(find "${proj_path}" -maxdepth 4 -print 2>/dev/null || true)
    } > "${perms_file}" 2>/dev/null

    # 备份项目目录下所有非数据文件 (yaml/conf/sh/py/json/toml/env 等配置文件)
    find "${proj_path}" -maxdepth 3 -type f \
      \( -name "*.yaml" -o -name "*.yml" -o -name "*.conf" -o -name "*.cfg" \
         -o -name "*.sh" -o -name "*.py" -o -name "*.json" -o -name "*.toml" \
         -o -name "*.env" -o -name "*.ini" -o -name "*.service" \
         -o -name "Makefile" -o -name "requirements*.txt" \) \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.venv/*' \
      2>/dev/null | while read -r cfg_file; do
      local rel_path
      rel_path="${cfg_file#${proj_path}/}"
      local cfg_dst="${proj_backup}/project_configs/${rel_path}"
      safe_mkdir "$(dirname "${cfg_dst}")"
      safe_copy "${cfg_file}" "${cfg_dst}" 2>/dev/null
    done

    ((count+=1))
  done

  local zh_project_label="个项目"
  local zh_service_label="个服务"
  local en_project_label="projects"
  local en_service_label="services"
  (( count == 1 )) && en_project_label="project"
  (( total_services == 1 )) && en_service_label="service"

  log_success "$(lang_pick \
    "Docker Compose: 已备份 ${count}${zh_project_label}，共 ${total_services}${zh_service_label}" \
    "Docker Compose: backed up ${count} ${en_project_label}, ${total_services} ${en_service_label} total")"
  summary_add "ok" "Docker Compose" "$(lang_pick \
    "${count} 个项目，共 ${total_services} 个服务" \
    "${count} ${en_project_label}, ${total_services} ${en_service_label} total")"
}
