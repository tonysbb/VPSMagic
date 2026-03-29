#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 一键安装脚本
# 在新 VPS 上运行此脚本以安装 VPSMagic 及其依赖
#
# 用法:
#   curl -sSL https://raw.githubusercontent.com/tonysbb/VPSMagic/main/install.sh | bash
#   或:
#   bash install.sh
# ============================================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INSTALL_DIR="/opt/vpsmagic"
BIN_LINK="/usr/local/bin/vpsmagic"
RCLONE_MIN_VERSION="1.64.0"
RSYNC_MIN_VERSION="3.2.3"
INSTALL_LANG="${INSTALL_LANG:-${VPSMAGIC_LANG:-${UI_LANG:-${LANG:-zh}}}}"

normalize_install_lang() {
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="${raw%%.*}"
  raw="${raw%%_*}"
  raw="${raw%%-*}"
  case "${raw}" in
    en) echo "en" ;;
    *) echo "zh" ;;
  esac
}

set_install_lang() {
  INSTALL_LANG="$(normalize_install_lang "${1:-${INSTALL_LANG}}")"
}

is_install_lang_en() {
  [[ "${INSTALL_LANG}" == "en" ]]
}

lang_pick_install() {
  local zh_text="${1:-}"
  local en_text="${2:-}"
  if is_install_lang_en; then
    printf '%s' "${en_text}"
  else
    printf '%s' "${zh_text}"
  fi
}

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

