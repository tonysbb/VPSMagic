#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 独立 Docker 容器
# ============================================================

[[ -n "${_COLLECTOR_DOCKER_STANDALONE_LOADED:-}" ]] && return 0
_COLLECTOR_DOCKER_STANDALONE_LOADED=1

collect_docker_standalone() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/docker_standalone"

  if ! command -v docker >/dev/null 2>&1; then
    summary_add "skip" "独立容器" "Docker 未安装"
    return 0
  fi

  log_step "$(lang_pick "采集独立 Docker 容器..." "Collecting standalone Docker containers...")"

  # 获取所有容器（排除属于 compose 项目的）
  local -a standalone_ids=()
  while IFS= read -r cid; do
    cid="$(echo "${cid}" | xargs)"
    [[ -z "${cid}" ]] && continue
    # 检查是否属于 Compose 项目
    local label
    label="$(docker inspect "${cid}" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
    if [[ -z "${label}" || "${label}" == "<no value>" ]]; then
      standalone_ids+=("${cid}")
    fi
  done < <(docker ps -aq 2>/dev/null)

  if [[ ${#standalone_ids[@]} -eq 0 ]]; then
    log_info "$(lang_pick "未发现独立 Docker 容器。" "No standalone Docker containers found.")"
    summary_add "skip" "独立容器" "无独立容器"
    return 0
  fi

  safe_mkdir "${target_dir}"
  local count=0

  for cid in "${standalone_ids[@]}"; do
    local name
    name="$(docker inspect "${cid}" --format '{{ .Name }}' 2>/dev/null | sed 's/^\///')"
    [[ -z "${name}" ]] && name="${cid:0:12}"

    local container_dir="${target_dir}/${name}"
    safe_mkdir "${container_dir}"

    log_info "  $(lang_pick "备份容器" "Backing up container"): ${name}"

    if log_dry_run "$(lang_pick "备份独立容器: ${name}" "Back up standalone container: ${name}")"; then
      ((count+=1))
      continue
    fi

    # 导出完整的 inspect 配置
    docker inspect "${cid}" > "${container_dir}/inspect.json" 2>/dev/null

    # 提取并记录关键信息（用于恢复时重建 docker run 命令）
    local image
    image="$(docker inspect "${cid}" --format '{{ .Config.Image }}' 2>/dev/null)"
    local status
    status="$(docker inspect "${cid}" --format '{{ .State.Status }}' 2>/dev/null)"
    local restart_policy
    restart_policy="$(docker inspect "${cid}" --format '{{ .HostConfig.RestartPolicy.Name }}' 2>/dev/null)"

    {
      echo "CONTAINER_NAME=${name}"
      echo "IMAGE=${image}"
      echo "STATUS=${status}"
      echo "RESTART_POLICY=${restart_policy}"

      # 端口映射
      echo "PORTS=$(docker inspect "${cid}" --format '{{ range $p, $conf := .NetworkSettings.Ports }}{{ range $conf }}{{ .HostPort }}:{{ $p }} {{ end }}{{ end }}' 2>/dev/null | xargs)"

      # 环境变量
      echo "ENV=$(docker inspect "${cid}" --format '{{ range .Config.Env }}{{ . }}|{{ end }}' 2>/dev/null)"

      # 挂载
      echo "MOUNTS=$(docker inspect "${cid}" --format '{{ range .Mounts }}{{ .Type }}:{{ .Source }}:{{ .Destination }} {{ end }}' 2>/dev/null | xargs)"

      # 网络
      echo "NETWORKS=$(docker inspect "${cid}" --format '{{ range $k, $v := .NetworkSettings.Networks }}{{ $k }} {{ end }}' 2>/dev/null | xargs)"
    } > "${container_dir}/metadata.env"

    # 备份卷数据
    local vol_dir="${container_dir}/volumes"
    while IFS= read -r mount_info; do
      mount_info="$(echo "${mount_info}" | xargs)"
      [[ -z "${mount_info}" ]] && continue

      local mtype="${mount_info%%:*}"
      local rest="${mount_info#*:}"
      local msrc="${rest%%:*}"
      local mdst="${rest#*:}"

      if [[ -d "${msrc}" ]]; then
        safe_mkdir "${vol_dir}"
        local safe_name
        safe_name="$(echo "${mdst}" | tr '/' '_' | sed 's/^_//')"
        tar -czf "${vol_dir}/${safe_name}.tar.gz" -C "${msrc}" . 2>/dev/null || {
          log_warn "    $(lang_pick "卷数据备份失败" "Volume data backup failed"): ${msrc}"
        }
      fi
    done < <(docker inspect "${cid}" --format '{{ range .Mounts }}{{ .Type }}:{{ .Source }}:{{ .Destination }}{{ printf "\n" }}{{ end }}' 2>/dev/null)

    ((count+=1))
  done

  log_success "$(lang_pick "独立容器: 已备份 ${count} 个" "Standalone containers: backed up ${count}")"
  summary_add "ok" "独立容器" "${count} 个容器"
}
