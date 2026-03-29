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
    log_debug "$(lang_pick "Telegram 未配置，跳过通知。" "Telegram is not configured. Skipping notification.")"
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
    log_debug "$(lang_pick "Telegram 通知发送成功" "Telegram notification sent successfully")"
    return 0
  else
    log_warn "$(lang_pick "Telegram 通知发送失败" "Telegram notification failed") (HTTP ${http_code})"
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

  local message
  message="$(lang_pick "🖥️ *VPS Magic Backup Report*
━━━━━━━━━━━━━━━━━━━━
🏷 主机: \`${hostname}\`
📅 时间: \`${timestamp}\`
📦 大小: \`${archive_size}\`
⏱ 耗时: \`${elapsed}\`
📄 文件: \`$(basename "${backup_file}")\`
━━━━━━━━━━━━━━━━━━━━

${summary}" "🖥️ *VPS Magic Backup Report*
━━━━━━━━━━━━━━━━━━━━
🏷 Host: \`${hostname}\`
📅 Time: \`${timestamp}\`
📦 Size: \`${archive_size}\`
⏱ Elapsed: \`${elapsed}\`
📄 File: \`$(basename "${backup_file}")\`
━━━━━━━━━━━━━━━━━━━━

${summary}")"

  local error_count
  error_count="$(summary_get_error_count)"
  if (( error_count > 0 )); then
    message+="$(lang_pick "

⚠️ *有 ${error_count} 个错误，请检查日志!*" "

⚠️ *${error_count} error(s) detected. Please check the logs.*")"
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

  local message
  message="$(lang_pick "🔄 *VPS Magic Restore Report*
━━━━━━━━━━━━━━━━━━━━
🏷 主机: \`${hostname}\`
📅 时间: \`${timestamp}\`
📦 恢复自: \`${backup_name}\`
⏱ 耗时: \`${elapsed}\`
━━━━━━━━━━━━━━━━━━━━

${summary}" "🔄 *VPS Magic Restore Report*
━━━━━━━━━━━━━━━━━━━━
🏷 Host: \`${hostname}\`
📅 Time: \`${timestamp}\`
📦 Restored from: \`${backup_name}\`
⏱ Elapsed: \`${elapsed}\`
━━━━━━━━━━━━━━━━━━━━

${summary}")"

  _tg_send "${message}"
}

# ---------- 发送简单消息 ----------
notify_message() {
  if [[ "${NOTIFY_ENABLED:-false}" != "true" ]]; then
    return 0
  fi
  _tg_send "$1"
}

# ---------- 发送迁移完成通知 ----------
notify_migrate_result() {
  if [[ "${NOTIFY_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  local hostname
  hostname="$(hostname 2>/dev/null || echo 'unknown')"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  local target_host="${1:-unknown}"
  local archive_size="${2:-unknown}"
  local elapsed="${3:-unknown}"
  local skip_restore="${4:-0}"

  local mode_str
  mode_str="$(lang_pick "完整迁移 (已恢复)" "full migration (restored)")"
  if [[ "${skip_restore}" == "1" ]]; then
    mode_str="$(lang_pick "仅推送 (未恢复)" "push only (not restored)")"
  fi

  local summary
  summary="$(summary_render)"

  local message
  message="$(lang_pick "🚀 *VPS Magic Migration Report*
━━━━━━━━━━━━━━━━━━━━
🏷 源主机: \`${hostname}\`
🎯 目标机: \`${target_host}\`
📅 时间: \`${timestamp}\`
📦 大小: \`${archive_size}\`
⏱ 耗时: \`${elapsed}\`
📋 模式: \`${mode_str}\`
━━━━━━━━━━━━━━━━━━━━

${summary}" "🚀 *VPS Magic Migration Report*
━━━━━━━━━━━━━━━━━━━━
🏷 Source host: \`${hostname}\`
🎯 Target host: \`${target_host}\`
📅 Time: \`${timestamp}\`
📦 Size: \`${archive_size}\`
⏱ Elapsed: \`${elapsed}\`
📋 Mode: \`${mode_str}\`
━━━━━━━━━━━━━━━━━━━━

${summary}")"

  _tg_send "${message}"
}
