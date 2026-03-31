# VPS Magic Backup

一套面向个人 / 小团队 VPS 运维场景的 **全栈备份与灾难恢复** Bash 工具。

不是只导出一堆文件 — 而是把一台 VPS 尽可能恢复到"可运行、可切流、可继续维护"的状态。

## ✨ 核心能力

- **10 大模块自动采集**：Docker Compose / 独立容器 / Systemd 服务 / 反向代理 / 数据库 / SSL 证书 / Crontab / 防火墙 / 用户目录 / 自定义路径
- **本地 + 云端双备份**：支持 WebDAV / S3 / Google Drive 等，支持主远端 + 异步副本，并可按优先级尝试可用目标
- **一键恢复**：空机远端恢复、自动补依赖（Docker / Compose / rclone）、健康检查
- **在线迁移**：源机直推到目标机，SSH + rsync 一条命令完成
- **定时备份**：Cron 定时 + Telegram 通知
- **中英文双语**：界面和文档同时支持

## 🚀 快速开始

### 第一步：安装

```bash
# 方式一：一键安装（推荐）
curl -sSL https://raw.githubusercontent.com/tonysbb/VPSMagic/main/install.sh | bash

# 方式二：手动安装
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
cd /opt/vpsmagic && bash install.sh
```

### 第二步：初始化配置

```bash
vpsmagic init
```

向导会让你选择：
1. **仅本地备份** — 适合先体验
2. **本地 + 云端备份** — 推荐用于生产环境
3. **仅生成配置** — 稍后手动编辑

> 💡 如果你已经有 `rclone` 和云端存储，建议直接选 `2`，一步到位。

### 第三步：执行备份

```bash
vpsmagic backup
```

### 第四步：校验备份

```bash
ls -lh /opt/vpsmagic/backups/archives
sha256sum -c /opt/vpsmagic/backups/archives/*.sha256
```

### 第五步：恢复演练

在目标机上执行（本地恢复）：

```bash
vpsmagic restore --local /path/to/backup.tar.gz
```

或从云端直接恢复（远端恢复）：

```bash
vpsmagic restore
```

> ⚠️ 建议先做一次**恢复演练**，确认流程跑通后，再用于生产切换。

## 📋 常用命令

| 命令 | 说明 |
|------|------|
| `vpsmagic init` | 交互式创建配置 |
| `vpsmagic backup` | 执行全量备份 |
| `vpsmagic backup --dest local` | 仅本地备份 |
| `vpsmagic restore` | 从远端恢复 |
| `vpsmagic restore --local <file>` | 从本地归档恢复 |
| `vpsmagic restore --source-hostname <name>` | 跨机恢复（远端路径含 `{hostname}` 时） |
| `vpsmagic restore --auto-confirm --rollback-on-failure` | 无人值守恢复 |
| `vpsmagic migrate root@new-vps` | 在线迁移到新 VPS |
| `vpsmagic doctor` | 环境诊断与风险评估 |
| `vpsmagic status` | 查看系统与备份状态 |
| `vpsmagic schedule install` | 安装定时备份 |
| `vpsmagic help` | 查看完整帮助 |

## 🏗️ 恢复等级

| 模块 | 等级 | 说明 |
|------|------|------|
| Docker Compose | A | 自动恢复并拉起，含健康检查 |
| 反向代理 | A | Caddy / Nginx / Apache / Traefik |
| Crontab / 防火墙 | A | 自动恢复并纳入快照 |
| Systemd 服务 | A/B | 保留源机 enable/running 状态 |
| 用户目录 | B | 恢复关键配置，保留目标机 SSH keys |
| 数据库 | B | 逻辑导出 + 文件恢复 |
| 独立 Docker 容器 | C | 保留重建线索，不自动拉起 |

> **A** = 自动恢复上线　**B** = 恢复后需人工确认　**C** = 保留线索，手动重建

## 📚 文档

中文文档（推荐入口）：

| 阶段 | 文档 |
|------|------|
| **第一次上手** | [零配置起步](docs/zh/零配置起步.md) — 从零完成第一次备份和恢复 |
| **日常使用** | [快速开始](docs/zh/快速开始.md) · [配置说明](docs/zh/配置说明.md) · [备份说明](docs/zh/备份说明.md) |
| **恢复与迁移** | [恢复说明](docs/zh/恢复说明.md) · [迁移说明](docs/zh/迁移说明.md) |
| **运维** | [状态说明](docs/zh/状态说明.md) · [定时任务说明](docs/zh/定时任务说明.md) · [排障说明](docs/zh/排障说明.md) |
| **参考** | [能力矩阵](docs/zh/能力矩阵.md) · [业务画像与适用场景](docs/zh/业务画像与适用场景.md) · [免责声明](docs/zh/免责声明.md) |
| **中文文档总览** | [docs/zh/README.md](docs/zh/README.md) |

English docs: [docs/en/README.md](docs/en/README.md)

## ⚠️ 项目边界

- 目标是"恢复到可运行状态"，不是完整系统镜像回放
- 轻量回滚仅覆盖配置级内容，不覆盖卷数据或业务副作用
- 远端恢复需目标机预置 `rclone.conf`（如用 OCI 还需 `/root/.oci/config`）— 这是刻意保留的安全验证门槛
- 数据库恢复不等于业务数据一致性恢复，切换前应做业务侧校验
- 非 Debian / Ubuntu 系统的自动补依赖能力相对保守

## 📄 License

MIT
