# Server Traffic Monitor

一个面向轻量 Linux 服务器的 **公网出口流量 + 基础资源状态** 单页监控面板。

项目来自一台 Azure Ubuntu 服务器上的实际需求：服务器已有 Xray/REALITY 占用 `443`，希望额外部署一个几乎不占资源的流量面板，用来观察月度公网出口、套餐使用率、CPU / 内存 / 磁盘，同时不能引入 Docker、Grafana、Prometheus 或常驻 Python/Node Web 服务。

界面采用亮色 Miku Cream 风格，主色为 **`#39C5BB`**，桌面端尽量一屏显示。

## 功能

- 公网出口 TX 独立统计
  - 使用 nftables 内核计数器
  - 排除常见 RFC1918 私网、链路本地、多播等目标
  - 不记录连接明细，不抓包，不保存原始网络内容
- 当前周期流量 / 套餐上限 / 剩余额度
- 今日公网、昨日公网、最近 7 天公网趋势
- 简单月底 / 周期末流量预测：当前周期已用流量 ÷ 当前周期已过自然日数 × 周期总日数
- CPU 使用率
- 内存使用率 + 已用 / 总量
- 根分区磁盘使用率 + 已用 / 总量
- 每 **1 分钟**自动采样
- 页面每 **1 分钟**自动刷新
- 管理口令鉴权
- 手动立即刷新
- 流量矫正
  - 用户只输入目标值
  - 系统自动计算偏移量
  - 不修改 nftables 原始计数
- 套餐设置
  - 每月清零日：1–28
  - 月度流量上限：GB
- systemd 开机自启
- Nginx 静态托管
- 无常驻 Python Web 服务

## 架构

```text
                    ┌─────────────────────────┐
                    │       Web Browser       │
                    └────────────┬────────────┘
                                 │ HTTPS
                                 ▼
                       ┌──────────────────┐
                       │      Nginx       │
                       │ static + WebDAV  │
                       └───────┬──────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
              ▼                                 ▼
      /data.json                        /api/admin/*
      read-only GET                    Basic Auth + PUT
              │                                 │
              │                                 ▼
              │                       systemd .path units
              │                                 │
              │                    ┌────────────┼────────────┐
              │                    ▼            ▼            ▼
              │                 refresh       adjust       package
              │
              ▼
 server-traffic-monitor-data.timer
          every 1 min
              │
              ▼
       generate_data.py
        │      │      │
        │      │      └── /proc + disk_usage
        │      │          CPU / RAM / Disk
        │      │
        │      └───────── vnStat
        │                 interface totals
        │
        └──────────────── nftables
                          public TX counter
```

## 为什么不用 Prometheus / Grafana

这个项目的目标不是完整可观测平台，而是一个单机、小内存、低维护成本的服务器流量面板。

公网流量由 nftables 在内核中累计；vnStat 保存轻量聚合数据；Python 只由 systemd 每分钟启动一次并立即退出。不会运行常驻 Python / Node 服务。

因此特别适合：

- 1 GB 左右内存的小型 VPS
- Azure / Oracle Cloud / 腾讯云 / 阿里云等轻量服务器
- 服务器已经运行代理或网站，不希望再加入大型监控栈
- 只关心公网出口配额和当前机器状态

## 系统要求

当前一键部署脚本面向：

- Ubuntu 22.04 / 24.04
- Debian 12 等 apt 系发行版
- systemd
- Nginx
- root / sudo 权限

脚本会自动安装最小依赖：

```text
nginx
vnstat
nftables
apache2-utils
python3
openssl
ca-certificates
```

## 一键部署

### 1. 克隆仓库

```bash
git clone https://github.com/zakee039/server-traffic-monitor.git
cd server-traffic-monitor
```

### 2. 准备 HTTPS 证书

推荐使用 Cloudflare Origin CA，或其他与你的域名匹配的 TLS 证书。

例如：

```text
/root/certs/fullchain.pem
/root/certs/privkey.key
```

> 私钥不会复制进仓库。部署脚本只会把证书安装到服务器的 Nginx 专用目录，并将私钥权限设置为 `0600`。

### 3. 执行安装

```bash
sudo bash install.sh \
  --domain monitor.example.com \
  --cert /root/certs/fullchain.pem \
  --key /root/certs/privkey.key
```

默认：

- HTTPS 端口：`8443`
- 流量套餐：`100 GB`
- 清零日：每月 1 日
- 公网出口网卡：自动识别
- 管理用户名：`admin`
- 首次安装管理密码：自动生成 16 位随机密码；重复安装默认保留现有密码
- 自动刷新：1 分钟

安装完成后终端会输出一次管理密码。

