# VPS Magic Backup

一套面向个人/小团队 VPS 运维场景的 Bash 灾备工具，目标是把一台主流部署形态的 VPS 尽可能恢复到“可运行、可切流、可继续维护”的状态，而不是只导出一堆文件。

## 项目目标

- 备份主流 VPS 运行环境：Docker Compose、Systemd、反向代理、数据库、Crontab、防火墙、用户目录、自定义路径
- 支持本地恢复、远端恢复、在线迁移
- 在目标机尽可能自动补齐关键依赖，并通过健康检查收紧“恢复成功”的定义
- 对无法完全自动恢复的对象，明确标注边界，而不是误报成功

## 适用范围

适合：

- 个人项目或小团队维护的单机 VPS
- 以 Docker Compose / Systemd / Caddy / Nginx 为主的部署形态
- 既可以先只做本地备份，也可以后续升级到远端备份
- 接受“先演练、再上线”的恢复流程

不适合直接假定为全自动场景：

- 强事务一致性要求的复杂数据库集群
- 多节点编排平台（如完整 Kubernetes 集群）
- 大量外部凭据强依赖、且目标机无法预置凭据的场景
- 要求完整系统级回滚、卷数据回滚、业务副作用回滚的场景

## 如果你的服务器不是我们的实验环境

可以使用，但不要假设它会因为“不是我们之前测试过的那类机器”就失效，也不要反过来假设它一定能一键完整恢复。

正确做法是先识别这台机器属于哪种业务画像，再决定采用哪条路径：

```bash
bash vpsmagic.sh doctor
```

这个命令会先回答：

- 这台机器更像轻量通用 VPS、Compose 应用型、Systemd 服务型，还是混合 Docker 业务型
- 当前发现了哪些部署形态
- 远端前置条件是否具备
- 哪些模块更接近 A / B / C 哪一级
- 应该先从本地备份、本地恢复，还是远端恢复开始
- 当前是否存在会阻塞正式恢复的条件

如果你想把这些结果交给脚本、CI 或其他自动化工具处理，也可以使用：

```bash
bash vpsmagic.sh doctor --format json
bash vpsmagic.sh status --format json
```

其中：

- `doctor --format json` 更适合恢复前判断与风险评估
- `status --format json` 更适合读取当前机器状态、配置状态和本地/远端备份概览

字段说明可进一步参考：

- [中文状态说明](docs/zh/状态说明.md)
- [English status docs](docs/en/status.md)

建议顺序始终是：

1. 先 `doctor`
2. 先本地备份
3. 先本地恢复演练
4. 再配置远端
5. 最后才做跨机恢复 / 在线迁移

## 恢复等级矩阵

| 模块 | 当前等级 | 说明 |
|------|----------|------|
| Docker Compose | A | 可恢复并自动拉起，已补健康检查 |
| Systemd 服务 | A / B | 常见服务可恢复；单实例服务默认恢复但不自动启动 |
| 反向代理 | A | 支持 Caddy / Nginx / Apache / Traefik 配置恢复 |
| 数据库 | B | 以逻辑导出和文件恢复为主，不承诺业务一致性自动验证 |
| Crontab / 防火墙 | A | 可恢复并纳入快照与摘要 |
| 用户目录 | B | 恢复关键配置，但会保留目标机当前 `authorized_keys` |
| 独立 Docker 容器 | C | 当前以数据与线索恢复为主，不承诺自动重建 |

## 免责声明

使用本工具前，建议先接受以下工程边界：

1. 本项目默认追求“恢复到可运行状态”，不是“完整系统镜像回放”。
2. 轻量回滚仅覆盖配置级内容，不覆盖卷数据、数据库结果或业务副作用。
3. 远端恢复依赖目标机事先具备相应凭据，例如 `rclone.conf`、`/root/.oci/config`；这也是刻意保留的安全验证门槛。
4. 数据库恢复不等于业务数据一致性恢复，生产切换前仍应做业务侧校验。
5. 对未明确支持的部署形态，必须先做演练，不应直接把首次恢复结果当作上线依据。

详细说明见：[docs/zh/免责声明.md](docs/zh/免责声明.md)

## 快速开始

如果你现在：

- 没有 `rclone`
- 没有云存储
- 只想先把当前 VPS 成功备份一次

请先走“仅本地模式”。这也是本项目默认推荐的新手入口。

详细步骤见：[零配置起步](docs/zh/零配置起步.md)

### 1. 安装

```bash
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
cd /opt/vpsmagic
bash install.sh
```

### 2. 初始化本地配置

```bash
bash vpsmagic.sh init
```

如果你只是第一次使用，建议在向导里直接选择：

- `仅本地备份（推荐新手）`

向导会先让你选择界面语言，然后生成 `config.env`。

生成后，至少确认这两项：