confirm() {
  local prompt="${1:-$(lang_pick_install "确认继续？" "Continue?")}"
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

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        [[ $# -ge 2 ]] || { error "$(lang_pick_install "--lang 需要一个参数" "--lang requires a value")"; exit 1; }
        set_install_lang "$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
}

normalize_version() {
  local version="${1:-}"
  version="${version#v}"
  version="${version%% *}"
  version="${version%%-*}"
  printf '%s' "${version}"
}

version_ge() {
  local current
  local required
  current="$(normalize_version "${1:-0}")"
  required="$(normalize_version "${2:-0}")"

  local IFS=.
  local -a current_parts=(${current})
  local -a required_parts=(${required})
  local max_len="${#current_parts[@]}"
  if (( ${#required_parts[@]} > max_len )); then
    max_len="${#required_parts[@]}"
  fi

  local i
  for (( i=0; i<max_len; i++ )); do
    local current_num="${current_parts[i]:-0}"
    local required_num="${required_parts[i]:-0}"
    (( 10#${current_num} > 10#${required_num} )) && return 0
    (( 10#${current_num} < 10#${required_num} )) && return 1
  done
  return 0
}

detect_rclone_version() {
  rclone version 2>/dev/null | awk 'NR==1 {print $2}'
}

detect_rsync_version() {
  rsync --version 2>/dev/null | awk 'NR==1 {print $3}'
}

# ---------- 检测操作系统 ----------
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
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  else echo "unknown"; fi
}

# ---------- 安装依赖 ----------
install_package() {
  local pkg="$1"
  local pm
  pm="$(detect_pkg_manager)"

  info "$(lang_pick_install "安装" "Installing") ${pkg}..."
  case "${pm}" in
    apt) apt-get update -qq && apt-get install -y -qq "${pkg}" ;;
    dnf) dnf install -y -q "${pkg}" ;;
    yum) yum install -y -q "${pkg}" ;;
    apk) apk add --quiet "${pkg}" ;;
    *) error "$(lang_pick_install "未知包管理器，请手动安装" "Unknown package manager. Please install manually") ${pkg}"; return 1 ;;
  esac
}

ensure_minimum_version() {
  local name="$1"
  local current_version="$2"
  local minimum_version="$3"

  if version_ge "${current_version}" "${minimum_version}"; then
    success "$(lang_pick_install "${name} 版本满足要求" "${name} version satisfies the requirement"): ${current_version} (>= ${minimum_version})"
    return 0
  fi

  warn "$(lang_pick_install "${name} 版本偏旧" "${name} version is older than recommended"): ${current_version} (< ${minimum_version})"
  return 1
}

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    local current_version
    current_version="$(detect_rclone_version)"
    if ensure_minimum_version "rclone" "${current_version}" "${RCLONE_MIN_VERSION}"; then
      return 0
    fi

      if ! confirm "$(lang_pick_install "是否使用 rclone 官方安装脚本升级？" "Upgrade with the official rclone install script?")" "y"; then
        warn "$(lang_pick_install "保留当前 rclone 版本。" "Keeping the current rclone version.")"
        return 0
      fi
  fi

  info "$(lang_pick_install "通过 rclone 官方安装脚本安装/升级 rclone..." "Installing/upgrading rclone with the official install script...")"
  if curl -sSL https://rclone.org/install.sh | bash 2>/dev/null; then
    local installed_version
    installed_version="$(detect_rclone_version)"
    success "$(lang_pick_install "rclone 安装成功" "rclone installed successfully"): ${installed_version}"
  else
    error "$(lang_pick_install "rclone 自动安装失败。" "rclone automatic installation failed.")"
    echo "  $(lang_pick_install "请手动安装" "Please install manually"): https://rclone.org/install.sh"
    return 1
  fi
}

install_rsync() {
  if command -v rsync >/dev/null 2>&1; then
    local current_version
    current_version="$(detect_rsync_version)"
    if ensure_minimum_version "rsync" "${current_version}" "${RSYNC_MIN_VERSION}"; then
      return 0
    fi

      if ! confirm "$(lang_pick_install "是否尝试通过系统仓库升级 rsync？" "Try upgrading rsync from the system repository?")" "y"; then
        warn "$(lang_pick_install "保留当前 rsync 版本。" "Keeping the current rsync version.")"
        return 0
      fi
    else
    if ! confirm "$(lang_pick_install "是否安装 rsync（推荐，用于增量同步与迁移提速）？" "Install rsync (recommended for incremental sync and faster migration)?")" "y"; then
      warn "$(lang_pick_install "跳过 rsync 安装。迁移时将回退为 scp。" "Skipping rsync installation. Migration will fall back to scp.")"
      return 0
    fi
  fi

  info "$(lang_pick_install "通过系统官方仓库安装/升级 rsync..." "Installing/upgrading rsync from the system repository...")"
  install_package "rsync" || return 1

  if command -v rsync >/dev/null 2>&1; then
    success "$(lang_pick_install "rsync 已安装" "rsync installed"): $(detect_rsync_version)"
  else
    warn "$(lang_pick_install "rsync 安装后仍不可用，请手动检查。" "rsync is still unavailable after installation. Please check manually.")"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    success "$(lang_pick_install "Docker 已安装" "Docker is already installed"): $(docker --version 2>/dev/null)"
    return 0
  fi

  echo
  echo -e "${BOLD}$(lang_pick_install "Docker 未安装。" "Docker is not installed.")${NC}"
  echo "  $(lang_pick_install "Docker 不是必须的，但如果你的 VPS 使用 Docker 部署服务，建议安装。" "Docker is optional, but recommended if your VPS runs services with Docker.")"
  echo

  local answer=""
  read -r -p "$(lang_pick_install "是否安装 Docker？" "Install Docker?") [y/N]: " answer
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    warn "$(lang_pick_install "跳过 Docker 安装。" "Skipping Docker installation.")"
    return 0
  fi

  info "$(lang_pick_install "安装 Docker..." "Installing Docker...")"
  if curl -sSL https://get.docker.com | sh 2>/dev/null; then
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    success "$(lang_pick_install "Docker 安装成功" "Docker installed successfully")"
  else
    error "$(lang_pick_install "Docker 自动安装失败。" "Docker automatic installation failed.")"
    echo "  $(lang_pick_install "请手动安装" "Please install manually"): https://docs.docker.com/engine/install/"
  fi
}

# ---------- 主安装流程 ----------
main() {
  parse_install_args "$@"
  set_install_lang "${INSTALL_LANG}"
  echo
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  local install_title
  install_title="$(lang_pick_install "VPS Magic Backup — 安装向导" "VPS Magic Backup — Installation Wizard")"
  printf '  ║%50s║\n' "${install_title}"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"

  # 检查 root
  if [[ "$(id -u)" -ne 0 ]]; then
    error "$(lang_pick_install "请以 root 用户运行此脚本: sudo bash install.sh" "Please run this script as root: sudo bash install.sh")"
    exit 1
  fi

  local OS
  OS="$(detect_os)"
  info "$(lang_pick_install "检测操作系统" "Detected OS"): ${OS}"
  if [[ "${OS}" == "alpine" ]]; then
    info "$(lang_pick_install "检测到 Alpine，目标是保证 Bash 模式下兼容运行。" "Alpine detected. Target mode is Bash-compatible execution.")"
  fi

  # ---- 第1步: 安装基础依赖 ----
  echo
  echo -e "${BOLD}$(lang_pick_install "第1步: 检查基础依赖" "Step 1: Check base dependencies")${NC}"

  local base_deps=("bash" "curl" "tar" "gzip")
  for dep in "${base_deps[@]}"; do
    if command -v "${dep}" >/dev/null 2>&1; then
      success "${dep} ✓"
    else
      install_package "${dep}"
    fi
  done

  # bc (用于大小格式化)
  if ! command -v bc >/dev/null 2>&1; then
    install_package "bc" 2>/dev/null || warn "$(lang_pick_install "bc 安装失败 (非关键)" "bc installation failed (non-critical)")"
  fi

  # ---- 第2步: 安装 rclone ----
  echo
  echo -e "${BOLD}$(lang_pick_install "第2步: 安装 rclone" "Step 2: Install rclone")${NC}"
  install_rclone

  # ---- 第3步: 安装 rsync (推荐) ----
  echo
  echo -e "${BOLD}$(lang_pick_install "第3步: 安装 rsync (推荐)" "Step 3: Install rsync (recommended)")${NC}"
  install_rsync

  # ---- 第4步: 安装 Docker (可选) ----
  echo
  echo -e "${BOLD}$(lang_pick_install "第4步: Docker (可选)" "Step 4: Docker (optional)")${NC}"
  install_docker

  # ---- 第5步: 安装 VPSMagic ----
  echo
  echo -e "${BOLD}$(lang_pick_install "第5步: 安装 VPS Magic Backup" "Step 5: Install VPS Magic Backup")${NC}"

  # 判断是从 Git 克隆还是本地安装
  local source_dir=""
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -f "${script_dir}/vpsmagic.sh" ]]; then
    source_dir="${script_dir}"
    info "$(lang_pick_install "使用本地文件" "Using local files"): ${source_dir}"
  else
    info "$(lang_pick_install "从 GitHub 克隆..." "Cloning from GitHub...")"
    if command -v git >/dev/null 2>&1; then
      git clone https://github.com/tonysbb/VPSMagic.git "${INSTALL_DIR}" 2>/dev/null || {
        error "$(lang_pick_install "Git 克隆失败。请手动下载并解压到" "Git clone failed. Please download and extract it manually to") ${INSTALL_DIR}"
        exit 1
      }
      source_dir="${INSTALL_DIR}"
    else
      install_package "git"
      git clone https://github.com/tonysbb/VPSMagic.git "${INSTALL_DIR}" 2>/dev/null
      source_dir="${INSTALL_DIR}"
    fi
  fi

  # 复制文件到安装目录
  if [[ "${source_dir}" != "${INSTALL_DIR}" ]]; then
    mkdir -p "${INSTALL_DIR}"
    cp -a "${source_dir}/." "${INSTALL_DIR}/"
    info "$(lang_pick_install "已复制文件到" "Copied files to"): ${INSTALL_DIR}"
  fi

  # 设置权限
  chmod +x "${INSTALL_DIR}/vpsmagic.sh"
  chmod +x "${INSTALL_DIR}/install.sh"

  # 创建启动包装器，避免通过 symlink 启动时的脚本目录解析问题
  cat > "${BIN_LINK}" <<EOF