服务器的 Nginx 只保存密码哈希，不保存随机生成的明文密码。

## 常用部署参数

```bash
sudo bash install.sh \
  --domain monitor.example.com \
  --cert /root/certs/fullchain.pem \
  --key /root/certs/privkey.key \
  --port 8443 \
  --quota 100 \
  --reset-day 1
```

完整选项：

| 参数 | 说明 |
|---|---|
| `--domain` | 必填，站点域名 |
| `--cert` | 必填，TLS 证书路径 |
| `--key` | 必填，TLS 私钥路径 |
| `--port` | HTTPS 监听端口，默认 `8443` |
| `--quota` | 流量套餐 GB，默认 `100` |
| `--reset-day` | 每月清零日，`1–28` |
| `--interface` | 手动指定出口网卡；默认自动识别 |
| `--admin-password` | 手动设置/重置管理密码；首次安装不传则生成 16 位，重复安装不传则保留现有密码 |
| `--open-ufw` | 如果 UFW 已启用，则自动开放所选 TCP 端口 |

例如服务器公网网卡不是 `eth0`：

```bash
sudo bash install.sh \
  --domain monitor.example.com \
  --cert /root/certs/fullchain.pem \
  --key /root/certs/privkey.key \
  --interface ens3
```

## 443 已被其他服务占用

这正是本项目默认使用 `8443` 的原因。

例如：

```text
443    → Xray / REALITY
8443   → Server Traffic Monitor / Nginx
```

安装器会检查目标端口。如果 `8443` 已经被 **非 Nginx** 进程占用，会直接终止，不会强行抢占端口。

## Cloudflare 配置

如果域名开启 Cloudflare 橙色云，并希望用户仍然直接访问：

```text
https://monitor.example.com
```

而源服务器的 Nginx 实际监听：

```text
8443
```

可以配置：

### DNS

```text
A  monitor.example.com  → 服务器公网 IP
Proxy status            → Proxied
```

### SSL/TLS

建议：

```text
Full (strict)
```

### Origin Rule

条件：

```text
Hostname equals monitor.example.com
```

动作：

```text
Rewrite destination port → 8443
```

最终链路：

```text
Browser :443
    ↓
Cloudflare
    ↓
Origin Rule
    ↓
Server :8443
    ↓
Nginx
```

如果云厂商还有 NSG / Security Group，需要额外开放 TCP `8443`。Linux 部署脚本无法修改 Azure NSG、AWS Security Group 等云平台防火墙。

## 公网流量统计口径

项目不是简单把 `eth0 TX` 全部当成公网流量。

nftables 会统计指定出口网卡，并排除常见非公网地址，例如：

```text
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
224.0.0.0/4
240.0.0.0/4

IPv6:
::1/128
fc00::/7
fe80::/10
ff00::/8
```

同时排除了 Azure 平台常见虚拟 IP：

```text
168.63.129.16
```

因此 Dashboard 中的公网 TX 比单纯的网卡 TX 更接近云服务器公网出口。

但它依然不是云厂商的计费系统：

> 本机公网计数与 Azure / AWS / 云厂商最终账单流量可能存在少量差异。

## 刷新机制

网络计数本身由 nftables 在内核中实时累计。

Dashboard 数据由 systemd 每分钟生成一次：

```text
nftables
vnStat
/proc
filesystem
   ↓
generate_data.py
   ↓
data.json
```

前端同样每 60 秒重新请求一次：

```text
/data.json?ts=<timestamp>
```

避免浏览器或 CDN 返回旧缓存。

如果需要马上查看最新状态，可以输入管理口令后点击：

```text
立即刷新
```

## 矫正机制

“矫正”不会改 nftables 原始 counter，也不会修改 vnStat 数据库。

假设：

```text
当前本机统计：12.10 GB
云平台显示：  12.45 GB
```

用户只需要输入：

```text
12.45 GB
```

系统自动计算：

```text
adjustment = target - raw
```

最终展示：

```text
display = raw + adjustment
```

校准偏移保存在：

```text
/var/lib/server-traffic-monitor/config.json
```

所以：

- 原始计数仍然保留
- 校准可以追踪
- 不会污染 vnStat
- 不需要用户自己计算偏移量

## 设置套餐

管理口令验证后可以设置：

- 清零日：1–28
- 套餐流量：GB

例如设置：

```text
清零日：15
套餐：100 GB
```

统计周期自动变成：

```text
9/15 → 10/14
10/15 → 11/14
...
```

不会真的删除历史计数，只改变当前周期的统计切分方式。

## 管理接口安全模型

普通 Dashboard 完全只读，不需要登录。

只有三个固定管理动作：