```bash
BACKUP_DESTINATION="local"
BACKUP_ROOT="/opt/vpsmagic/backups"
```

### 3. 先执行一次本地备份

```bash
bash vpsmagic.sh backup --config /opt/vpsmagic/config.env
```

### 4. 校验本地归档

```bash
ls -lh /opt/vpsmagic/backups/archives
sha256sum -c /opt/vpsmagic/backups/archives/*.sha256
```

### 5. 在目标机恢复

```bash
bash vpsmagic.sh restore --local /path/to/backup.tar.gz --config /opt/vpsmagic/config.env
```

### 6. 以后再升级到远端备份

当你已经跑通本地备份 / 恢复后，再继续配置：

- `rclone`
- 单远端备份
- 主备远端
- 跨机恢复

此时再阅读：

- [配置说明](docs/zh/配置说明.md)
- [备份说明](docs/zh/备份说明.md)
- [恢复说明](docs/zh/恢复说明.md)

跨机恢复且远端路径使用了 `{hostname}` 时：

```bash
bash vpsmagic.sh restore \
  --config /opt/vpsmagic/config.env \
  --source-hostname SOURCE_HOSTNAME
```

## 常用命令

```bash
# 备份
bash vpsmagic.sh backup --config /opt/vpsmagic/config.env

# 仅本地备份
bash vpsmagic.sh backup --config /opt/vpsmagic/config.env --dest local

# 本地文件恢复
bash vpsmagic.sh restore --local /path/to/backup.tar.gz --config /opt/vpsmagic/config.env

# 远端恢复
bash vpsmagic.sh restore --config /opt/vpsmagic/config.env

# 无人值守恢复，失败后自动执行配置级回滚
bash vpsmagic.sh restore \
  --config /opt/vpsmagic/config.env \
  --auto-confirm \
  --rollback-on-failure

# 在线迁移
bash vpsmagic.sh migrate root@new-vps

# 定时任务
bash vpsmagic.sh schedule install --config /opt/vpsmagic/config.env
```

## 文档索引

中文文档：

- 总览入口：[中文文档总览](docs/zh/README.md)

首次上手：

- [新用户新环境开局指导](docs/zh/新用户新环境开局指导.md)
- [零配置起步](docs/zh/零配置起步.md)
- [快速开始](docs/zh/快速开始.md)
- [配置说明](docs/zh/配置说明.md)

运行与恢复：

- [备份说明](docs/zh/备份说明.md)
- [状态说明](docs/zh/状态说明.md)
- [恢复说明](docs/zh/恢复说明.md)
- [迁移说明](docs/zh/迁移说明.md)
- [定时任务说明](docs/zh/定时任务说明.md)
- [排障说明](docs/zh/排障说明.md)

边界与验收：

- [免责声明](docs/zh/免责声明.md)
- [能力矩阵](docs/zh/能力矩阵.md)
- [业务画像与适用场景](docs/zh/业务画像与适用场景.md)
- [真实空机远端恢复验收](docs/zh/真实空机远端恢复验收.md)
- [最终验收结论](docs/zh/最终验收结论.md)

English docs:

- Overview: [docs/en/README.md](docs/en/README.md)
- New-user guide: [docs/en/new-user-new-environment-guide.md](docs/en/new-user-new-environment-guide.md)
- Status fields: [docs/en/status.md](docs/en/status.md)
- [Real empty-host remote restore acceptance](docs/en/real-empty-host-remote-restore-acceptance.md)
- [Final acceptance summary](docs/en/final-acceptance-summary.md)

## 当前已落地能力

- 支持 `BACKUP_TARGETS`、`BACKUP_PRIMARY_TARGET`、`BACKUP_ASYNC_TARGET`
- 支持 `{hostname}` 占位符
- 支持 `--source-hostname` 跨机恢复
- 远端恢复支持前置检查、可用远端过滤、主远端失败自动回退
- 同名本地归档且 `.sha256` 一致时直接复用
- 缺 `rclone`、Docker / Compose 时可尝试自动安装
- Debian 空机默认源缺 `docker-compose-plugin` 时，会继续尝试 Docker 官方仓库
- 恢复前会生成配置级快照，并把回滚边界写入快照目录

## 当前已知限制

- 不会自动生成 `rclone.conf` 或 `/root/.oci/config`；它们被视为远端恢复的安全验证门槛
- 独立 Docker 容器仍不是自动恢复主路径
- 数据库恢复仍以逻辑导出与文件恢复为主，不承诺业务层一致性验证
- 轻量回滚仍是配置级，不是完整系统回滚
- 非 Debian / Ubuntu 类系统的自动补依赖能力仍相对保守

## 维护与发布建议

1. 每次发布前至少做一次真实 restore 演练。
2. 对计划上线的业务，优先按 A / B / C 等级评估恢复预期。
3. 任何新增功能都应优先补摘要项、健康检查项和失败边界说明。
