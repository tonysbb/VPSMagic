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

## 🎯 设计目标与恢复标准

本项目的目标不是“把文件打包带走”，而是尽可能让**一台未知但主流部署形态的 VPS**，在备份后能被恢复到另一台空白机器上，并在**仅切换 DNS** 的前提下尽快恢复上线。

### 设计目标

1. **广适配**：面对未知服务器时，尽可能自动发现并覆盖主流部署形态，而不是只适配单一项目目录。
2. **强健壮**：遇到缺依赖、权限不足、路径异常、远端不可用时，不崩溃、不误报成功、给出明确处理动作。
3. **可上线恢复**：对已支持的主流场景，恢复完成标准应是“服务可运行”，不是“文件已落盘”。
4. **明确降级**：对暂不支持自动拉起的对象，必须在备份与恢复摘要中明确标注，不能伪装成成功。

### 适配范围

项目默认面向以下主流 VPS 部署模型：

| 部署形态 | 目标 |
|----------|------|
| Docker Compose | 自动发现、备份、恢复、拉起 |
| Systemd 服务 | 备份 unit / working directory / 关键配置，并尽量恢复启动 |
| 反向代理 | 备份 Nginx / Caddy / Apache / Traefik 配置，并在恢复后 reload |
| 数据库 | 采集 MySQL / PostgreSQL 逻辑导出与 SQLite 文件 |
| 用户环境 | 备份 dotfiles、SSH、`rclone` 配置等关键运行环境 |
| 自定义路径 | 兜底覆盖无法自动归类的重要目录 |

### 恢复等级

| 等级 | 定义 | 示例 |
|------|------|------|
| A. 自动上线 | 恢复完成后服务已拉起，仅需切换 DNS 即可上线 | Docker Compose、Systemd、反代、证书 |
| B. 半自动恢复 | 文件和配置已恢复，但需要少量人工确认或执行固定命令 | MySQL / PostgreSQL 导入、个别依赖安装 |
| C. 手动重建 | 只能恢复数据与配置线索，无法承诺自动拉起 | 独立 Docker 容器、强依赖外部人工凭据的场景 |

项目的默认方向是：**尽量把更多常见场景推进到 A 级**，至少要把无法自动恢复的对象明确降级为 B / C 级。

### 恢复验收标准

对目标为“A 级自动上线”的模块，恢复完成后至少应满足：

1. 配置文件已恢复到正确位置
2. 依赖数据已恢复到正确位置
3. 服务已启动或已执行自动拉起动作
4. 关键端口 / 关键进程 / 容器状态可验证
5. 结果摘要真实反映成功、警告、失败和手动项

### 远端恢复原则

- 如果**源服务器和目标服务器都能访问同一个备份存储**，可直接使用 `vpsmagic restore` 远端恢复。
- 如果**目标服务器无法访问源服务器所用 remote**，应先将 `.tar.gz` 与 `.sha256` 手动传到目标服务器，再执行 `vpsmagic restore --local <file>`。
- 如果恢复包内包含 `root/.config/rclone`、OpenList / Compose / Systemd 等相关模块，那么**恢复完成后**目标机才可能重新具备与源机相同的本地 remote 条件；这不能替代第一次恢复前的可达性要求。

### 当前已知缺口与优先级

| 优先级 | 缺口 | 说明 |
|--------|------|------|
| P0 | 恢复后健康检查不足 | 当前更多是“恢复动作完成”，还缺少端口 / 容器 / 服务级验收 |
| P0 | 独立容器仍非自动恢复 | 目前仅恢复数据并给出重建提示，不满足 A 级目标 |
| P1 | 自动发现覆盖率仍需提升 | 面对未知 VPS，仍有漏检风险，需继续增强 Compose / 服务 / 数据目录发现 |
| P1 | 恢复摘要需持续收紧 | 对半自动、手动项必须持续避免误标为 `ok` |
| P2 | 英文化与跨平台细节仍在补齐 | 不阻塞主链路，但影响一致性与可运维性 |

后续联调与改进，均应以本节标准作为验收基线。

## ✅ 最近联调结论与迁移注意事项

以下结论来自一轮真实的跨机恢复联调：源机与接近空机状态的目标机之间，实际验证了 `openlist`、`aria2`、`pdfmaker`、`caddy`、`rclone`、`downnow-bot` 等链路。

### 已验证通过的恢复能力

1. **SSH 不锁死**
   - 恢复前会记录目标机当前 SSH 监听端口
   - 恢复防火墙后会优先保活该端口
   - 恢复 `user_home` 时会保留目标机现有 `authorized_keys`，避免把源机登录入口覆盖到目标机

