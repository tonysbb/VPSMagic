#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 数据库 (MySQL/PostgreSQL/SQLite)
# ============================================================

[[ -n "${_COLLECTOR_DATABASE_LOADED:-}" ]] && return 0
_COLLECTOR_DATABASE_LOADED=1

collect_databases() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/database"

  log_step "$(lang_pick "采集数据库备份..." "Collecting database backups...")"

  local found=0

  # ==================== MySQL / MariaDB ====================
  _collect_mysql() {
    local mysql_dir="${target_dir}/mysql"
    local dumped=0

    # Docker 容器中的 MySQL
    if [[ -n "${DB_MYSQL_CONTAINERS:-}" ]]; then
      local -a containers=()
      parse_list "${DB_MYSQL_CONTAINERS}" containers
      for cname in "${containers[@]}"; do
        if docker ps -q --filter "name=${cname}" 2>/dev/null | grep -q .; then
          log_info "  $(lang_pick "导出 MySQL 容器" "Exporting MySQL container"): ${cname}"
          safe_mkdir "${mysql_dir}"
          if ! log_dry_run "docker exec ${cname} mysqldump --all-databases"; then
            local out_file="${mysql_dir}/${cname}_all.sql"
            docker exec "${cname}" mysqldump --all-databases --single-transaction \
              -u root -p"${DB_MYSQL_HOST_PASS:-root}" 2>/dev/null \
              > "${out_file}" || {
              log_warn "    $(lang_pick "MySQL 容器导出失败" "MySQL container export failed"): ${cname}"
              rm -f "${out_file}" 2>/dev/null || true
              continue
            }
            if [[ -s "${out_file}" ]]; then
              ((dumped+=1))
            else
              log_warn "    $(lang_pick "MySQL 容器导出为空，已忽略" "MySQL container export is empty, ignored"): ${cname}"
              rm -f "${out_file}" 2>/dev/null || true
            fi
          fi
        else
          log_warn "  $(lang_pick "MySQL 容器不存在或未运行" "MySQL container not found or not running"): ${cname}"
        fi
      done
    fi

    # 自动检测 MySQL Docker 容器
    if command -v docker >/dev/null 2>&1; then
      local -a auto_mysql_cids=()
      while IFS= read -r cid; do
        cid="$(echo "${cid}" | xargs)"
        [[ -z "${cid}" ]] && continue
        if ! in_array "${cid}" "${auto_mysql_cids[@]}"; then
          auto_mysql_cids+=("${cid}")
        fi
      done < <(
        docker ps -q --filter "ancestor=mysql" 2>/dev/null
        docker ps -q --filter "ancestor=mariadb" 2>/dev/null
        docker ps -q --filter "name=mysql" 2>/dev/null
        docker ps -q --filter "name=mariadb" 2>/dev/null
      )

      for cid in "${auto_mysql_cids[@]}"; do
        local cname
        cname="$(docker inspect "${cid}" --format '{{ .Name }}' 2>/dev/null | sed 's/^\///')"
        # 跳过已手动配置的
        if [[ -n "${DB_MYSQL_CONTAINERS:-}" ]] && echo "${DB_MYSQL_CONTAINERS}" | grep -qw "${cname}"; then
          continue
        fi
        log_info "  $(lang_pick "自动发现 MySQL 容器" "Auto-detected MySQL container"): ${cname}"
        safe_mkdir "${mysql_dir}"
        if ! log_dry_run "docker exec ${cname} mysqldump --all-databases"; then
          local out_file="${mysql_dir}/${cname}_all.sql"
          # 尝试从环境变量获取 root 密码
          local mysql_pass
          mysql_pass="$(docker inspect "${cid}" --format '{{ range .Config.Env }}{{ . }}{{ printf "\n" }}{{ end }}' 2>/dev/null | awk -F= '/^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=/{print substr($0, index($0,"=")+1); exit}')"
          if [[ -n "${mysql_pass}" ]]; then
            docker exec "${cname}" mysqldump --all-databases --single-transaction \
              -u root -p"${mysql_pass}" 2>/dev/null \
              > "${out_file}" || {
              log_warn "    $(lang_pick "MySQL 容器导出失败（自动探测）" "MySQL container export failed (auto-detected)"): ${cname}"
              rm -f "${out_file}" 2>/dev/null || true
              continue
            }
          else
            docker exec "${cname}" mysqldump --all-databases --single-transaction \
              -u root 2>/dev/null > "${out_file}" || {
              log_warn "    $(lang_pick "MySQL 容器导出失败（未检测到 root 密码）" "MySQL container export failed (root password not detected)"): ${cname}"
              rm -f "${out_file}" 2>/dev/null || true
              continue
            }
          fi

          if [[ -s "${out_file}" ]]; then
            ((dumped+=1))
          else
            log_warn "    $(lang_pick "MySQL 容器导出为空，已忽略" "MySQL container export is empty, ignored"): ${cname}"
            rm -f "${out_file}" 2>/dev/null || true
          fi
        fi
      done
    fi

    # 主机直装 MySQL
    if command -v mysqldump >/dev/null 2>&1 && [[ -n "${DB_MYSQL_HOST_USER:-}" ]]; then
      log_info "  $(lang_pick "导出主机 MySQL..." "Exporting host MySQL...")"
      safe_mkdir "${mysql_dir}"
      if ! log_dry_run "mysqldump --all-databases"; then
        local out_file="${mysql_dir}/host_all.sql"
        mysqldump --all-databases --single-transaction \
          -u "${DB_MYSQL_HOST_USER}" \
          ${DB_MYSQL_HOST_PASS:+-p"${DB_MYSQL_HOST_PASS}"} \
          2>/dev/null > "${out_file}" || {
          log_warn "    $(lang_pick "主机 MySQL 导出失败" "Host MySQL export failed")"
          rm -f "${out_file}" 2>/dev/null || true
        }
        if [[ -s "${out_file}" ]]; then
          ((dumped+=1))
        fi
      fi
    fi

    if (( dumped > 0 )); then
      found=1
      summary_add "ok" "MySQL" "$(lang_pick "${dumped} 个数据库导出" "${dumped} database exports")"
    fi
  }

  # ==================== PostgreSQL ====================
  _collect_postgres() {
    local pg_dir="${target_dir}/postgres"
    local dumped=0

    # Docker 容器
    if [[ -n "${DB_POSTGRES_CONTAINERS:-}" ]]; then
      local -a containers=()
      parse_list "${DB_POSTGRES_CONTAINERS}" containers
      for cname in "${containers[@]}"; do
        if docker ps -q --filter "name=${cname}" 2>/dev/null | grep -q .; then
          log_info "  $(lang_pick "导出 PostgreSQL 容器" "Exporting PostgreSQL container"): ${cname}"
          safe_mkdir "${pg_dir}"
          if ! log_dry_run "docker exec ${cname} pg_dumpall"; then
            local out_file="${pg_dir}/${cname}_all.sql"
            docker exec "${cname}" pg_dumpall -U postgres 2>/dev/null \
              > "${out_file}" || {
              log_warn "    $(lang_pick "PostgreSQL 容器导出失败" "PostgreSQL container export failed"): ${cname}"
              rm -f "${out_file}" 2>/dev/null || true
              continue
            }
            if [[ -s "${out_file}" ]]; then
              ((dumped+=1))
            else
              log_warn "    $(lang_pick "PostgreSQL 容器导出为空，已忽略" "PostgreSQL container export is empty, ignored"): ${cname}"
              rm -f "${out_file}" 2>/dev/null || true
            fi
          fi
        fi
      done
    fi

    # 自动检测 PostgreSQL Docker 容器
    if command -v docker >/dev/null 2>&1; then
      local -a auto_pg_cids=()
      while IFS= read -r cid; do
        cid="$(echo "${cid}" | xargs)"
        [[ -z "${cid}" ]] && continue
        if ! in_array "${cid}" "${auto_pg_cids[@]}"; then
          auto_pg_cids+=("${cid}")
        fi
      done < <(
        docker ps -q --filter "ancestor=postgres" 2>/dev/null
        docker ps -q --filter "name=postgres" 2>/dev/null
      )

      for cid in "${auto_pg_cids[@]}"; do
        local cname
        cname="$(docker inspect "${cid}" --format '{{ .Name }}' 2>/dev/null | sed 's/^\///')"
        if [[ -n "${DB_POSTGRES_CONTAINERS:-}" ]] && echo "${DB_POSTGRES_CONTAINERS}" | grep -qw "${cname}"; then
          continue
        fi
        log_info "  $(lang_pick "自动发现 PostgreSQL 容器" "Auto-detected PostgreSQL container"): ${cname}"
        safe_mkdir "${pg_dir}"
        if ! log_dry_run "docker exec ${cname} pg_dumpall"; then
          local out_file="${pg_dir}/${cname}_all.sql"
          docker exec "${cname}" pg_dumpall -U postgres 2>/dev/null \
            > "${out_file}" || {
            log_warn "    $(lang_pick "PostgreSQL 容器导出失败（自动探测）" "PostgreSQL container export failed (auto-detected)"): ${cname}"
            rm -f "${out_file}" 2>/dev/null || true
            continue
          }
          if [[ -s "${out_file}" ]]; then
            ((dumped+=1))
          else
            log_warn "    $(lang_pick "PostgreSQL 容器导出为空，已忽略" "PostgreSQL container export is empty, ignored"): ${cname}"
            rm -f "${out_file}" 2>/dev/null || true
          fi
        fi
      done
    fi

    # 主机直装 PostgreSQL
    if command -v pg_dumpall >/dev/null 2>&1; then
      log_info "  $(lang_pick "导出主机 PostgreSQL..." "Exporting host PostgreSQL...")"
      safe_mkdir "${pg_dir}"
      if ! log_dry_run "pg_dumpall"; then
        local out_file="${pg_dir}/host_all.sql"
        sudo -u postgres pg_dumpall 2>/dev/null > "${out_file}" || {
          log_warn "    $(lang_pick "主机 PostgreSQL 导出失败" "Host PostgreSQL export failed")"
          rm -f "${out_file}" 2>/dev/null || true
        }
        if [[ -s "${out_file}" ]]; then
          ((dumped+=1))
        fi
      fi
    fi

    if (( dumped > 0 )); then
      found=1
      summary_add "ok" "PostgreSQL" "$(lang_pick "${dumped} 个数据库导出" "${dumped} database exports")"
    fi
  }

  # ==================== SQLite ====================
  _collect_sqlite() {
    if [[ -z "${DB_SQLITE_PATHS:-}" ]]; then
      return 0
    fi

    local sqlite_dir="${target_dir}/sqlite"
    local -a paths=()
    parse_list "${DB_SQLITE_PATHS}" paths
    local dumped=0

    for db_path in "${paths[@]}"; do
      if [[ ! -f "${db_path}" ]]; then
        log_warn "  $(lang_pick "SQLite 文件不存在" "SQLite file does not exist"): ${db_path}"
        continue
      fi
      log_info "  $(lang_pick "备份 SQLite" "Backing up SQLite"): ${db_path}"
      safe_mkdir "${sqlite_dir}"

      if ! log_dry_run "$(lang_pick "备份 SQLite" "Backup SQLite"): ${db_path}"; then
        local safe_name
        safe_name="$(echo "${db_path}" | tr '/' '_' | sed 's/^_//')"
        if command -v sqlite3 >/dev/null 2>&1; then
          sqlite3 "${db_path}" ".backup '${sqlite_dir}/${safe_name}'" 2>/dev/null || {
            # 回退到直接复制
            cp -a "${db_path}" "${sqlite_dir}/${safe_name}" 2>/dev/null
            log_warn "    $(lang_pick "sqlite3 .backup 失败，已直接复制。" "sqlite3 .backup failed, copied directly instead.")"
          }
        else
          cp -a "${db_path}" "${sqlite_dir}/${safe_name}" 2>/dev/null
        fi
        # 记录原始路径
        echo "${db_path}" >> "${sqlite_dir}/_path_map.txt"
        ((dumped+=1))
      fi
    done

    if (( dumped > 0 )); then
      found=1
      summary_add "ok" "SQLite" "$(lang_pick "${dumped} 个数据库" "${dumped} databases")"
    fi
  }

  _collect_mysql
  _collect_postgres
  _collect_sqlite

  if (( found == 0 )); then
    log_info "$(lang_pick "未发现需要备份的数据库。" "No databases found for backup.")"
    summary_add "skip" "数据库" "未发现"
  else
    log_success "$(lang_pick "数据库备份采集完成" "Database backup collection completed")"
  fi
}
