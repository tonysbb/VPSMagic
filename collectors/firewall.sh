#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 采集器: 防火墙规则
# ============================================================

[[ -n "${_COLLECTOR_FIREWALL_LOADED:-}" ]] && return 0
_COLLECTOR_FIREWALL_LOADED=1

collect_firewall() {
  local staging_dir="$1"
  local target_dir="${staging_dir}/firewall"

  log_step "采集防火墙规则..."

  local found=0

  if log_dry_run "备份防火墙规则"; then return 0; fi

  safe_mkdir "${target_dir}"

  # ---- UFW ----
  if command -v ufw >/dev/null 2>&1; then
    log_info "  发现 UFW 防火墙"
    ufw status verbose > "${target_dir}/ufw_status.txt" 2>/dev/null || true
    ufw show raw > "${target_dir}/ufw_raw.txt" 2>/dev/null || true
    # 备份 UFW 规则文件
    if [[ -d "/etc/ufw" ]]; then
      tar -czf "${target_dir}/etc_ufw.tar.gz" -C /etc ufw 2>/dev/null || true
    fi
    # 备份 UFW 用户规则
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
      safe_copy "${f}" "${target_dir}/"
    done
    found=1
  fi

  # ---- iptables ----
  if command -v iptables >/dev/null 2>&1; then
    log_info "  导出 iptables 规则"
    iptables-save > "${target_dir}/iptables.rules" 2>/dev/null || true
    if command -v ip6tables-save >/dev/null 2>&1; then
      ip6tables-save > "${target_dir}/ip6tables.rules" 2>/dev/null || true
    fi
    found=1
  fi

  # ---- nftables ----
  if command -v nft >/dev/null 2>&1; then
    log_info "  导出 nftables 规则"
    nft list ruleset > "${target_dir}/nftables.rules" 2>/dev/null || true
    safe_copy "/etc/nftables.conf" "${target_dir}/"
    found=1
  fi

  # ---- firewalld ----
  if command -v firewall-cmd >/dev/null 2>&1; then
    log_info "  发现 firewalld"
    firewall-cmd --list-all-zones > "${target_dir}/firewalld_zones.txt" 2>/dev/null || true
    firewall-cmd --list-all > "${target_dir}/firewalld_default.txt" 2>/dev/null || true
    if [[ -d "/etc/firewalld" ]]; then
      tar -czf "${target_dir}/etc_firewalld.tar.gz" -C /etc firewalld 2>/dev/null || true
    fi
    found=1
  fi

  # ---- fail2ban ----
  if command -v fail2ban-client >/dev/null 2>&1; then
    log_info "  发现 fail2ban"
    fail2ban-client status > "${target_dir}/fail2ban_status.txt" 2>/dev/null || true
    if [[ -d "/etc/fail2ban" ]]; then
      tar -czf "${target_dir}/etc_fail2ban.tar.gz" -C /etc fail2ban 2>/dev/null || true
    fi
    found=1
  fi

  if (( found == 0 )); then
    log_info "未发现防火墙配置。"
    summary_add "skip" "防火墙" "未发现"
  else
    log_success "防火墙规则采集完成"
    summary_add "ok" "防火墙" "规则已备份"
  fi
}