2. **空机恢复后可自动拉起主业务**
   - `Docker Compose` 项目可自动恢复并启动
   - `Caddy` 可在干净 APT 环境中自动补仓库、安装并拉起
   - `rclone` 配置可恢复，缺失时会尝试自动安装 `rclone`
   - Python `venv` 与依赖恢复已做兼容处理，可过滤无效冻结项并自动补 `pip/setuptools/wheel`

3. **反向代理跟随源机真实状态**
   - 恢复时只会自动拉起源机真实启用的反向代理
   - 不会因为历史残留配置把目标机错误带成 `apache2`

4. **恢复摘要与健康检查已收紧**
   - 会检查 Compose 运行数、端口监听、反向代理、`rclone`
   - 新增 `Compose 出网` 检查，避免把容器网络故障误判成挂载或 token 故障

### 当前推荐的迁移切换流程

1. 在源机完成一次最新备份
2. 在目标机执行 `vpsmagic restore` 或 `vpsmagic restore --local`
3. 先验证：
   - Compose 容器是否全部 `running`
   - `caddy` 是否 `active`
   - `80/443` 是否监听
   - `rclone listremotes` 是否可用
4. 再切 DNS
5. 对单实例服务，最后执行人工切换

### 仍需人工参与的事项

1. **单实例 Systemd 服务**
   - 典型如 Telegram 轮询 bot
   - 恢复时默认只恢复，不自动启动
   - 切换时应先停源机，再启目标机

   ```bash
   # 源机
   systemctl stop downnow-bot

   # 目标机
   systemctl start downnow-bot
   journalctl -u downnow-bot -n 30 --no-pager
   ```

2. **DNS 切换后的证书签发窗口**
   - `caddy` 首次在目标机申请证书时，Cloudflare 场景下可能短暂出现 `525 SSL handshake failed`
   - 应先查看 `journalctl -u caddy`，确认 ACME 挑战是否已成功
   - 本轮联调中，`pan.shechu.top` 与 `pdf.shechu.top` 在证书签发完成后恢复正常访问

### 这轮联调踩到的关键坑

1. **不要把“前台 502 / 挂载像失效 / bot 上传异常”直接等同于 token 或挂载故障**
   - 本轮中出现过：
     - `openlist` 进程正常
     - `5244` 正常监听
     - 宿主机可访问外部 HTTPS
     - 但容器内访问外部 HTTPS 全超时
   - 这类情况的根因是 Docker bridge 出网异常，不是挂载本身失效

2. **恢复顺序会影响 Docker 出网**
   - 如果先启动 Compose，再恢复防火墙，后者可能覆盖 Docker 写入的转发/NAT 规则
   - 现已调整为：**先恢复防火墙，再恢复 Compose**

3. **迁移后旧默认网络和旧任务会污染判断**
   - 现已在 Compose 恢复前主动：
     - `docker compose down --remove-orphans`
     - 删除 `${project}_default`
     - `docker compose up -d --force-recreate`
   - 同时新增 `健康检查 / Compose 出网`

### 当前可接受的验收标准

如果恢复摘要同时满足以下条件，可认为主业务恢复已基本达标：

- `Restore Docker Compose: restored`
- `健康检查 / Docker Compose: ... running`
- `健康检查 / Compose 端口: ...`
- `健康检查 / Compose 出网: ... ok`
- `健康检查 / 反向代理: caddy: active`
- `健康检查 / 代理端口: 80,443`
- `健康检查 / rclone: ... remotes available`
- `Warnings: 0`

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

如果**源服务器和目标服务器都能访问同一个备份存储**，可以直接执行 `vpsmagic restore` 从远端拉取备份。  
如果**目标服务器无法访问源服务器使用的 remote**，请先把 `.tar.gz` 和对应 `.sha256` 文件手动传到目标服务器，再执行：

```bash
vpsmagic restore --local /path/to/backup.tar.gz
```