#!/usr/bin/env bash
exec "${INSTALL_DIR}/vpsmagic.sh" "$@"
EOF
  chmod +x "${BIN_LINK}"
  success "$(lang_pick_install "已创建命令" "Created command"): ${BIN_LINK}"

  # 创建备份目录
  mkdir -p /opt/vpsmagic/backups
  chmod 700 /opt/vpsmagic/backups

  # ---- 第6步: 初始化配置 ----
  echo
  echo -e "${BOLD}$(lang_pick_install "第6步: 配置" "Step 6: Configuration")${NC}"

  if [[ ! -f "${INSTALL_DIR}/config.env" ]]; then
    local answer=""
    read -r -p "$(lang_pick_install "是否现在创建配置文件？" "Create the config file now?") [Y/n]: " answer
    answer="${answer:-y}"
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      bash "${INSTALL_DIR}/vpsmagic.sh" init --lang "${INSTALL_LANG}"
    else
      cp "${INSTALL_DIR}/config.example.env" "${INSTALL_DIR}/config.env"
      chmod 600 "${INSTALL_DIR}/config.env"
      warn "$(lang_pick_install "已复制配置模板到" "Copied the config template to") ${INSTALL_DIR}/config.env, $(lang_pick_install "请手动编辑。" "please edit it manually.")"
    fi
  else
    info "$(lang_pick_install "配置文件已存在" "Config file already exists"): ${INSTALL_DIR}/config.env"
  fi

  # ---- 完成 ----
  echo
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  local completion_title
  completion_title="$(lang_pick_install "安装完成! 🎉" "Installation Complete!")"
  printf '  ║%50s║\n' "${completion_title}"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo
  echo "  $(lang_pick_install "快速开始" "Quick start"):"
  echo "    1. $(lang_pick_install "配置 rclone 远端" "Configure rclone remote"):  rclone config"
  echo "       $(lang_pick_install "Oracle Object Storage 可在 rclone 中选择 S3 兼容后端进行配置" "Oracle Object Storage can be configured in rclone as an S3-compatible backend")"
  echo "    2. $(lang_pick_install "编辑配置文件" "Edit config file"):      vim ${INSTALL_DIR}/config.env"
  echo "    3. $(lang_pick_install "测试备份 (模拟)" "Test backup (dry-run)"):   vpsmagic backup --dry-run --dest local"
  echo "    4. $(lang_pick_install "执行远端备份" "Run remote backup"):      vpsmagic backup --dest remote"
  echo "    5. $(lang_pick_install "安装定时备份" "Install schedule"):      vpsmagic schedule install"
  echo "    6. $(lang_pick_install "迁移/预同步提速" "Migration / pre-sync acceleration"):   rsync --version && vpsmagic migrate root@new-vps"
  echo
  echo "  $(lang_pick_install "恢复命令 (在新 VPS 上)" "Restore command (on the new VPS)"):"
  echo "    vpsmagic restore"
  echo "    $(lang_pick_install "如果源机和目标机都能访问同一个备份存储，可直接执行远端恢复。" "If both the source VPS and destination VPS can access the same backup storage, you can restore directly from remote.")"
  echo "    $(lang_pick_install "如果目标机无法访问源机使用的 remote，请先把备份文件手动传到目标机，再执行 vpsmagic restore --local <file>。" "If the destination VPS cannot access the remote used by the source VPS, copy the backup file to the destination first and run vpsmagic restore --local <file>.")"
  echo
  echo "  $(lang_pick_install "Oracle Object Storage 提示" "Oracle Object Storage notes"):"
  echo "    - $(lang_pick_install "建议直接使用 rclone remote 访问对象存储，不要默认 mount 后再备份" "Use an rclone remote directly instead of mounting object storage by default")"
  echo "    - $(lang_pick_install "配好 remote 后，将其写入 BACKUP_TARGETS 或执行 vpsmagic backup --remote <remote:path>" "After configuring the remote, put it into BACKUP_TARGETS or run vpsmagic backup --remote <remote:path>")"
  echo
  echo "  $(lang_pick_install "在线迁移 (从源 VPS 执行)" "Online migration (run on the source VPS)"):"
  echo "    vpsmagic migrate root@new-vps"
  echo
  echo "  $(lang_pick_install "更多帮助" "More help"):  vpsmagic help"
  echo
}

main "$@"
