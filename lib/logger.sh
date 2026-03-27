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

log_banner() {
  local text="$1"
  echo
  echo -e "${_CLR_BOLD}${_CLR_CYAN}"
  log_separator "═" 56
  printf "  %s\n" "${text}"
  log_separator "═" 56
  echo -e "${_CLR_NC}"
}
