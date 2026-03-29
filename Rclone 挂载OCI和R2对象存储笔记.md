### Rclone 挂载 Oracle OCI 笔记
> 环境：Linux（root 用户），rclone >= 1.57，Region 示例：`ap-tokyo-1`

***

#### 一、OCI 控制台：生成 API Key

1. 登录 [OCI 控制台](https://cloud.oracle.com)
2. 右上角 **用户头像 → User settings→ Tokens and keys**
3. 左侧按钮 **Add API Key → 添加 API 密钥**
4. 选择 **Generate API key pair** → 下载私钥（`.pem` 文件）
5. 点击「添加」后，复制弹出的配置预览内容

***

#### 二、服务器：创建 OCI 配置文件

```bash
mkdir -p ~/.oci
nano ~/.oci/oci_api_key.pem    # 粘贴私钥内容
nano ~/.oci/config              # 粘贴控制台生成的配置
chmod 600 ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/config
```

`~/.oci/config` 内容示例（**key_file 填绝对路径**）：

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaaaaaaXXXXXX
fingerprint=xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx
tenancy=ocid1.tenancy.oc1..aaaaaaaaXXXXXX
region=ap-tokyo-1
key_file=/root/.oci/oci_api_key.pem
```


***

#### 三、配置 rclone

运行 `rclone config`，生成的配置示例：

```ini
[OOS]
type = oracleobjectstorage
namespace = idbamagbg734
compartment = ocid1.compartment.oc1..aaaaaaaaXXXXXX
region = ap-tokyo-1
provider = user_principal_auth
config_file = /root/.oci/config
config_profile = DEFAULT
```


***

#### 四、验证 \& 挂载

```bash
# 验证
rclone lsd OOS:
rclone ls OOS:bucket-name

# 挂载
mkdir -p /mnt/oci-bucket
rclone mount OOS:bucket-name /mnt/oci-bucket \
  --allow-non-empty --allow-other \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 5G \
  --log-level INFO \
  --daemon
```


***

#### 五、开机自动挂载（systemd）

创建 `/etc/systemd/system/rclone-oci.service`，然后：

```bash
systemctl daemon-reload
systemctl enable rclone-oci
systemctl start rclone-oci
```


***

#### 六、两个配置文件的分工

| 文件                           | 作用                                       | 存储内容                                                     |
| :----------------------------- | :----------------------------------------- | :----------------------------------------------------------- |
| `~/.config/rclone/rclone.conf` | 告诉 rclone **"有这个远程，去哪里找认证"** | 远程名称、类型、namespace、region、compartment、以及 `config_file` 指向路径 |
| `~/.oci/config` + `.pem`       | 实际执行认证，提供 **真正的身份凭证**      | User OCID、Tenancy OCID、Fingerprint、私钥路径               |

***

#### 七、常见错误排查

| 错误提示 | 原因 | 解决方法 |
| :-- | :-- | :-- |
| `config file doesn't exist` | `/root/.oci/config` 不存在 | 按第二步创建 |
| `did not find a proper configuration for tenancy` | config 内容或路径错误 | 检查 OCID 和 key_file 绝对路径 |
| `401 authentication failed` | 私钥与控制台公钥不匹配 | 重新生成 API Key 对 |
| `permission denied` on `.pem` | 文件权限过于开放 | `chmod 600 ~/.oci/oci_api_key.pem` |

### Rclone 挂载 Cloudflare R2 笔记

> 环境：Linux，rclone 已安装  
> 适用场景：将 Cloudflare R2 bucket 挂载到本地目录，便于像操作文件夹一样访问对象存储。

---

#### 一、准备信息

在开始之前，需要先在 Cloudflare 后台准备以下信息：

- Account ID
- R2 的 Access Key ID
- R2 的 Secret Access Key
- 已创建好的 bucket 名称（例如 `bucket-name`）

Cloudflare 官方说明中，rclone 连接 R2 前需要先生成 Access Key，然后使用该密钥对进行访问。

---

#### 二、创建 R2 API 凭证

1. 登录 Cloudflare Dashboard。
2. 进入 **R2 对象存储** 页面。
3. 打开 **API Tokens**后边的**Manage**按钮。
4. **Create User API token**，权限建议使用对象读写。
5. 保存生成后的：
   - `Access Key ID`
   - `Secret Access Key`
   - `endpoints for S3 clients`
6. 创建bucket。

> 注意：Secret Access Key 通常只显示一次，丢失后需要重新生成。

---

#### 三、配置 rclone

Cloudflare R2 使用 S3 兼容接口，因此可以直接在 `~/.config/rclone/rclone.conf` 中写入配置，无需像 OCI 那样额外依赖独立认证配置文件。

先编辑配置文件：

```bash
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

写入以下内容：

```ini
[R2]
type = s3
provider = Cloudflare
access_key_id = 你的AccessKeyID
secret_access_key = 你的SecretAccessKey
region = auto
endpoint = endpoints for S3 clients
acl = private
no_check_bucket = true
```

说明：

- `R2` 是这个远程存储的名称，可以自定义。
- `type = s3` 表示通过 S3 兼容协议连接。
- `provider = Cloudflare` 表示这是 Cloudflare R2。
- `region = auto` 是常见写法。
- `endpoint` 格式为：`https://<AccountID>.r2.cloudflarestorage.com`。
- `no_check_bucket = true` 跳过 lsd，直接测试访问具体 bucket。

---

#### 四、验证连接

配置完成后，先测试是否能连通。

```bash
# 查看指定 bucket 内容
rclone ls R2:bucket-name
```
- `bucket-name` 本例中的示例 bucket 名称。
如果能够列出文件，说明配置成功。

---

#### 五、挂载到本地目录

先创建本地挂载点：

```bash
mkdir -p /mnt/r2-bucket
```

然后执行挂载命令：

```bash
rclone mount r2:bucket-name /mnt/r2-bucket \
  --allow-non-empty \
  --allow-other \
  --dir-perms 0755 \
  --file-perms 0644 \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 5G \
  --log-level INFO \
  --log-file /var/log/rclone/r2.log \
  --daemon
```

挂载完成后，可通过以下命令验证：

```bash
ls /mnt/r2-bucket
```

---

#### 六、开机自动挂载（systemd）

创建 systemd 服务文件：

```bash
nano /etc/systemd/system/rclone-r2.service
```

写入以下内容：

```ini
[Unit]
Description=Rclone Mount Cloudflare R2
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount r2:bucket-name /mnt/r2-bucket \
  --allow-non-empty \
  --allow-other \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 5G \
  --log-level INFO \
  --log-file /var/log/rclone/r2.log
ExecStop=/bin/fusermount -uz /mnt/r2-bucket
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

然后执行：

```bash
systemctl daemon-reload
systemctl enable rclone-r2
systemctl start rclone-r2
systemctl status rclone-r2
```

---

#### 七、常见问题排查

| 错误提示 | 可能原因 | 解决方法 |
|---|---|---|
| `AccessDenied` | Access Key / Secret Key 错误 | 重新检查并复制正确密钥 |
| `NoSuchBucket` | bucket 名称写错 | 确认 bucket 实际名称 |
| 无法列出 bucket | endpoint 填错 | 检查 Account ID 与 endpoint 格式 |
| 挂载后目录为空 | 挂载目标 bucket 错误 | 用 `rclone ls r2:bucket名` 先验证 |
| `allow-other` 失败 | FUSE 未启用 `user_allow_other` | 修改 `/etc/fuse.conf` |

---

#### 八、补充说明

- R2 本质上是对象存储，不是传统块存储或本地磁盘，因此不适合高频随机小文件写入。
- 更适合备份、静态资源、图片、视频和归档文件场景。
- 相比传统对象存储，R2 没有标准的出口流量费用，适合做静态资源托管和备份。