```text
PUT /api/admin/refresh
PUT /api/admin/adjust
PUT /api/admin/package
```

它们具有以下限制：

- HTTPS
- Nginx Basic Auth
- bcrypt 密码哈希
- 请求体限制为 4 KB
- 只接受 PUT
- 没有任意命令接口
- 没有文件浏览
- 没有上传目录
- 没有 WebShell
- Nginx 只把固定 JSON 请求写到受控目录
- systemd `.path` 只触发固定脚本

也就是说，管理接口不是一个通用系统控制 API。

## 数据和磁盘占用

项目不会记录每个数据包，也不会保存每条连接。

主要持久化数据：

```text
/var/lib/server-traffic-monitor/data.json
/var/lib/server-traffic-monitor/public_state.json
/var/lib/server-traffic-monitor/config.json
vnStat database
```

`data.json` 每分钟覆盖写入，而不是不断追加。

公网状态只保留有限的日聚合，用于：

- 当前套餐周期
- 昨日公网
- 最近 7 天

正常运行多年通常也只是 MB 级数据，不会产生大量硬盘占用。

## 资源占用

设计目标：

- 无 Docker
- 无 Prometheus
- 无 Grafana
- 无 Node
- 无常驻 Python Web Server

常驻部分主要只有：

- Nginx
- vnStat daemon
- systemd / nftables 原生机制

Python 采样脚本每分钟执行一次后退出。

在最初的 Azure Ubuntu 24.04 实机环境中，Nginx + vnStat 常驻 RSS 约为几十 MB 级。

## 服务

部署后会创建：

```text
server-traffic-monitor-counter.service
server-traffic-monitor-data.service
server-traffic-monitor-data.timer

server-traffic-monitor-admin-refresh.path
server-traffic-monitor-admin-adjust.path
server-traffic-monitor-admin-package.path

server-traffic-monitor-admin@.service
```

查看状态：

```bash
systemctl status server-traffic-monitor-data.timer
systemctl status server-traffic-monitor-counter.service
systemctl status server-traffic-monitor-admin-refresh.path
```

查看下一次刷新：

```bash
systemctl list-timers server-traffic-monitor-data.timer
```

## 重要路径

```text
Web:
  /var/www/server-traffic-monitor/

Runtime data:
  /var/lib/server-traffic-monitor/

Scripts:
  /usr/local/lib/server-traffic-monitor/

Nginx:
  /etc/nginx/sites-available/server-traffic-monitor
  /etc/nginx/sites-enabled/server-traffic-monitor
  /etc/nginx/server-traffic-monitor.htpasswd

TLS:
  /etc/nginx/ssl/server-traffic-monitor/

nftables:
  /etc/server-traffic-monitor/public-counter.nft
```

## 修改管理密码

```bash
sudo htpasswd -B /etc/nginx/server-traffic-monitor.htpasswd admin
```

密码修改后无需重启 Nginx。

## 更新

拉取新版后重新运行原安装命令即可：

```bash
git pull

sudo bash install.sh \
  --domain monitor.example.com \
  --cert /root/certs/fullchain.pem \
  --key /root/certs/privkey.key
```

重复执行安装器时，已有管理密码哈希默认会保留；如果需要同时重置密码，显式传入 `--admin-password`。

安装器会：

1. 备份已有项目配置
2. 保留已有矫正数据
3. 更新程序文件
4. 检查 nftables 规则
5. 执行 `nginx -t`
6. 重启项目自身 systemd 单元

不会执行系统全量升级。

## 项目结构

```text
server-traffic-monitor/
├── README.md
├── install.sh
├── web/
│   └── index.html
├── scripts/
│   ├── generate_data.py
│   └── admin_action.py
└── deploy/
    ├── load-public-counter.sh
    ├── public-counter.nft.in
    ├── nginx/
    │   └── server.conf.in
    └── systemd/
        ├── server-traffic-monitor-counter.service
        ├── server-traffic-monitor-data.service.in
        ├── server-traffic-monitor-data.timer
        ├── server-traffic-monitor-admin@.service
        ├── server-traffic-monitor-admin-refresh.path
        ├── server-traffic-monitor-admin-adjust.path
        └── server-traffic-monitor-admin-package.path
```

## 设计原则

这个项目坚持几件事：

- **打开就能看**
- **默认只读**
- **不为了监控再部署一套复杂平台**
- **原始计数和人工校准分离**
- **尽量不抢现有业务端口**
- **配置失败时尽早退出**
- **公网统计可解释，而不是黑盒数字**
- **低资源服务器也能长期运行**

---

Made for small servers that just need a clean answer to one question:

**这个月，我还剩多少公网流量？**
