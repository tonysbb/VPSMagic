# 中文文档总览

本目录面向普通使用者，按“任务”而不是按“代码模块”组织文档。

如果你只是第一次接触这个工具，先记住一个原则：

- 先跑通“本地备份 + 本地恢复演练”
- 再做“云端备份 + 远端恢复”
- 最后再做“跨机恢复 / 在线迁移”

如果你不知道该从哪篇开始，按下面判断：

- 你还没有 `rclone`、没有云存储：先看 [零配置起步](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/零配置起步.md)
- 你已经想开始正式使用：看 [快速开始](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/快速开始.md)
- 你准备配置云端远端：看 [配置说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/配置说明.md)
- 你准备在新机恢复：看 [恢复说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/恢复说明.md)
- 你遇到了错误或恢复结果不符合预期：看 [排障说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/排障说明.md)
- 你不确定自己的 VPS 属于哪一类：看 [业务画像与适用场景](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/业务画像与适用场景.md)
- 你想看一轮真实空机远端恢复是否已经验证通过：看 [真实空机远端恢复验收](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/真实空机远端恢复验收.md)

## 三条最短路径

### 路径 1：我现在只想先备份成功一次

直接看：

1. [零配置起步](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/零配置起步.md)
2. [恢复说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/恢复说明.md)
3. [业务画像与适用场景](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/业务画像与适用场景.md)

### 路径 2：我已经要开始正式使用

直接看：

1. [快速开始](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/快速开始.md)
2. [配置说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/配置说明.md)
3. [备份说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/备份说明.md)
4. [恢复说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/恢复说明.md)

### 路径 3：我已经遇到问题了

直接看：

1. [排障说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/排障说明.md)
2. [恢复说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/恢复说明.md)

建议阅读顺序：

1. [零配置起步](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/零配置起步.md)
2. [免责声明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/免责声明.md)
3. [快速开始](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/快速开始.md)
4. [配置说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/配置说明.md)
5. [备份说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/备份说明.md)
6. [恢复说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/恢复说明.md)
7. [迁移说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/迁移说明.md)
8. [定时任务说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/定时任务说明.md)
9. [排障说明](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/排障说明.md)
10. [能力矩阵](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/能力矩阵.md)
11. [业务画像与适用场景](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/业务画像与适用场景.md)
12. [真实空机远端恢复验收](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/真实空机远端恢复验收.md)

## 第一次使用时你可以先不关心

如果你现在只是第一次上手，这些内容都可以先不学：

- `OCI`
- `R2`
- `rclone`
- `BACKUP_ASYNC_TARGET`
- `--source-hostname`
- `--rollback-on-failure`

先把第一轮最小闭环做出来，再升级能力，排错成本最低。

如果你已经准备上线远端恢复，请把下面两项当成安全验证门槛，而不是“可有可无的缺失项”：

- `rclone.conf`
- `/root/.oci/config`