远端恢复开始前，工具会先做一轮**远端恢复前置检查**，至少包括：
- `rclone remote` 是否存在
- `OCI` 目标所需的 `/root/.oci/config` 是否存在
- 若全部远端都不满足条件，会在真正查询备份前直接结束，并提示改用 `restore --local`

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
| `BACKUP_PRIMARY_TARGET` | (可选) | 备份/恢复交互默认选中的主目标，例如 `OOS:mybucket/vpsmagic/{hostname}` |
| `BACKUP_ASYNC_TARGET` | (可选) | 备份完成后异步复制一份的目标，例如 `R2:mybucket/vpsmagic/{hostname}` |
| `BACKUP_INTERACTIVE_TARGETS` | `true` | 备份/恢复前是否先列出可选远端路径并允许用户交互选择 |
| `RESTORE_ROLLBACK_ON_FAILURE` | `false` | `restore --rollback-on-failure` 的默认行为开关；开启后恢复失败将自动执行轻量回滚 |
| `RESTORE_SOURCE_HOSTNAME` | (可选) | 跨机恢复时用于展开 `{hostname}` 的源主机名，例如 `NCPDE` |
| `RCLONE_REMOTE` | (兼容旧配置) | 单一路径，未设置 `BACKUP_TARGETS` 时使用 |
| `BACKUP_ROOT` | `/opt/vpsmagic/backups` | 本地备份目录 |
| `BACKUP_KEEP_LOCAL` | `3` | 本地保留份数 |
| `BACKUP_KEEP_REMOTE` | `30` | 远端保留份数 |
| `BACKUP_DESTINATION` | `remote` | 默认备份模式，可选 `remote` 或 `local` |
| `BACKUP_ENCRYPTION_KEY` | (空) | AES-256 加密密钥，留空不加密 |
| `UI_LANG` | `zh` | 界面语言，可选 `zh` 或 `en` |

### 当前行为说明

- 备份总是先执行本地归档。
- 交互模式下会先询问是否启用云端备份。
- 云端备份会列出 `BACKUP_TARGETS` 中的完整远端路径，默认选中 `BACKUP_PRIMARY_TARGET`。
- 主目标上传为同步阻塞模式，成功后会异步复制一份到 `BACKUP_ASYNC_TARGET`。
- 主目标和异步目标都会上传归档文件及对应的 `.sha256` 校验文件。
- 备份开始前会检查上一次异步副本状态；如果上次异步任务失败，会打印告警。
- 远端路径支持 `{hostname}` 占位符，运行时展开为当前机器 hostname。
- 跨机恢复时，可通过 `RESTORE_SOURCE_HOSTNAME` 或 `restore --source-hostname <源主机名>`，让恢复阶段按源主机名展开 `{hostname}`。
- 恢复默认先查本地备份，存在时默认选最新。
- 本地已有备份时，可在列表中输入 `0` 主动切换到云端搜索。
- 切到云端恢复后，会先统一打印一轮“远端恢复前置检查”结果。
- 云端恢复默认先查 `BACKUP_PRIMARY_TARGET`；如果主目标访问失败或没有备份，再回退到其他候选目标。
- 云端恢复会在真正查询前先检查 `rclone` remote 是否存在；`OCI` 目标还会预检查本机 `/root/.oci/config`。
- 远端恢复会先下载归档与 `.sha256`，再执行校验。
- 如果本地已存在同名归档，恢复会先比对远端 `.sha256`；一致时直接复用本地文件，不再重复询问是否覆盖下载。
- 恢复前必须输入精确的 `yes` 才会开始执行。
- 恢复前会创建轻量快照；恢复失败后不会立即回滚，而是在整轮恢复和健康检查结束后再判断。
- 默认不自动回滚；可通过 `restore --rollback-on-failure` 在无人值守场景下视同强确认，失败后自动执行轻量回滚。

### 已知问题

- 远端恢复前虽然已加入 `rclone remote` 和 `OCI` 凭据预检查，并会给出复制/本地恢复指引，但工具仍不会自动生成 `rclone.conf` 或 `/root/.oci/config`。首次空机远端恢复前，目标机仍需具备这些前置凭据。
- 轻量回滚仅覆盖配置级内容，例如反代、systemd、cron、防火墙规则和 compose 配置；不承诺回滚卷数据、数据库导入结果或业务副作用。
- Docker / Compose 自动安装目前主要覆盖 Debian / Ubuntu 路径，其他发行版仍属于尽力而为。
- 当前使用的 `git-deploy` 推送脚本内部是 `git add .`，会把未跟踪文件一起提交，使用时需要额外注意工作区干净度。

### Oracle Object Storage 建议

- 推荐将 Oracle Object Storage 配置成 `rclone` 的 S3 兼容 remote，然后直接上传。
- 不建议把对象存储默认 `mount` 成文件系统后再做备份，这会增加稳定性和权限问题。
- 推荐在 `BACKUP_TARGETS` / `BACKUP_PRIMARY_TARGET` / `BACKUP_ASYNC_TARGET` 中填写完整路径，并使用 `{hostname}` 占位符避免跨主机写死路径。
- 典型用法：`vpsmagic backup --remote oracle_s3:bucket-name/vpsmagic/{hostname}`

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
