# VPS Magic Backup

一套 Bash 脚本工具，面向个人/小团队 VPS 运维场景，实现 **一键备份所有服务 → 推送 WebDAV/GDrive 异地存储 → VPS 故障后在新机器上快速恢复** 的完整灾备链路。支持 **在线迁移** — 两台 VPS 都正常时通过 SSH 直接推送并恢复。

## ✨ 特性

- 📦 **全量备份**：Docker Compose / 独立容器 / Systemd 服务 / 反代配置 / 数据库 / SSL 证书 / Crontab / 防火墙 / 用户目录 / 自定义路径
- ☁️ **异地推送**：通过 rclone 上传至 WebDAV (OpenList)、Google Drive、OneDrive、S3/Oracle Object Storage 等 40+ 存储后端
- 🔄 **一键恢复**：在新 VPS 上拉取最新备份，自动还原主要服务并重新启动（独立容器提供重建清单）
- 🔐 **安全可靠**：AES-256 可选加密 · SHA256 完整性校验 · 配置文件权限保护
- 🚀 **在线迁移**：两台 VPS 都在线时，通过 SSH 直推备份并自动恢复，无需绕路云存储
- ⏰ **定时调度**：cron 自动备份，Telegram 通知结果
- 🧩 **模块化架构**：10 个采集器独立开关，按需启用
- 🎯 **入门友好**：交互式配置向导，dry-run 模拟模式，详细的中文日志

## 📁 项目结构

```
VPSMagicBackup/
├── vpsmagic.sh              # 主入口脚本
├── config.example.env       # 配置模板 (详细注释)
├── install.sh               # 一键安装脚本
├── lib/                     # 共用库
│   ├── config.sh            # 配置加载与校验
│   ├── logger.sh            # 日志输出
│   ├── notify.sh            # Telegram 通知
│   └── utils.sh             # 工具函数
├── collectors/              # 备份采集器
│   ├── docker_compose.sh    # Docker Compose 项目
│   ├── docker_standalone.sh # 独立 Docker 容器
│   ├── systemd_service.sh   # Systemd 服务
│   ├── reverse_proxy.sh     # Nginx/Caddy/Apache/Traefik
│   ├── database.sh          # MySQL/PostgreSQL/SQLite
│   ├── ssl_certs.sh         # Let's Encrypt / acme.sh
│   ├── crontab.sh           # Crontab + systemd timers
│   ├── firewall.sh          # UFW/iptables/nftables/firewalld/fail2ban
│   ├── user_home.sh         # 用户目录 (dotfiles/SSH keys)
│   └── custom_paths.sh      # 自定义路径
├── modules/                 # 功能模块
│   ├── backup.sh            # 备份总控
│   ├── upload.sh            # rclone 上传 + 轮转
│   ├── restore.sh           # 恢复总控 (远端 + 本地文件)
│   ├── migrate.sh           # 在线迁移 (VPS → VPS)
│   └── schedule.sh          # cron 调度管理
└── README.md
```

## 🚀 快速开始

### 1. 安装

```bash
# 方式一：一键安装 (在 VPS 上以 root 运行)
curl -sSL https://raw.githubusercontent.com/tonysbb/VPSMagic/main/install.sh | bash

# 方式二：手动安装
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
cd /opt/vpsmagic
bash install.sh
```

### 2. 配置 rclone 远端

```bash
# 安装 rclone (如果还没有)
curl https://rclone.org/install.sh | sudo bash

# 配置远端存储
rclone config
# 按提示添加 WebDAV / Google Drive 等
```

<details>
<summary>📖 WebDAV (OpenList/AList) 配置示例</summary>

```
rclone config
> n          # 新建 remote
> openlist   # 名称
> webdav     # 类型
> https://your-domain.com/dav   # URL
> other      # vendor
> username   # 用户名
> password   # 密码

# 测试连接
rclone lsd openlist:
```
</details>

<details>
<summary>📖 Google Drive 配置示例</summary>

```
rclone config
> n          # 新建 remote
> gdrive     # 名称
> drive      # 类型
# 按提示完成 OAuth 认证

# 测试
rclone lsd gdrive:
```
</details>

### 3. 初始化配置

```bash
# 交互式配置向导
vpsmagic init

# 或手动编辑
cp /opt/vpsmagic/config.example.env /opt/vpsmagic/config.env
vim /opt/vpsmagic/config.env
```

### 4. 执行备份

```bash
# 先用 dry-run 测试
vpsmagic backup --dry-run

# 执行真实备份
vpsmagic backup

# 仅做本地归档，不上传远端
vpsmagic backup --dest local

# 本次临时上传到指定远端
vpsmagic backup --remote oracle_s3:bucket-name/vps1

# 临时切换英文界面
vpsmagic status --lang en
```

### 5. 设置自动备份

```bash
# 安装定时任务 (默认每天凌晨3点)
vpsmagic schedule install

# 查看调度状态
vpsmagic schedule status
```

## 📋 命令参考

