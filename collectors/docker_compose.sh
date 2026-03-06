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
    log_info "Docker 未安装，跳过 Docker Compose 采集。"
    summary_add "skip" "Docker Compose" "Docker 未安装"
    return 0
  fi

  log_step "采集 Docker Compose 项目..."

  # 探测 Compose 项目
  local -a projects=()
  if [[ "${COMPOSE_PROJECTS}" == "auto" ]]; then
    log_info "自动探测运行中的 Docker Compose 项目..."
    # 方法1: docker compose ls (新版)
    if docker compose ls --format json >/dev/null 2>&1; then
      while IFS= read -r line; do
        local proj_dir
        proj_dir="$(echo "${line}" | grep -o '"ConfigFiles":"[^"]*"' | head -1 | sed 's/"ConfigFiles":"//;s/"//' | xargs dirname 2>/dev/null)"
        if [[ -n "${proj_dir}" && -d "${proj_dir}" ]]; then
          projects+=("${proj_dir}")
        fi
      done < <(docker compose ls --format json 2>/dev/null)
    fi

    # 方法2: 查找常见路径下的 docker-compose.yml
    if [[ ${#projects[@]} -eq 0 ]]; then
      local search_dirs=("/opt" "/srv" "/home" "/root" "/var/docker")
      for sdir in "${search_dirs[@]}"; do
        if [[ -d "${sdir}" ]]; then
          while IFS= read -r f; do
            local proj_d
            proj_d="$(dirname "${f}")"
            if ! in_array "${proj_d}" "${projects[@]}"; then
              projects+=("${proj_d}")
            fi
          done < <(find "${sdir}" -maxdepth 4 -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" 2>/dev/null)
        fi
      done
    fi
  else
    parse_list "${COMPOSE_PROJECTS}" projects
  fi

  if [[ ${#projects[@]} -eq 0 ]]; then
    log_info "未发现 Docker Compose 项目。"
    summary_add "skip" "Docker Compose" "未发现项目"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0

  for proj_path in "${projects[@]}"; do
    if [[ ! -d "${proj_path}" ]]; then
      log_warn "项目目录不存在: ${proj_path}"
      continue
    fi

    local proj_name
    proj_name="$(basename "${proj_path}")"
    local proj_backup="${target_dir}/${proj_name}"
    safe_mkdir "${proj_backup}"

    log_info "  备份项目: ${proj_name} (${proj_path})"

    if log_dry_run "备份 Docker Compose 项目: ${proj_path}"; then
      ((count++))
      continue
    fi

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
        vol_mount="$(docker volume inspect "${proj_name}_${vol_name}" --format '{{ .Mountpoint }}' 2>/dev/null || \
                     docker volume inspect "${vol_name}" --format '{{ .Mountpoint }}' 2>/dev/null || true)"
        if [[ -n "${vol_mount}" && -d "${vol_mount}" ]]; then
          log_debug "    备份卷: ${vol_name} (${vol_mount})"
          tar -czf "${vol_dir}/${vol_name}.tar.gz" -C "${vol_mount}" . 2>/dev/null || {
            log_warn "    卷 ${vol_name} 备份失败"
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
      echo "# 项目目录权限快照 (恢复时用于修复属主和权限)"
      echo "# 格式: 权限 属主:属组 路径"
      find "${proj_path}" -maxdepth 4 -printf '%m %u:%g %p\n' 2>/dev/null || \
        find "${proj_path}" -maxdepth 4 -exec stat -c '%a %U:%G %n' {} \; 2>/dev/null || true
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

    ((count++))
  done

  log_success "Docker Compose: 已备份 ${count} 个项目"
  summary_add "ok" "Docker Compose" "${count} 个项目"
}

