#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 工具函数库
# ============================================================

[[ -n "${_VPSMAGIC_UTILS_LOADED:-}" ]] && return 0
_VPSMAGIC_UTILS_LOADED=1

# ---------- 环境检测 ----------
require_cmd() {
  local cmd="$1"
  local install_hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "未检测到命令: ${cmd}"
    if [[ -n "${install_hint}" ]]; then
      echo -e "  安装方法: ${install_hint}" >&2
    fi
    return 1
  fi
  return 0
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "此操作需要 root 权限，请使用 sudo 或以 root 用户运行。"
    exit 1
  fi
}

is_linux() {
  [[ "$(uname -s)" == "Linux" ]]
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "${ID}"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/redhat-release ]]; then
    echo "centos"
  else
    echo "unknown"
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  else
    echo "unknown"
  fi
}

# ---------- 文件操作 ----------
safe_mkdir() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}" || {
      log_error "无法创建目录: ${dir}"
      return 1
    }
  fi
}

safe_copy() {
  local src="$1"
  local dst="$2"
  if [[ -e "${src}" ]]; then
    cp -a "${src}" "${dst}" 2>/dev/null || {
      log_warn "复制失败: ${src} -> ${dst}"
      return 1
    }
    return 0
  else
    log_debug "源不存在，跳过: ${src}"
    return 1
  fi
}

safe_copy_dir() {
  local src="$1"
  local dst="$2"
  if [[ -d "${src}" ]]; then
    safe_mkdir "${dst}"
    cp -a "${src}/." "${dst}/" 2>/dev/null || {
      log_warn "目录复制失败: ${src} -> ${dst}"
      return 1
    }
    return 0
  else
    log_debug "源目录不存在，跳过: ${src}"
    return 1
  fi
}

# ---------- 校验 ----------
checksum_file() {
  local file="$1"
  local sum_file="${2:-${file}.sha256}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" > "${sum_file}"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" > "${sum_file}"
  else
    log_warn "未找到 sha256sum 或 shasum，跳过校验。"
    return 1
  fi
}

verify_checksum() {
  local file="$1"
  local sum_file="${2:-${file}.sha256}"
  if [[ ! -f "${sum_file}" ]]; then
    log_warn "校验文件不存在: ${sum_file}"
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${sum_file}" --quiet 2>/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "${sum_file}" --quiet 2>/dev/null
  else
    log_warn "未找到校验工具，跳过验证。"
    return 1
  fi
}

# ---------- 加密/解密 (可选) ----------
encrypt_file() {
  local input="$1"
  local output="$2"
  local passphrase="$3"
  if ! require_cmd "openssl"; then return 1; fi
  openssl enc -aes-256-cbc -salt -pbkdf2 -in "${input}" -out "${output}" -pass "pass:${passphrase}" 2>/dev/null
}

decrypt_file() {
  local input="$1"
  local output="$2"
  local passphrase="$3"
  if ! require_cmd "openssl"; then return 1; fi
  openssl enc -aes-256-cbc -d -salt -pbkdf2 -in "${input}" -out "${output}" -pass "pass:${passphrase}" 2>/dev/null
}

# ---------- 格式化 ----------
human_size() {
  local bytes="${1:-0}"
  if (( bytes < 1024 )); then
    echo "${bytes} B"
  elif (( bytes < 1048576 )); then
    echo "$(( bytes / 1024 )) KB"
  elif (( bytes < 1073741824 )); then
    printf "%.1f MB" "$(echo "scale=1; ${bytes}/1048576" | bc 2>/dev/null || echo "${bytes}")"
  else
    printf "%.2f GB" "$(echo "scale=2; ${bytes}/1073741824" | bc 2>/dev/null || echo "${bytes}")"
  fi
}

elapsed_time() {
  local start="$1"
  local end="${2:-$(date +%s)}"
  local diff=$(( end - start ))
  if (( diff < 60 )); then
    echo "${diff}s"
  elif (( diff < 3600 )); then
    echo "$(( diff / 60 ))m $(( diff % 60 ))s"
  else
    echo "$(( diff / 3600 ))h $(( (diff % 3600) / 60 ))m"
  fi
}

get_file_size() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "0"
    return
  fi
  if stat --version >/dev/null 2>&1; then
    # GNU stat
    stat -c%s "${file}" 2>/dev/null || echo "0"
  else
    # BSD stat (macOS)
    stat -f%z "${file}" 2>/dev/null || echo "0"
  fi
}

# ---------- 交互式工具 ----------
confirm() {
  local prompt="${1:-确认继续？}"
  local default="${2:-y}"
  local answer=""
  local hint="[y/N]"

  if [[ "${default}" =~ ^[Yy]$ ]]; then
    hint="[Y/n]"
  fi

  read -r -p "${prompt} ${hint}: " answer
  answer="${answer:-${default}}"
  [[ "${answer}" =~ ^[Yy]$ ]]
}

read_with_default() {
  local __var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local input=""

  if [[ -n "${default_value}" ]]; then
    read -r -p "${prompt} [默认: ${default_value}]: " input
  else
    read -r -p "${prompt}: " input
  fi

  input="${input:-${default_value}}"
  printf -v "${__var_name}" '%s' "${input}"
}

# ---------- 进度显示 ----------
show_progress() {
  local current="$1"
  local total="$2"
  local label="${3:-进度}"
  local width=30
  local pct=$(( current * 100 / total ))
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=""

  printf -v bar '%0.s█' $(seq 1 "${filled}" 2>/dev/null) || bar=""
  local spaces=""
  printf -v spaces '%0.s░' $(seq 1 "${empty}" 2>/dev/null) || spaces=""

  printf "\r  ${label}: [${bar}${spaces}] %3d%% (%d/%d)" "${pct}" "${current}" "${total}"
  if (( current == total )); then
    echo
  fi
}

# ---------- 数组/列表工具 ----------
# 将逗号分隔/换行分隔的字符串转为数组
# 用法: parse_list "a, b, c" result_array
parse_list() {
  local input="$1"
  local -n _result_arr="$2"
  _result_arr=()

  # 替换换行为逗号，然后按逗号切分
  local normalized
  normalized="$(echo "${input}" | tr '\n' ',')"

  IFS=',' read -ra items <<< "${normalized}"
  for item in "${items[@]}"; do
    # trim 空白
    item="$(echo "${item}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -n "${item}" ]]; then
      _result_arr+=("${item}")
    fi
  done
}

# 检查值是否在数组中
in_array() {
  local needle="$1"
  shift
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}