| 命令 | 说明 |
|------|------|
| `vpsmagic backup` | 执行全量备份 (采集 + 打包 + 上传) |
| `vpsmagic backup --dest local` | 仅做本地归档，不上传远端 |
| `vpsmagic backup --remote <rclone:path>` | 本次临时上传到指定远端 |
| `vpsmagic upload` | 仅上传最新的本地备份到远端 |
| `vpsmagic restore` | 从远端下载并恢复备份 |
| `vpsmagic restore --local <path>` | 从本地文件恢复备份 |
| `vpsmagic migrate user@host` | 在线迁移到另一台 VPS |
| `vpsmagic schedule install` | 安装定时备份 cron 任务 |
| `vpsmagic schedule remove` | 移除定时任务 |
| `vpsmagic schedule status` | 查看调度状态和最近执行记录 |
| `vpsmagic status` | 系统状态概览 (依赖/配置/备份) |
| `vpsmagic init` | 交互式创建配置文件 |
| `vpsmagic help` | 显示帮助信息 |

### 全局选项

| 选项 | 说明 |
|------|------|
| `--config <path>` | 指定配置文件路径 |
| `--dry-run` | 模拟运行，不执行实际操作 |
| `--dest <local|remote>` | 选择本次备份目标模式 |
| `--remote <path>` | 指定本次执行使用的远端路径 |
| `--lang <zh|en>` | 指定本次执行的界面语言 |
| `--verbose` | 显示详细调试信息 |
| `--version`, `-v` | 显示版本号 |

## 🔄 灾难恢复 (在新 VPS 上)

当你的 VPS 出现故障，需要在另一台上快速恢复时：

```bash
# 1. 安装基础工具
apt update && apt install -y curl git

# 2. 安装 VPSMagic 及依赖
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
bash /opt/vpsmagic/install.sh

# 3. 配置 rclone (指向你的 WebDAV/GDrive)
rclone config

# 4. 编辑配置 (优先填写 BACKUP_TARGETS，旧版可继续用 RCLONE_REMOTE)
vim /opt/vpsmagic/config.env

# 5. 一键恢复
vpsmagic restore
```

恢复流程会：
1. 列出远端所有可用备份
2. 用户选择要恢复的版本
3. 下载并校验 SHA256
4. 解密（如果加密了）
5. 按模块逐一还原配置和数据
6. 自动启动 Docker Compose 和 Systemd 服务（独立容器会给出重建提示）

预计恢复时间：**10-30 分钟**（取决于服务数量和网络带宽）。

## 🚀 在线迁移 (VPS → VPS)

当两台 VPS **都正常运行**时（换机、升配、换线路等），无需绕路云存储，直接推送：

```bash
# 前提: 已在源机配好到目标机的 SSH 密钥认证
ssh-copy-id root@new-vps

# 一键迁移 (采集 → 打包 → SSH 推送 → 远程恢复)
vpsmagic migrate root@new-vps

# 指定端口和带宽限制
vpsmagic migrate root@new-vps -p 2222 --bwlimit 10m

# 仅推送不恢复 (想在目标机手动检查后再恢复)
vpsmagic migrate root@new-vps --skip-restore
# 然后在目标机上手动恢复:
# vpsmagic restore --local /opt/vpsmagic/backups/restore/xxx.tar.gz
```

### migrate vs restore 对比

| 场景 | 推荐命令 | 说明 |
|------|---------|------|
| 源机已挂 / 灾备恢复 | `vpsmagic restore` | 从云存储下载恢复 |
| 两台都在线 / 计划迁移 | `vpsmagic migrate` | SSH 直推，速度快一倍 |
| 目标机有备份文件 | `vpsmagic restore --local` | 本地文件恢复 |

## ⚙️ 配置说明

默认上传优先级：`gdrive` -> `onedrive` -> `openlist_webdav`。
如果你的 remote 名称不同，直接显式设置 `BACKUP_TARGETS`。

### 核心配置

| 配置项 | 默认值 | 说明 |
|--------|---------|------|
| `BACKUP_TARGETS` | (推荐) | 逗号分隔的远端优先级列表，例如 `gdrive:VPSBackup/vps1,onedrive:VPSBackup/vps1,openlist_webdav:139Cloud/backup/vps1` |
| `RCLONE_REMOTE` | (兼容旧配置) | 单一路径，未设置 `BACKUP_TARGETS` 时使用 |
| `BACKUP_ROOT` | `/opt/vpsmagic/backups` | 本地备份目录 |
| `BACKUP_KEEP_LOCAL` | `3` | 本地保留份数 |
| `BACKUP_KEEP_REMOTE` | `30` | 远端保留份数 |
| `BACKUP_DESTINATION` | `remote` | 默认备份模式，可选 `remote` 或 `local` |
| `BACKUP_ENCRYPTION_KEY` | (空) | AES-256 加密密钥，留空不加密 |
| `UI_LANG` | `zh` | 界面语言，可选 `zh` 或 `en` |

### Oracle Object Storage 建议

