#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 通知模块 (Telegram)
# ============================================================

[[ -n "${_VPSMAGIC_NOTIFY_LOADED:-}" ]] && return 0
_VPSMAGIC_NOTIFY_LOADED=1

# ---------- Telegram 发送 ----------
_tg_send() {
  local message="$1"
  local parse_mode="${2:-Markdown}"

  if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    log_debug "Telegram 未配置，跳过通知。"
    return 0
  fi

  local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
  local response
  response="$(curl -s -w "\n%{http_code}" -X POST "${url}" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=${parse_mode}" \
    --data-urlencode "text=${message}" \
    --connect-timeout 10 \
    --max-time 30 2>/dev/null)"

  local http_code
  http_code="$(echo "${response}" | tail -1)"

  if [[ "${http_code}" == "200" ]]; then
    log_debug "Telegram 通知发送成功"
    return 0
  else
    log_warn "Telegram 通知发送失败 (HTTP ${http_code})"
    return 1
  fi
}

# ---------- 发送备份完成通知 ----------
notify_backup_result() {
  if [[ "${NOTIFY_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  local hostname
  hostname="$(hostname 2>/dev/null || echo 'unknown')"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  local summary
  summary="$(summary_render)"

  local archive_size="${1:-unknown}"
  local elapsed="${2:-unknown}"
  local backup_file="${3:-unknown}"

  local message="🖥️ *VPS Magic Backup Report*
━━━━━━━━━━━━━━━━━━━━
🏷 主机: \`${hostname}\`
📅 时间: \`${timestamp}\`
📦 大小: \`${archive_size}\`
⏱ 耗时: \`${elapsed}\`
📄 文件: \`$(basename "${backup_file}")\`
━━━━━━━━━━━━━━━━━━━━

${summary}"

  local error_count
  error_count="$(summary_get_error_count)"
  if (( error_count > 0 )); then
    message+="

⚠️ *有 ${error_count} 个错误，请检查日志!*"
  fi

  _tg_send "${message}"
}

# ---------- 发送恢复完成通知 ----------
notify_restore_result() {
  if [[ "${NOTIFY_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  local hostname
  hostname="$(hostname 2>/dev/null || echo 'unknown')"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local backup_name="${1:-unknown}"
  local elapsed="${2:-unknown}"

  local summary
  summary="$(summary_render)"

  local message="🔄 *VPS Magic Restore Report*
━━━━━━━━━━━━━━━━━━━━
🏷 主机: \`${hostname}\`
📅 时间: \`${timestamp}\`
📦 恢复自: \`${backup_name}\`
⏱ 耗时: \`${elapsed}\`
━━━━━━━━━━━━━━━━━━━━

${summary}"

  _tg_send "${message}"
}

# ---------- 发送简单消息 ----------
notify_message() {
  if [[ "${NOTIFY_ENABLED:-false}" != "true" ]]; then
    return 0
  fi
  _tg_send "$1"
}
