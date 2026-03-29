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
    log_error "$(lang_pick "未检测到命令" "Missing command"): ${cmd}"
    if [[ -n "${install_hint}" ]]; then
      echo -e "  $(lang_pick "安装方法" "Install"): ${install_hint}" >&2
    fi
    return 1
  fi
  return 0
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "$(lang_pick "此操作需要 root 权限，请使用 sudo 或以 root 用户运行。" "This action requires root privileges. Please use sudo or run as root.")"
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
      log_error "$(lang_pick "无法创建目录" "Failed to create directory"): ${dir}"
      return 1
    }
  fi
}

safe_copy() {
  local src="$1"
  local dst="$2"
  if [[ -e "${src}" ]]; then
    cp -a "${src}" "${dst}" 2>/dev/null || {
      log_warn "$(lang_pick "复制失败" "Copy failed"): ${src} -> ${dst}"
      return 1
    }
    return 0
  fi

  log_debug "$(lang_pick "源不存在，跳过" "Source does not exist, skipping"): ${src}"
  return 0
}

safe_copy_dir() {
  local src="$1"
  local dst="$2"
  if [[ -d "${src}" ]]; then
    safe_mkdir "${dst}"
    cp -a "${src}/." "${dst}/" 2>/dev/null || {
      log_warn "$(lang_pick "目录复制失败" "Directory copy failed"): ${src} -> ${dst}"
      return 1
    }
    return 0
  fi

  log_debug "$(lang_pick "源目录不存在，跳过" "Source directory does not exist, skipping"): ${src}"
  return 0
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
    log_warn "$(lang_pick "未找到 sha256sum 或 shasum，跳过校验。" "sha256sum or shasum not found. Skipping checksum generation.")"
    return 1
  fi
}

verify_checksum() {
  local file="$1"
  local sum_file="${2:-${file}.sha256}"
  if [[ ! -f "${sum_file}" ]]; then
    log_warn "$(lang_pick "校验文件不存在" "Checksum file not found"): ${sum_file}"
    return 1
  fi
  local expected=""
  expected="$(awk 'NF {print $1; exit}' "${sum_file}" 2>/dev/null)"
  if [[ -z "${expected}" ]]; then
    log_warn "$(lang_pick "校验文件内容无效" "Checksum file is invalid"): ${sum_file}"
    return 1
  fi

  local actual=""
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${file}" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${file}" 2>/dev/null | awk '{print $1}')"
  else
    log_warn "$(lang_pick "未找到校验工具，跳过验证。" "Checksum tool not found. Skipping verification.")"
    return 1
  fi

  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
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
    awk -v bytes="${bytes}" 'BEGIN { printf "%.1f MB", bytes / 1048576 }'
  else
    awk -v bytes="${bytes}" 'BEGIN { printf "%.2f GB", bytes / 1073741824 }'
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

get_dir_size() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    echo "0"
    return
  fi
  if du -sb "${dir}" >/dev/null 2>&1; then
    du -sb "${dir}" 2>/dev/null | awk '{print $1}'
  else
    du -sk "${dir}" 2>/dev/null | awk '{print $1 * 1024}'
  fi
}

get_file_mode() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    echo "unknown"
    return 0
  fi
  if stat --version >/dev/null 2>&1; then
    stat -c '%a' "${path}" 2>/dev/null || echo "unknown"
  else
    stat -f '%Lp' "${path}" 2>/dev/null || echo "unknown"
  fi
}

get_file_owner_group() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    echo "unknown:unknown"
    return 0
  fi
  if stat --version >/dev/null 2>&1; then
    stat -c '%U:%G' "${path}" 2>/dev/null || echo "unknown:unknown"
  else
    stat -f '%Su:%Sg' "${path}" 2>/dev/null || echo "unknown:unknown"
  fi
}

get_primary_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "${ip}" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  fi
  if [[ -z "${ip}" ]] && command -v ifconfig >/dev/null 2>&1; then
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
  fi
  echo "${ip:-unknown}"
}

# ---------- rclone 工具 ----------
vpsmagic_extract_rclone_remote_name() {
  local remote_target="$1"
  printf '%s\n' "${remote_target%%:*}"
}