- 推荐将 Oracle Object Storage 配置成 `rclone` 的 S3 兼容 remote，然后直接上传。
- 不建议把对象存储默认 `mount` 成文件系统后再做备份，这会增加稳定性和权限问题。
- 典型用法：`vpsmagic backup --remote oracle_s3:bucket-name/vps1`

### Rsync 说明

- `rsync` 不是主备份格式替代品，更适合做迁移提速和大目录预同步。
- 安装 `rsync` 后，`vpsmagic migrate` 会优先使用 `rsync`，否则回退为 `scp`。
- 预同步示例：`rsync -avz /opt/data/ root@standby:/opt/data/`

### 备份模块开关

每个模块可独立启用/禁用：

| 模块 | 配置项 | 备份内容 |
|------|--------|----------|
| Docker Compose | `ENABLE_DOCKER_COMPOSE` | compose 文件、.env、卷数据、镜像清单 |
| 独立容器 | `ENABLE_DOCKER_STANDALONE` | inspect 配置、卷数据（恢复时按清单手动重建） |
| Systemd | `ENABLE_SYSTEMD` | .service 文件、程序目录、工作目录 |
| 反向代理 | `ENABLE_REVERSE_PROXY` | Nginx/Caddy/Apache/Traefik 配置 |
| 数据库 | `ENABLE_DATABASE` | MySQL/PostgreSQL dump、SQLite 文件 |
| SSL 证书 | `ENABLE_SSL_CERTS` | Let's Encrypt / acme.sh 证书 |
| Crontab | `ENABLE_CRONTAB` | 用户/系统 crontab、systemd timers |
| 防火墙 | `ENABLE_FIREWALL` | UFW/iptables/nftables/firewalld 规则 |
| 用户目录 | `ENABLE_USER_HOME` | dotfiles、SSH keys、rclone 配置 |
| 自定义路径 | `ENABLE_CUSTOM_PATHS` | EXTRA_PATHS 指定的文件和目录 |

### 自动探测

设置 `COMPOSE_PROJECTS=auto` 和 `SYSTEMD_SERVICES=auto` 时，脚本会尝试自动探测：
- **Docker Compose**: 通过 `docker compose ls` 和搜索 `/opt` `/srv` `/home` `/root` 下的 compose 文件。生产环境建议显式填写 `COMPOSE_PROJECTS`，避免遗漏未运行项目或特殊目录。
- **Systemd**: 扫描 `/etc/systemd/system/` 下的自定义 `.service` 文件（排除系统默认服务）

## 🔐 安全注意事项

1. **配置文件权限**: 包含敏感信息，建议设为 `chmod 600`
2. **加密备份**: 设置 `BACKUP_ENCRYPTION_KEY` 启用 AES-256-CBC 加密
3. **root 权限**: 备份操作需要 root 访问所有服务配置
4. **SSH Keys**: `user_home` 模块仅备份 `authorized_keys` 和 `config`，不备份私钥

## 📝 版本记录

### v1.0.2 (2026-03-24)
- 🧭 兼容性修复：主入口支持通过 `/usr/local/bin/vpsmagic` 包装器稳定启动，不再依赖符号链接解析
- 🛠 可靠性修复：全仓库将危险的 `((x++))` 计数写法改为 `set -e` 安全形式，避免首次计数即退出
- 🛠 可靠性修复：`safe_copy` / `safe_copy_dir` 遇到可选文件缺失时不再中断主流程
- 🛠 可靠性修复：首次无历史归档时，备份预检不再因为 `ls` 返回码中断
- 🛠 可靠性修复：`backup --dry-run` 不再因为未实际生成归档而在上传阶段误报失败
- 🛠 可靠性修复：远端上传前增加 `rclone mkdir` 预检，并给出 OpenList / WebDAV 场景的明确路径提示
- 🧩 适配性增强：Compose 自动发现改为同时解析 `docker compose ls` 和常见部署目录，减少漏检

### v1.0.1 (2026-03-07)
- 🔒 安全修复：配置加载改为白名单安全解析，不再直接 `source` 配置文件
- 🔒 安全修复：恢复流程不再 `source` 备份内 `.env`，改为安全键值读取
- 🛠 可靠性修复：数据库自动探测与导出计数逻辑修正，避免误报成功
- 🧭 兼容性修复：移除 `grep -oP` 依赖，提升在精简系统中的兼容性
- 🐚 兼容性修复：修复 Bash 3.2 下的模块开关判断
- 🧹 文档对齐：明确独立容器恢复为“重建清单 + 手动重建”

### v1.0.0 (2026-03-07)
- 🎉 初始版本发布
- 10 个备份采集器 (Docker Compose/独立容器/Systemd/反代/数据库/SSL/Crontab/防火墙/用户目录/自定义路径)
- rclone 异地上传 + 本地/远端轮转清理
- 交互式恢复流程 + 本地文件恢复 (`--local`)
- 🚀 在线迁移功能 (`vpsmagic migrate user@host`)
- 交互式配置向导 (init)
- cron 定时备份管理
- AES-256 可选加密
- Telegram 通知
- dry-run 模拟模式

## 📜 License

MIT
