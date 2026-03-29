#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 日志模块
# 提供带颜色的终端输出和文件日志记录
# ============================================================

# 防止重复 source
[[ -n "${_VPSMAGIC_LOGGER_LOADED:-}" ]] && return 0
_VPSMAGIC_LOGGER_LOADED=1

# ---------- 颜色定义 ----------
readonly _CLR_RED='\033[0;31m'
readonly _CLR_GREEN='\033[0;32m'
readonly _CLR_YELLOW='\033[1;33m'
readonly _CLR_BLUE='\033[0;34m'
readonly _CLR_CYAN='\033[0;36m'
readonly _CLR_MAGENTA='\033[0;35m'
readonly _CLR_BOLD='\033[1m'
readonly _CLR_DIM='\033[2m'
readonly _CLR_NC='\033[0m'

# ---------- 全局变量 ----------
LOG_FILE="${LOG_FILE:-}"
_SUMMARY_ITEMS=()
_ERROR_COUNT=0
_WARN_COUNT=0

# ---------- 内部函数 ----------
_ts() {
  date +'%Y-%m-%d %H:%M:%S'
}

_log_to_file() {
  if [[ -n "${LOG_FILE}" && "${LOG_FILE}" != "/dev/null" ]]; then
    # 测试是否可写，不可写则静默跳过（避免反复输出权限错误）
    if [[ -z "${_LOG_FILE_WRITABLE:-}" ]]; then
      local dir
      dir="$(dirname "${LOG_FILE}")"
      if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}" 2>/dev/null || { _LOG_FILE_WRITABLE=0; return 0; }
      fi
      if touch "${LOG_FILE}" 2>/dev/null; then
        _LOG_FILE_WRITABLE=1
      else
        _LOG_FILE_WRITABLE=0
        return 0
      fi
    fi
    if [[ "${_LOG_FILE_WRITABLE}" == "1" ]]; then
      echo "[$(_ts)] $*" >> "${LOG_FILE}" 2>/dev/null || true
    fi
  fi
  return 0
}

# ---------- 公开日志函数 ----------
log_info() {
  echo -e "${_CLR_BLUE}[INFO $(_ts)]${_CLR_NC} $*"
  _log_to_file "[INFO] $*"
}

log_warn() {
  echo -e "${_CLR_YELLOW}[WARN $(_ts)]${_CLR_NC} $*"
  _log_to_file "[WARN] $*"
  ((_WARN_COUNT++)) || true
}

log_warn_soft() {
  echo -e "${_CLR_YELLOW}[WARN $(_ts)]${_CLR_NC} $*"
  _log_to_file "[WARN_SOFT] $*"
}

log_error() {
  echo -e "${_CLR_RED}[ERROR $(_ts)]${_CLR_NC} $*" >&2
  _log_to_file "[ERROR] $*"
  ((_ERROR_COUNT++)) || true
}

log_success() {
  echo -e "${_CLR_GREEN}[OK $(_ts)]${_CLR_NC} $*"
  _log_to_file "[OK] $*"
}

log_step() {
  echo -e "${_CLR_CYAN}[STEP $(_ts)]${_CLR_NC} ${_CLR_BOLD}$*${_CLR_NC}"
  _log_to_file "[STEP] $*"
}

log_debug() {
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo -e "${_CLR_DIM}[DEBUG $(_ts)] $*${_CLR_NC}"
  fi
  _log_to_file "[DEBUG] $*"
}

log_dry_run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo -e "${_CLR_DIM}[DRY-RUN] $(lang_pick "将执行" "Would run"): $*${_CLR_NC}"
    _log_to_file "[DRY-RUN] $*"
    return 0
  fi
  return 1
}

# ---------- 摘要收集 ----------
summary_add() {
  local status="$1"  # ok / warn / error / skip
  local module="$2"
  local detail="${3:-}"
  _SUMMARY_ITEMS+=("${status}|${module}|${detail}")
  _log_to_file "[SUMMARY] ${status} | ${module} | ${detail}"
}

_summary_count_status() {
  local target_status="$1"
  local count=0
  local item=""
  local status=""

  for item in "${_SUMMARY_ITEMS[@]}"; do
    IFS='|' read -r status _ <<< "${item}"
    [[ "${status}" == "${target_status}" ]] && ((count+=1))
  done

  printf '%s\n' "${count}"
}

summary_get_warn_count() {
  local summary_warn_count=0
  summary_warn_count="$(_summary_count_status "warn")"
  if (( _WARN_COUNT > summary_warn_count )); then
    printf '%s\n' "${_WARN_COUNT}"
  else
    printf '%s\n' "${summary_warn_count}"
  fi
}

