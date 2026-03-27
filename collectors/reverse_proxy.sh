#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 反向代理配置 (Nginx/Caddy)
# ============================================================

[[ -n "${_COLLECTOR_REVERSE_PROXY_LOADED:-}" ]] && return 0
_COLLECTOR_REVERSE_PROXY_LOADED=1

_write_reverse_proxy_status() {
  local svc_name="$1"
  local out_file="$2"
  local enabled_state="unknown"
  local active_state="unknown"

  if systemctl list-unit-files "${svc_name}.service" >/dev/null 2>&1 || systemctl cat "${svc_name}" >/dev/null 2>&1; then
    enabled_state="$(systemctl is-enabled "${svc_name}" 2>/dev/null || echo "unknown")"
    active_state="$(systemctl is-active "${svc_name}" 2>/dev/null || echo "unknown")"
  fi

  {
    echo "SERVICE=${svc_name}"
    echo "ENABLED=${enabled_state}"
    echo "ACTIVE=${active_state}"
  } > "${out_file}"
}

collect_reverse_proxy() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/reverse_proxy"

  log_step "采集反向代理配置..."

  local found=0
  local apache_detected=0

  # ---- Nginx ----
  if command -v nginx >/dev/null 2>&1 || [[ -d "/etc/nginx" ]]; then
    log_info "  发现 Nginx 配置"
    local nginx_dir="${target_dir}/nginx"

    if log_dry_run "备份 Nginx 配置"; then
      found=1
    else
      safe_mkdir "${nginx_dir}"
      if [[ -d "/etc/nginx" ]]; then
        tar -czf "${nginx_dir}/etc_nginx.tar.gz" -C /etc nginx 2>/dev/null || {
          log_warn "    /etc/nginx 备份失败"
        }
      fi
      # 额外检查 conf.d 和 sites 目录
      for extra_dir in /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled; do
        [[ -d "${extra_dir}" ]] && log_debug "    包含: ${extra_dir}"
      done
      # Nginx 版本和模块信息
      nginx -V > "${nginx_dir}/version.txt" 2>&1 || true
      nginx -T > "${nginx_dir}/full_config.txt" 2>/dev/null || true
      _write_reverse_proxy_status "nginx" "${nginx_dir}/status.env"
      found=1
    fi
  fi

  # ---- Caddy ----
  if command -v caddy >/dev/null 2>&1 || [[ -f "/etc/caddy/Caddyfile" ]]; then
    log_info "  发现 Caddy 配置"
    local caddy_dir="${target_dir}/caddy"

    if log_dry_run "备份 Caddy 配置"; then
      found=1
    else
      safe_mkdir "${caddy_dir}"
      if [[ -d "/etc/caddy" ]]; then
        tar -czf "${caddy_dir}/etc_caddy.tar.gz" -C /etc caddy 2>/dev/null || {
          log_warn "    /etc/caddy 备份失败"
        }
      fi
      # 单独 Caddyfile
      for cf in /etc/caddy/Caddyfile /root/Caddyfile /srv/Caddyfile; do
        safe_copy "${cf}" "${caddy_dir}/" 2>/dev/null
      done
      caddy version > "${caddy_dir}/version.txt" 2>/dev/null || true
      _write_reverse_proxy_status "caddy" "${caddy_dir}/status.env"
      found=1
    fi
  fi

  # ---- Apache (可选) ----
  if systemctl is-active apache2 >/dev/null 2>&1 || systemctl is-enabled apache2 >/dev/null 2>&1; then
    apache_detected=1
  elif [[ -f "/etc/apache2/apache2.conf" ]] || [[ -f "/etc/httpd/conf/httpd.conf" ]]; then
    if find /etc/apache2/sites-enabled /etc/apache2/sites-available /etc/httpd/conf.d -maxdepth 1 -type f 2>/dev/null | grep -q .; then
      apache_detected=1
    fi
  fi

  if (( apache_detected == 1 )); then
    log_info "  发现 Apache 配置"
    local apache_dir="${target_dir}/apache"

    if ! log_dry_run "备份 Apache 配置"; then
      safe_mkdir "${apache_dir}"
      if [[ -d "/etc/apache2" ]]; then
        tar -czf "${apache_dir}/etc_apache2.tar.gz" -C /etc apache2 2>/dev/null || true
      fi
      if [[ -d "/etc/httpd" ]]; then
        tar -czf "${apache_dir}/etc_httpd.tar.gz" -C /etc httpd 2>/dev/null || true
      fi
      _write_reverse_proxy_status "apache2" "${apache_dir}/status.env"
      found=1
    fi
  fi

  # ---- Traefik (Docker 中检测) ----
  if command -v docker >/dev/null 2>&1; then
    local traefik_id
    traefik_id="$(docker ps -q --filter "ancestor=traefik" 2>/dev/null | head -1)"
    if [[ -z "${traefik_id}" ]]; then
      traefik_id="$(docker ps -q --filter "name=traefik" 2>/dev/null | head -1)"
    fi
    if [[ -n "${traefik_id}" ]]; then
      log_info "  发现 Traefik 容器"
      local traefik_dir="${target_dir}/traefik"
      if ! log_dry_run "备份 Traefik 配置"; then
        safe_mkdir "${traefik_dir}"
        docker inspect "${traefik_id}" > "${traefik_dir}/inspect.json" 2>/dev/null || true
        # 检查常见配置路径
        for tp in /etc/traefik /opt/traefik; do
          if [[ -d "${tp}" ]]; then
            tar -czf "${traefik_dir}/$(basename "${tp}").tar.gz" -C "$(dirname "${tp}")" "$(basename "${tp}")" 2>/dev/null || true
          fi
        done
        found=1
      fi
    fi
  fi

  if [[ "${found}" -eq 0 ]]; then
    log_info "未发现常见反向代理 (Nginx/Caddy/Apache/Traefik)。"
    summary_add "skip" "反向代理" "未发现"
  else
    log_success "反向代理配置采集完成"
    summary_add "ok" "反向代理" "配置已备份"
  fi
}
