#!/usr/bin/env bash
# ============================================================
# VPS Magic Backup — 一键安装脚本
# 在新 VPS 上运行此脚本以安装 VPSMagic 及其依赖
#
# 用法:
#   curl -sSL https://raw.githubusercontent.com/your/VPSMagicBackup/main/install.sh | bash
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

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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

  info "安装 ${pkg}..."
  case "${pm}" in
    apt) apt-get update -qq && apt-get install -y -qq "${pkg}" ;;
    dnf) dnf install -y -q "${pkg}" ;;
    yum) yum install -y -q "${pkg}" ;;
    apk) apk add --quiet "${pkg}" ;;
    *) error "未知包管理器，请手动安装 ${pkg}"; return 1 ;;
  esac
}

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    success "rclone 已安装: $(rclone version 2>/dev/null | head -1)"
    return 0
  fi

  info "安装 rclone..."
  if curl -sSL https://rclone.org/install.sh | bash 2>/dev/null; then
    success "rclone 安装成功"
  else
    error "rclone 自动安装失败。"
    echo "  请手动安装: https://rclone.org/install.sh"
    return 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    success "Docker 已安装: $(docker --version 2>/dev/null)"
    return 0
  fi

  echo
  echo -e "${BOLD}Docker 未安装。${NC}"
  echo "  Docker 不是必须的，但如果你的 VPS 使用 Docker 部署服务，建议安装。"
  echo

  local answer=""
  read -r -p "是否安装 Docker？[y/N]: " answer
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    warn "跳过 Docker 安装。"
    return 0
  fi

  info "安装 Docker..."
  if curl -sSL https://get.docker.com | sh 2>/dev/null; then
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    success "Docker 安装成功"
  else
    error "Docker 自动安装失败。"
    echo "  请手动安装: https://docs.docker.com/engine/install/"
  fi
}

# ---------- 主安装流程 ----------
main() {
  echo
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║          VPS Magic Backup — 安装向导             ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"

  # 检查 root
  if [[ "$(id -u)" -ne 0 ]]; then
    error "请以 root 用户运行此脚本: sudo bash install.sh"
    exit 1
  fi

  local OS
  OS="$(detect_os)"
  info "检测操作系统: ${OS}"

  # ---- 第1步: 安装基础依赖 ----
  echo
  echo -e "${BOLD}第1步: 检查基础依赖${NC}"

  local base_deps=("curl" "tar" "gzip")
  for dep in "${base_deps[@]}"; do
    if command -v "${dep}" >/dev/null 2>&1; then
      success "${dep} ✓"
    else
      install_package "${dep}"
    fi
  done

  # bc (用于大小格式化)
  if ! command -v bc >/dev/null 2>&1; then
    install_package "bc" 2>/dev/null || warn "bc 安装失败 (非关键)"
  fi

  # ---- 第2步: 安装 rclone ----
  echo
  echo -e "${BOLD}第2步: 安装 rclone${NC}"
  install_rclone

  # ---- 第3步: 安装 Docker (可选) ----
  echo
  echo -e "${BOLD}第3步: Docker (可选)${NC}"
  install_docker

  # ---- 第4步: 安装 VPSMagic ----
  echo
  echo -e "${BOLD}第4步: 安装 VPS Magic Backup${NC}"

  # 判断是从 Git 克隆还是本地安装
  local source_dir=""
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -f "${script_dir}/vpsmagic.sh" ]]; then
    source_dir="${script_dir}"
    info "使用本地文件: ${source_dir}"
  else
    info "从 GitHub 克隆..."
    if command -v git >/dev/null 2>&1; then
      git clone https://github.com/your/VPSMagicBackup.git "${INSTALL_DIR}" 2>/dev/null || {
        error "Git 克隆失败。请手动下载并解压到 ${INSTALL_DIR}"
        exit 1
      }
      source_dir="${INSTALL_DIR}"
    else
      install_package "git"
      git clone https://github.com/your/VPSMagicBackup.git "${INSTALL_DIR}" 2>/dev/null
      source_dir="${INSTALL_DIR}"
    fi
  fi

  # 复制文件到安装目录
  if [[ "${source_dir}" != "${INSTALL_DIR}" ]]; then
    mkdir -p "${INSTALL_DIR}"
    cp -a "${source_dir}/." "${INSTALL_DIR}/"
    info "已复制文件到: ${INSTALL_DIR}"
  fi

  # 设置权限
  chmod +x "${INSTALL_DIR}/vpsmagic.sh"
  chmod +x "${INSTALL_DIR}/install.sh"

  # 创建 symlink
  ln -sf "${INSTALL_DIR}/vpsmagic.sh" "${BIN_LINK}"
  success "已创建命令: ${BIN_LINK}"

  # 创建备份目录
  mkdir -p /opt/vpsmagic/backups
  chmod 700 /opt/vpsmagic/backups

  # ---- 第5步: 初始化配置 ----
  echo
  echo -e "${BOLD}第5步: 配置${NC}"

  if [[ ! -f "${INSTALL_DIR}/config.env" ]]; then
    local answer=""
    read -r -p "是否现在创建配置文件？[Y/n]: " answer
    answer="${answer:-y}"
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      bash "${INSTALL_DIR}/vpsmagic.sh" init
    else
      cp "${INSTALL_DIR}/config.example.env" "${INSTALL_DIR}/config.env"
      chmod 600 "${INSTALL_DIR}/config.env"
      warn "已复制配置模板到 ${INSTALL_DIR}/config.env，请手动编辑。"
    fi
  else
    info "配置文件已存在: ${INSTALL_DIR}/config.env"
  fi

  # ---- 完成 ----
  echo
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║              安装完成! 🎉                       ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo
  echo "  快速开始:"
  echo "    1. 配置 rclone 远端:  rclone config"
  echo "    2. 编辑配置文件:      vim ${INSTALL_DIR}/config.env"
  echo "    3. 测试备份 (模拟):   vpsmagic backup --dry-run"
  echo "    4. 执行真实备份:      vpsmagic backup"
  echo "    5. 安装定时备份:      vpsmagic schedule install"
  echo
  echo "  恢复命令 (在新 VPS 上):"
  echo "    vpsmagic restore"
  echo
  echo "  在线迁移 (从源 VPS 执行):"
  echo "    vpsmagic migrate root@new-vps"
  echo
  echo "  更多帮助:  vpsmagic help"
  echo
}

main "$@"
