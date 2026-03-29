#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: SSL 证书
# ============================================================

[[ -n "${_COLLECTOR_SSL_LOADED:-}" ]] && return 0
_COLLECTOR_SSL_LOADED=1

collect_ssl_certs() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/ssl_certs"

  log_step "$(lang_pick "采集 SSL 证书..." "Collecting SSL certificates...")"

  local found=0

  # ---- Let's Encrypt (certbot) ----
  if [[ -d "/etc/letsencrypt" ]]; then
    log_info "  $(lang_pick "发现 Let's Encrypt 证书" "Detected Let's Encrypt certificates")"
    if ! log_dry_run "$(lang_pick "备份 /etc/letsencrypt" "Back up /etc/letsencrypt")"; then
      safe_mkdir "${target_dir}"
      tar -czf "${target_dir}/letsencrypt.tar.gz" -C /etc letsencrypt 2>/dev/null || {
        log_warn "    $(lang_pick "Let's Encrypt 备份失败" "Let's Encrypt backup failed")"
      }
      found=1
    fi
  fi

  # ---- acme.sh ----
  local acme_dirs=("${HOME}/.acme.sh" "/root/.acme.sh" "/home/*/.acme.sh")
  for pattern in "${acme_dirs[@]}"; do
    for acme_dir in ${pattern}; do
      if [[ -d "${acme_dir}" ]]; then
        log_info "  $(lang_pick "发现 acme.sh 证书" "Detected acme.sh certificates"): ${acme_dir}"
        if ! log_dry_run "$(lang_pick "备份 ${acme_dir}" "Back up ${acme_dir}")"; then
          safe_mkdir "${target_dir}"
          local safe_name
          safe_name="acme_$(echo "${acme_dir}" | tr '/' '_' | sed 's/^_//')"
          tar -czf "${target_dir}/${safe_name}.tar.gz" \
            -C "$(dirname "${acme_dir}")" "$(basename "${acme_dir}")" 2>/dev/null || {
            log_warn "    $(lang_pick "acme.sh 备份失败" "acme.sh backup failed"): ${acme_dir}"
          }
          echo "${acme_dir}" >> "${target_dir}/_acme_paths.txt"
          found=1
        fi
      fi
    done
  done

  # ---- 自定义 SSL 目录 ----
  local custom_ssl_dirs=("/etc/ssl/private" "/etc/ssl/certs/custom" "/opt/ssl")
  for ssldir in "${custom_ssl_dirs[@]}"; do
    if [[ -d "${ssldir}" ]] && [[ "$(ls -A "${ssldir}" 2>/dev/null)" ]]; then
      log_info "  $(lang_pick "发现自定义 SSL 目录" "Detected custom SSL directory"): ${ssldir}"
      if ! log_dry_run "$(lang_pick "备份 ${ssldir}" "Back up ${ssldir}")"; then
        safe_mkdir "${target_dir}"
        local safe_name
        safe_name="$(echo "${ssldir}" | tr '/' '_' | sed 's/^_//')"
        tar -czf "${target_dir}/${safe_name}.tar.gz" \
          -C "$(dirname "${ssldir}")" "$(basename "${ssldir}")" 2>/dev/null || true
        found=1
      fi
    fi
  done

  if (( found == 0 )); then
    log_info "$(lang_pick "未发现 SSL 证书。" "No SSL certificates found.")"
    summary_add "skip" "SSL 证书" "未发现"
  else
    log_success "$(lang_pick "SSL 证书采集完成" "SSL certificate collection completed")"
    summary_add "ok" "SSL 证书" "已备份"
  fi
}