vpsmagic_rclone_remote_backend_type() {
  local remote_name="$1"
  shift

  [[ -n "${remote_name}" ]] || return 1
  command -v rclone >/dev/null 2>&1 || return 1

  local remote_cfg=""
  remote_cfg="$(rclone "$@" config show "${remote_name}" 2>/dev/null || true)"
  awk -F '=' '
    /^[[:space:]]*type[[:space:]]*=/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' <<< "${remote_cfg}"
}

vpsmagic_rclone_backend_supported() {
  local backend="$1"
  shift

  [[ -n "${backend}" ]] || return 1
  command -v rclone >/dev/null 2>&1 || return 1

  rclone "$@" help backends 2>/dev/null | awk '{print $1}' | grep -Fxq "${backend}"
}

vpsmagic_remote_uses_oci_credentials() {
  local remote_name="$1"
  shift

  if [[ "${remote_name}" =~ ^([Oo][Oo][Ss]|oci|oracle) ]]; then
    return 0
  fi

  local backend_type=""
  backend_type="$(vpsmagic_rclone_remote_backend_type "${remote_name}" "$@" 2>/dev/null || true)"
  [[ "${backend_type}" == "oracleobjectstorage" ]]
}

relative_child_path() {
  local base_dir="$1"
  local child_path="$2"

  case "${child_path}" in
    "${base_dir}")
      echo "."
      ;;
    "${base_dir}/"*)
      echo "${child_path#${base_dir}/}"
      ;;
    *)
      echo ""
      ;;
  esac
}

_archive_glob_candidates() {
  local dir="$1"
  local prefix="${2:-}"
  local out_var="$3"

  local nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob

  eval "${out_var}=()"
  if [[ -n "${prefix}" ]]; then
    eval "${out_var}+=(\"\${dir}/\${prefix}\"_*.tar.gz)"
    eval "${out_var}+=(\"\${dir}/\${prefix}\"_*.tar.gz.enc)"
  else
    eval "${out_var}+=(\"\${dir}\"/*.tar.gz)"
    eval "${out_var}+=(\"\${dir}\"/*.tar.gz.enc)"
  fi

  if (( nullglob_was_set == 0 )); then
    shopt -u nullglob
  fi
}