summary_render() {
  local output=""
  local sep="————————————————————"
  local warn_count=0
  local error_count=0

  warn_count="$(summary_get_warn_count)"
  error_count="$(summary_get_error_count)"

  output+="📋 $(lang_pick "VPS Magic Backup 执行摘要" "VPS Magic Backup execution summary")\n"
  output+="${sep}\n"

  for item in "${_SUMMARY_ITEMS[@]}"; do
    IFS='|' read -r status module detail <<< "${item}"
    local icon=""
    local rendered_module rendered_detail
    rendered_module="$(summary_module_name "${module}")"
    rendered_detail="$(summary_detail_text "${detail}")"
    case "${status}" in
      ok)    icon="✅" ;;
      warn)  icon="⚠️" ;;
      error) icon="❌" ;;
      skip)  icon="⏭️" ;;
      *)     icon="•" ;;
    esac
    if [[ -n "${rendered_detail}" ]]; then
      output+="${icon} ${rendered_module}: ${rendered_detail}\n"
    else
      output+="${icon} ${rendered_module}\n"
    fi
  done

  output+="${sep}\n"
  output+="⚠️ $(lang_pick "警告" "Warnings"): ${warn_count}  ❌ $(lang_pick "错误" "Errors"): ${error_count}\n"

  echo -e "${output}"
}

summary_get_error_count() {
  local summary_error_count=0
  summary_error_count="$(_summary_count_status "error")"
  if (( _ERROR_COUNT > summary_error_count )); then
    printf '%s\n' "${_ERROR_COUNT}"
  else
    printf '%s\n' "${summary_error_count}"
  fi
}

# ---------- 分隔线与标题 ----------
log_separator() {
  local char="${1:-─}"
  local width="${2:-50}"
  printf '%0.s'"${char}" $(seq 1 "${width}")
  echo
}

_banner_terminal_width() {
  local cols="60"
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || echo "60")"
  fi
  if ! [[ "${cols}" =~ ^[0-9]+$ ]]; then
    cols="60"
  fi
  (( cols < 30 )) && cols=30
  printf '%s\n' "${cols}"
}

_banner_repeat_char() {
  local char="${1:-═}"
  local count="${2:-0}"
  local out=""
  while (( count > 0 )); do
    out+="${char}"
    ((count--))
  done
  printf '%s' "${out}"
}

_banner_display_width() {
  local text="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    TEXT="${text}" python3 - <<'PY'
import os
import unicodedata

text = os.environ.get("TEXT", "")
width = 0
for ch in text:
    if unicodedata.combining(ch):
        continue
    width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
print(width)
PY
    return 0
  fi
  printf '%s\n' "${#text}"
}

_banner_fit_text() {
  local text="${1:-}"
  local inner_width="${2:-50}"
  local max_text_width=$(( inner_width - 2 ))

  if (( max_text_width < 4 )); then
    printf '%s\n' "${text}"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    TEXT="${text}" INNER_WIDTH="${max_text_width}" python3 - <<'PY'
import os
import unicodedata

text = os.environ.get("TEXT", "")
max_width = int(os.environ.get("INNER_WIDTH", "48"))

def width(s: str) -> int:
    total = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        total += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return total

if width(text) <= max_width:
    print(text)
else:
    out = []
    current = 0
    ellipsis_width = 3
    for ch in text:
        ch_width = 0 if unicodedata.combining(ch) else (2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1)
        if current + ch_width + ellipsis_width > max_width:
            break
        out.append(ch)
        current += ch_width
    print("".join(out) + "...")
PY
  elif (( ${#text} > max_text_width )); then
    printf '%s\n' "${text:0:$(( max_text_width - 3 ))}..."
  else
    printf '%s\n' "${text}"
  fi
}

log_box_banner() {
  local lines=("$@")
  local inner_width="50"
  local terminal_width=""
  local max_inner_width=""
  local line=""
  local fitted=""
  local left_pad=0
  local right_pad=0

  terminal_width="$(_banner_terminal_width)"
  max_inner_width=$(( terminal_width - 6 ))
  (( max_inner_width < 24 )) && max_inner_width=24

  for line in "${lines[@]}"; do
    local line_width
    line_width="$(_banner_display_width "${line}")"
    (( line_width + 4 > inner_width )) && inner_width=$(( line_width + 4 ))
  done
  (( inner_width > max_inner_width )) && inner_width="${max_inner_width}"

  echo
  echo -e "${_CLR_BOLD}${_CLR_CYAN}"
  printf '  ╔%s╗\n' "$(_banner_repeat_char "═" "${inner_width}")"
  for line in "${lines[@]}"; do
    fitted="$(_banner_fit_text "${line}" "${inner_width}")"
    local fitted_width
    fitted_width="$(_banner_display_width "${fitted}")"
    left_pad=$(( (inner_width - fitted_width) / 2 ))
    right_pad=$(( inner_width - fitted_width - left_pad ))
    printf '  ║%*s%s%*s║\n' "${left_pad}" "" "${fitted}" "${right_pad}" ""
  done
  printf '  ╚%s╝\n' "$(_banner_repeat_char "═" "${inner_width}")"
  echo -e "${_CLR_NC}"
}

log_banner() {
  log_box_banner "$1"
}
