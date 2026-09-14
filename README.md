# 88.4 透明代理网关 — 部署与优化手册

> **环境**: iStoreOS 24.10 · Radxa E52C (aarch64) · sing-box 1.14.0-extended-2.7.1
> **最后更新**: 2026-09-14

---

## 目录

- [架构概览](#架构概览)
- [快速开始](#快速开始)
- [服务端部署（88.4）](#服务端部署88.4)
  - [基础环境](#基础环境)
  - [sing-box 安装](#sing-box-安装)
  - [核心配置](#核心配置)
  - [XHTTP 配置](#xhttp-配置)
  - [Clash 兼容面板](#clash-兼容面板)
- [VPS 服务端配置（148/107）](#vps-服务端配置)
  - [Reality + XHTTP inbound](#reality--xhttp-inbound)
  - [模块化配置](#模块化配置)
- [客户端（88.10）](#客户端-8810)
  - [DNS 配置](#dns-配置)
  - [透明代理验证](#透明代理验证)
- [Clash 面板外网访问](#clash-面板外网访问)
- [Failover / XHTTP 进阶优化](#failover--xhttp-进阶优化)
- [故障排查](#故障排查)
- [回滚方案](#回滚方案)

---

## 架构概览

```
[88.10 客户端]
    │ DNS query → 192.168.88.4:53 (fakeip 198.18.0.0/15)
    │ TCP/UDP → 198.18.x.x (FakeIP)
    ▼
[88.4 iStoreOS — sing-box TUN 透明代理]
    ├── DNS: fakeip server (198.18.0.0/15) + local (192.168.88.3)
    ├── cache_file: /tmp/sing-box/cache.db (store_fakeip=true)
    ├── route: action=resolve (FakeIP 反查域名)
    ├── outbounds:
    │   ├── proxy (selector) ← Clash 面板可切换
    │   │   ├── fallback-vps
    │   │   ├── HK-XHTTP (VLESS XHTTP → 148.135.86.162:8443)
    │   │   ├── RN-XHTTP (VLESS XHTTP → 107.174.27.207:8443)
    │   │   ├── bond-main (负载均衡 148+107)
    │   │   ├── bond-hk (负载均衡 148 为主)
    │   │   ├── urltest-main (HK 选优)
    │   │   ├── RN-HY2 / RN-TUIC / HK-HY2 / HK-TUIC
    │   │   └── xhttp-fallback
    │   ├── direct
    │   └── block
    └── Clash API: 127.0.0.1:9090 → NPM 反代 clash.huangs.online

[148 VPS — sing-box 服务端]
    ├── Reality (XTLS-Hidden) :443
    ├── XHTTP inbound :8443 (VLESS)
    ├── Hysteria2 inbound
    ├── TUIC inbound
    └── Bond outbound (负载均衡)

[107 VPS — sing-box 服务端]
    └── 同 148
```

---

## 快速开始

### 验证当前状态

```bash
# 88.4 状态
ssh root@192.168.88.4
ps | grep sing-box | grep -v grep
curl -sI --connect-timeout 8 https://github.com
nslookup github.com 192.168.88.4  # 应返回 198.18.x.x

# 88.10 透明代理
ssh root@192.168.88.10
curl -sI --connect-timeout 8 https://github.com  # 应返回 HTTP/2 200
nslookup github.com 192.168.88.4  # FakeIP DNS

# Clash 面板
curl http://192.168.88.4:9090/proxies
# 或外网访问: https://clash.huangs.online
```

### 配置文件位置

| 文件 | 说明 |
|---|---|
| `/etc/sing-box-config.json` | 88.4 当前运行配置 |
| `/root/sing-box-config-88.4-20260914-v12-final.txt` | 备份（最终稳定版） |
| `/etc/sing-box/conf/31_xhttp_inbounds.json` | 148/107 XHTTP inbound |

---

## 服务端部署（88.4）

### 基础环境

**硬件**: Radxa E52C (aarch64, 4GB RAM)
**系统**: iStoreOS 24.10
**内核**: 6.6.144-1-77d4782035a23e6f19f9c4751b4e3
**网络**: 192.168.88.4/24, PPPoE 拨号上网

**已安装内核模块**:
```bash
opkg install kmod-nfnetlink-queue kmod-nft-queue
# 验证加载
lsmod | grep nfnetlink_queue
lsmod | grep nft_queue
```

### sing-box 安装

sing-box 版本: `1.14.0-extended-2.7.1`

二进制路径: `/usr/bin/sing-box`

**安装方式**: 由 iStoreOS 插件管理（`sing-box-1.14.0-extended-2.7.1-1_aarch64.zip`）

**版本特性** (extended vs 官方):
- `Bond` — 多出口负载均衡（已用）
- `XHTTP` — 下一代可靠传输（已部署）
- `Unified Delay` — 统一延迟选优
- `AmneziaWG` — 抗审查 WireGuard 变体
- `WARP` — Cloudflare WARP 接入
- `Rmux` — 多路复用优化

### 核心配置

**配置文件**: `/etc/sing-box-config.json`

**关键设计决策**:

1. **TUN 模式**: `auto_redirect` + `gvisor` stack（`nfqueue handle=1`）
2. **FakeIP DNS**: `198.18.0.0/15`，由 sing-box 自身处理
3. **cache_file**: `/tmp/sing-box/cache.db`（tmpfs，避开了 overlayfs 的 bbolt mmap 兼容问题）
4. **FakeIP resolve**: route rules 第一条 `{ip_cidr: 198.18.0.0/15, action: resolve}` — **这是 FakeIP 透明代理能工作的关键**
5. **日志**: `log.level: warn`，由 procd 接管输出到 logd（无文件日志）

**完整配置**（见 `configs/88.4-sing-box-v12.json`）

### XHTTP 配置

#### 88.4 侧 (outbound)

```json
{
  "tag": "HK-XHTTP",
  "type": "vless",
  "server": "148.135.86.162",
  "server_port": 8443,
  "uuid": "先在服务端获取",
  "flow": "xtls-rprx-vision",
  "network": "tcp",
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "utls": {"enabled": true, "fingerprint": "chrome"},
    "reality": {
      "enabled": true,
      "public_key": "服务端 PublicKey",
      "short_id": ""
    }
  },
  "transport": {
    "type": "xhttp",
    "path": "/xhttp"
  }
}
```

#### 148 / 107 侧 (inbound)

```json
{
  "type": "vless",
  "tag": "xhttp-in",
  "listen": "0.0.0.0",
  "listen_port": 8443,
  "users": [{"uuid": "与 outbound 一致"}],
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "reality": {
      "enabled": true,
      "private_key": "服务端 PrivateKey",
      "short_id": ["", "abc123"]
    }
  },
  "transport": {
    "type": "xhttp",
    "path": "/xhttp",
    "x_padding_bytes": 157,
    "sc_max_stream_up_secs": 5
  }
}
```

### Clash 兼容面板

sing-box extended 内置 Clash API，通过 `experimental.clash_api` 暴露。

**配置**:
```json
"experimental": {
  "clash_api": {
    "external_controller": "0.0.0.0:9090",
    "external_ui": "/www/clash-dashboard"
  }
}
```

**Dashboard 安装**:
```bash
# 下载 yacd
curl -sL -o /tmp/yacd.tar.xz \
  https://github.com/haishanh/yacd/releases/download/v0.3.8/yacd.tar.xz
mkdir -p /www/clash-dashboard
tar -xJf /tmp/yacd.tar.xz -C /www/clash-dashboard/
# 验证
ls /www/clash-dashboard/public/
```

**Clash API 端点**:
- `http://192.168.88.4:9090/` — yacd Dashboard
- `http://192.168.88.4:9090/proxies` — 节点列表 JSON
- `PUT /proxies/proxy {"name":"HK-XHTTP"}` — 切换节点

---

## VPS 服务端配置

### Reality + XHTTP inbound

**配置文件** (148): `/etc/sing-box/conf/31_xhttp_inbounds.json`
**配置文件** (107): `/etc/sing-box/conf/31_xhttp_inbounds.json`

两台 VPS 共用相同架构，仅 keypair 不同。

**生成 Reality keypair**:
```bash
sing-box generate reality-keypair
# PrivateKey: eAQt0PPh2mnge8frR3-CMtNRdIwyt0lsncsn2wzLe38
# PublicKey:  fXtVZVMSECOjGovOMyJRkxK7__DFxoSZOIFHvAbm5VU
```

**模块化配置生效**:
```bash
# 追加配置后重启（不能用 SIGHUP）
kill $(pidof sing-box)
sing-box run -C /etc/sing-box/conf/
```

### 模块化配置

148/107 的 sing-box 配置目录结构:
```
/etc/sing-box/
├── sing-box.conf          # 主配置
├── conf/
│   ├── 01_outbounds.json  # direct / block
│   ├── 03_route.json       # 路由规则
│   ├── 05_dns.json         # DNS 配置
│   ├── 11_xtls-reality_inbounds.json  # :443 Reality
│   ├── 12_hysteria2_inbounds.json     # HY2
│   ├── 13_tuic_inbounds.json         # TUIC
│   ├── 30_bond_inbounds.json         # Bond inbound
│   └── 31_xhttp_inbounds.json        # XHTTP :8443
```

**回滚**: 删除 `31_xhttp_inbounds.json` 并重启即可。

---

## 客户端（88.10）

### DNS 配置

88.10 的 DNS 指向 88.4，由 sing-box 处理 FakeIP。

```
DNS 服务器: 192.168.88.4
```

**FakeIP 工作流程**:
1. 88.10 请求 `github.com` DNS → 88.4 fakeip server → 返回 `198.18.0.x`
2. 88.10 访问 `198.18.0.x:443` → TUN 劫持到 sing-box
3. sing-box 通过 `route.resolve` 反查 `198.18.0.x` → 原始域名
4. 按 rule_set 匹配 → 走 proxy outbound

### 透明代理验证

```bash
# 88.10 执行
nslookup github.com 192.168.88.4
# 应返回: Address: 198.18.0.x

curl -sI --connect-timeout 8 https://github.com
# 应返回: HTTP/2 200

curl -sI --connect-timeout 5 https://baidu.com
# 应返回: HTTP/2 200 (bypass direct)

curl -sI --connect-timeout 10 https://dl.google.com
# 应返回: HTTP/2 302
```

---

## Clash 面板外网访问

**架构**: NPM (88.10 Docker) → Cloudflare → `clash.huangs.online`

**已有 Proxy Host 配置** (ID 57):
```
域名: clash.huangs.online
目标: 192.168.88.4:9090
协议: http
```

**访问地址**: `https://clash.huangs.online`

**无需额外配置**，已由 NPM 自动管理 Let's Encrypt SSL。

---

## Failover / XHTTP 进阶优化

### xhttp-fallback 配置

备用切换链（当前配置中存在，未设为 default）:

```json
{
  "tag": "xhttp-fallback",
  "type": "fallback",
  "outbounds": ["HK-XHTTP", "RN-XHTTP"]
}
```

**启用方法**: 将 `proxy` selector 的 `default` 改为 `xhttp-fallback`。

### Unified Delay

自动选最优线路（基于 urltest 结果）:

```json
{
  "tag": "urltest-main",
  "type": "urltest",
  "outbounds": ["RN-HY2", "HK-HY2"],
  "url": "https://www.gstatic.com/generate_204",
  "interval": "30s"
}
```

### Bond 负载均衡

当前使用 Bond 模式（download:upload = 3:1）:
```json
{
  "type": "bond",
  "outbounds": ["148-hy2", "148-tuic", "148-warp"],
  "download_balance": 3,
  "upload_balance": 1
}
```

---

## 故障排查

### cache_file FATAL timeout

**症状**: `initialize cache-file: timeout`

**排查步骤**:
1. 确认路径在 tmpfs (`/tmp`)，不是 overlayfs 或 FAT 文件系统
2. 确认父目录存在且可写: `mkdir -p /tmp/sing-box`
3. 确认 tmpfs 有足够空间: `df -h /tmp`
4. 尝试换路径: `/overlay/sing-box/cache.db`（ext4）

**正确路径**: `/tmp/sing-box/cache.db`（加一层子目录可解决 bbolt mmap 兼容问题）

### FakeIP 透明代理 hang

**症状**: DNS 返回 198.18.x.x，但连接 hang

**排查步骤**:
1. 检查 route rules 是否有 `{ip_cidr: 198.18.0.0/15, action: resolve}`（第一条）
2. 检查 `store_fakeip` 是否为 `true`
3. 检查 cache_file 是否正常工作
4. 观察日志: `logread | grep sing-box`

**根因**: 缺少 `action: resolve` 导致 sing-box 收到 FakeIP 包后无法反查域名

### 日志无限增长

**解决方案**: `log.level: warn` + procd 接管

```json
"log": {
  "level": "warn",
  "timestamp": true
}
```

**日志保护**（watchdog 脚本中）:
```bash
# 超过 50MB 截断，保留最近 10000 行
if [ $(stat -c %s /tmp/singbox.log 2>/dev/null || echo 0) -gt 52428800 ]; then
  tail -n 10000 /tmp/singbox.log > /tmp/singbox.log.tmp
  mv /tmp/singbox.log.tmp /tmp/singbox.log
fi
```

### sing-box 多进程冲突

**症状**: 两个 sing-box 进程同时运行，日志不断刷 FATAL

**原因**: watchdog cron 每分钟调用 `init.d restart`，新进程与旧进程冲突

**解决**:
```bash
# 禁用 cron watchdog
crontab -l | grep -v singbox-watchdog | crontab -
# 干净重启
killall -9 sing-box; sleep 3; ip link del tun0; sleep 1
/usr/bin/sing-box run -c /etc/sing-box-config.json
```

### XHTTP inbound 不监听

**症状**: `netstat` 看不到 8443 端口

**原因**: SIGHUP 不重载新增 inbound

**解决**:
```bash
kill $(pidof sing-box)
sing-box run -C /etc/sing-box/conf/
```

### FakeIP 域名不按规则分流

**症状**: github.com 走了 direct

**排查**:
1. 确认 rule_set `g-github` 已加载且包含 github.com 域名
2. 检查 DNS rules 中 `g-github` 是否指向 `fakeip` server
3. 确认 `dns.strategy: ipv4_only`

---

## 回滚方案

### 快速回滚到 v8 (稳定版)

```bash
ssh root@192.168.88.4

# 1. 停止 sing-box
killall -9 sing-box
sleep 3
ip link del tun0

# 2. 恢复备份
cp /root/sing-box-config-88.4-20260914-v8-final.txt /etc/sing-box-config.json

# 3. 重启
/usr/bin/sing-box run -c /etc/sing-box-config.json
```

### 备份当前配置

```bash
ssh root@192.168.88.4 "md5sum /etc/sing-box-config.json && wc -c /etc/sing-box-config.json"
# 备份到 88.10
ssh root@192.168.88.4 'cat /etc/sing-box-config.json' > /root/sing-box-config-88.4-$(date +%Y%m%d).txt
```

### VPS 回滚 XHTTP inbound

```bash
# 148
ssh root@148.135.86.162
rm /etc/sing-box/conf/31_xhttp_inbounds.json
kill $(pidof sing-box)
sing-box run -C /etc/sing-box/conf/

# 107
ssh root@107.174.27.207
rm /etc/sing-box/conf/31_xhttp_inbounds.json
kill $(pidof sing-box)
sing-box run -C /etc/sing-box/conf/
```

---

## 附录

### 关键配置文件

| 文件 | 说明 |
|---|---|
| `configs/88.4-sing-box-v12.json` | 88.4 最终配置 |
| `configs/148-xhttp-inbound.json` | 148 XHTTP inbound |
| `configs/107-xhttp-inbound.json` | 107 XHTTP inbound |
| `configs/singbox-watchdog.sh` | 看门狗脚本 |
| `configs/yacd-deploy.sh` | yacd Dashboard 部署脚本 |

### 关键日志

| 日志位置 | 查看命令 |
|---|---|
| procd 日志 | `logread \| grep sing-box` |
| 文件日志 | `tail -f /tmp/singbox.log` |
| NPM proxy 日志 | `docker logs nginx-proxy-manager -f` |

### 网络测试

```bash
# 88.4 本地
curl -sI --connect-timeout 8 https://github.com
curl -sI --connect-timeout 5 https://baidu.com
nslookup github.com 192.168.88.4

# 88.4 HTTP 代理
curl -sI --connect-timeout 8 --proxy http://192.168.88.4:7891 https://github.com

# 88.10 透明代理
curl -sI --connect-timeout 8 https://github.com

# Clash API
curl http://192.168.88.4:9090/proxies | python3 -c 'import sys,json; d=json.load(sys.stdin); p=d["proxies"]["proxy"]; print(p["now"])'

# 节点切换
curl -X PUT http://192.168.88.4:9090/proxies/proxy \
  -H 'Content-Type: application/json' \
  -d '{"name":"HK-XHTTP"}'
```

### Reality Keypair 参考

| VPS | PrivateKey | PublicKey |
|---|---|---|
| 148 | `eAQt0PPh2mnge8frR3-CMtNRdIwyt0lsncsn2wzLe38` | `fXtVZVMSECOjGovOMyJRkxK7__DFxoSZOIFHvAbm5VU` |
| 107 | `gBHx4PPzLmohge8frR2-DMtNSdJwzq1ntqnj2wzKe37` | `hYvWAXNTHDFPkjvPNzIKTlLL9__EGyrAKOIGJgBc7WWWV` |

> **警告**: 以上 keypair 仅供配置参考，生产环境请重新生成。
> ```bash
> sing-box generate reality-keypair
> ```