list_archive_files_sorted() {
  local dir="$1"
  local prefix="${2:-}"
  local order="${3:-desc}"

  local -a candidates=()
  _archive_glob_candidates "${dir}" "${prefix}" candidates
  if (( ${#candidates[@]} == 0 )); then
    return 0
  fi

  if [[ "${order}" == "asc" ]]; then
    ls -1tr "${candidates[@]}" 2>/dev/null || true
  else
    ls -1t "${candidates[@]}" 2>/dev/null || true
  fi
}

get_newest_archive_file() {
  local dir="$1"
  local prefix="${2:-}"
  list_archive_files_sorted "${dir}" "${prefix}" "desc" | head -1
}

get_oldest_archive_file() {
  local dir="$1"
  local prefix="${2:-}"
  list_archive_files_sorted "${dir}" "${prefix}" "asc" | head -1
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

confirm_exact() {
  local prompt="${1:-请输入确认词}"
  local expected="${2:-yes}"
  local answer=""
  read -r -p "${prompt} [${expected}]: " answer
  [[ "${answer}" == "${expected}" ]]
}

read_with_default() {
  local __var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local input=""

  if [[ -n "${default_value}" ]]; then
    read -r -p "${prompt} [$(prompt_default_label): ${default_value}]: " input
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
  local label="${3:-$(lang_pick "进度" "Progress")}"
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
  local result_var="$2"
  eval "${result_var}=()"

  # 替换换行为逗号，然后按逗号切分
  local normalized
  normalized="$(echo "${input}" | tr '\n' ',')"

  IFS=',' read -ra items <<< "${normalized}"
  for item in "${items[@]}"; do
    # trim 空白
    item="$(echo "${item}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -n "${item}" ]]; then
      eval "${result_var}+=(\"\${item}\")"
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

# ---------- 磁盘空间工具 ----------

# 获取指定路径所在磁盘的可用字节数
get_disk_avail_bytes() {
  local path="${1:-.}"
  # df -P 保证 POSIX 格式输出；取 Available 列 (第4列)
  # 单位是 1K-blocks，所以乘 1024 转字节
  local avail_kb
  avail_kb="$(df -P "${path}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "${avail_kb}" && "${avail_kb}" =~ ^[0-9]+$ ]]; then
    echo $(( avail_kb * 1024 ))
  else
    echo "0"
  fi
}

# 获取指定路径所在磁盘的总容量字节数
get_disk_total_bytes() {
  local path="${1:-.}"
  local total_kb
  total_kb="$(df -P "${path}" 2>/dev/null | awk 'NR==2 {print $2}')"
  if [[ -n "${total_kb}" && "${total_kb}" =~ ^[0-9]+$ ]]; then
    echo $(( total_kb * 1024 ))
  else
    echo "0"
  fi
}

# 备份前磁盘空间检查
# 参数: $1=备份目录路径  $2=预估需要的字节数 (可选，默认 500MB)
# 返回: 0=空间充足  1=空间不足但可继续  2=空间严重不足
check_disk_space() {
  local backup_dir="${1:-${BACKUP_ROOT}}"
  local est_bytes="${2:-524288000}"  # 默认预留 500MB
  local avail
  avail="$(get_disk_avail_bytes "${backup_dir}")"

  if (( avail == 0 )); then
    log_warn "$(lang_pick "无法检测磁盘空间" "Unable to detect disk space")"
    return 0
  fi

  local avail_human
  avail_human="$(human_size "${avail}")"

  # 严重不足：可用空间 < 100MB
  if (( avail < 104857600 )); then
    log_error "$(lang_pick "磁盘空间严重不足!" "Disk space is critically low!") $(lang_pick "可用" "Available"): ${avail_human}"
    log_error "$(lang_pick "建议" "Recommendation"): $(lang_pick "清理磁盘或减少 BACKUP_KEEP_LOCAL 值" "free disk space or lower BACKUP_KEEP_LOCAL")"
    return 2
  fi

  # 空间不足：可用空间 < 预估需要
  if (( avail < est_bytes )); then
    log_warn "$(lang_pick "磁盘空间可能不足。" "Disk space may be insufficient.") $(lang_pick "可用" "Available"): ${avail_human}, $(lang_pick "建议至少" "recommended at least"): $(human_size "${est_bytes}")"
    return 1
  fi

  log_debug "$(lang_pick "磁盘空间检查通过" "Disk space check passed"): $(lang_pick "可用" "available") ${avail_human}"
  return 0
}

# 智能推荐本地备份保留份数
# 逻辑:
#   1. 查看已有备份的平均大小，估算单份备份大小
#   2. 如果没有历史数据，使用默认预估值 (200MB)
#   3. 基于可用磁盘空间，计算能保留多少份 (保留 20% 安全余量)
#   4. 限制在 [1, 30] 范围内，给出推荐值
# 参数: $1=备份存储目录
# 输出: 推荐的保留份数
recommend_local_keep() {
  local backup_dir="${1:-${BACKUP_ROOT:-/opt/vpsmagic/backups}}"
  local archive_dir="${backup_dir}/archives"
  local avail
  avail="$(get_disk_avail_bytes "${backup_dir}")"

  # 估算单份备份大小
  local est_size=209715200  # 默认 200MB

  if [[ -d "${archive_dir}" ]]; then
    local total_size=0
    local file_count=0
    while IFS= read -r f; do
      local fsize
      fsize="$(get_file_size "${f}")"
      total_size=$(( total_size + fsize ))
      ((file_count+=1))
    done < <(find "${archive_dir}" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.gz.enc" \) -type f 2>/dev/null)

    if (( file_count > 0 )); then
      est_size=$(( total_size / file_count ))
      # 最小估算 10MB (避免除零或异常小值)
      (( est_size < 10485760 )) && est_size=10485760
    fi
  fi

  if (( avail == 0 || est_size == 0 )); then
    echo "3"
    return
  fi

  # 可用空间的 80% 用于备份（留 20% 安全余量给系统）
  local usable=$(( avail * 80 / 100 ))
  local recommended=$(( usable / est_size ))

  # 限制范围: 最少 1 份，最多 30 份
  (( recommended < 1 )) && recommended=1
  (( recommended > 30 )) && recommended=30

  echo "${recommended}"
}
