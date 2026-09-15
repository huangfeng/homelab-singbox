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
    │   │   ├── bond-cc  (HY2+TUIC 聚合 → 148)
    │   │   ├── bond-rn  (HY2+TUIC 聚合 → 107)
    │   │   ├── urltest-main (cc/rn 的 HY2+TUIC 自动选优)
    │   │   ├── cc-Reality :10000  / cc-XHTTP :8443
    │   │   ├── cc-HY2 :10001      / cc-TUIC :10002
    │   │   ├── rn-Reality :10000  / rn-XHTTP :8443
    │   │   └── rn-HY2 :10001      / rn-TUIC :10002
    │   ├── direct
    │   └── block
    └── Clash API: 0.0.0.0:9090 → NPM 反代 clash.huangs.online

[148 CloudCone — sing-box 服务端]  (前缀 cc-)
    ├── cc-reality  VLESS+Vision+Reality  :10000/TCP
    ├── cc-xhttp    VLESS+XHTTP+Reality   :8443/TCP
    ├── cc-hy2      Hysteria2             :10001/UDP
    ├── cc-tuic     TUIC (BBR/0-RTT)      :10002/UDP
    └── cc-bond     Bond (HY2+TUIC)       :10081-10082/UDP

[107 RackNerd — sing-box 服务端]  (前缀 rn-，端口与 148 完全一致)
    └── rn-reality / rn-xhttp / rn-hy2 / rn-tuic / rn-bond
        (realm 中继已停用，释放 10000-10011 端口段)
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
| `/root/sing-box-config-88.4-20260914-v12-final.txt` | 备份（v12 稳定版） |
| `configs/88.4-sing-box-v13.json` | 88.4 统一端口版（cc-*/rn-* 命名） |
| `configs/148-cc/*.json` | 148 (CloudCone) 全部 inbound |
| `configs/107-rn/*.json` | 107 (RackNerd) 全部 inbound |

---

## 统一端口方案（cc-* / rn-*）

**目标**: 148 与 107 使用**完全相同的端口与协议模板**，仅标签前缀和域名不同，便于统一调优与故障互换。

| 协议 | 端口 | 传输 | 148 标签 | 107 标签 |
|---|---|---|---|---|
| Reality (VLESS+Vision) | **10000/TCP** | TLS 伪装 | `cc-reality` | `rn-reality` |
| XHTTP (VLESS) | **8443/TCP** | Reality + XHTTP stream-up | `cc-xhttp` | `rn-xhttp` |
| Hysteria2 | **10001/UDP** | QUIC/h3 | `cc-hy2` | `rn-hy2` |
| TUIC | **10002/UDP** | QUIC/h3, BBR, 0-RTT | `cc-tuic` | `rn-tuic` |
| Bond 聚合 | **10081+10082/UDP** | HY2+TUIC 双路 | `cc-bond` | `rn-bond` |

**命名约定**: `cc-` = CloudCone (148.135.86.162)，`rn-` = RackNerd (107.174.27.207)。客户端出站标签与之同名，Clash 面板可直接辨识。

| 域名 | 指向 | 用途 |
|---|---|---|
| `cc.huangs.online` | 148.135.86.162 (DNS-only) | 148 入口（改 IP 免改客户端） |
| `rn.huangs.online` | 107.174.27.207 (DNS-only) | 107 入口 |
| `cc6.huangs.online` | 2607:f130:0:10c::12d (AAAA) | 148 IPv6 备用入口 |

> ⚠️ 这两个子域名**必须 DNS-only（灰云）**。`*.huangs.online` 通配是 Cloudflare Tunnel 橙云 CNAME，橙云只代理 80/443 且不转发 UDP，会直接破坏 Reality/Hysteria2/TUIC。

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

## 第二出口：WARP 直连（AmneziaWG 抗封锁）

> **核心价值**: 完全绕开 148/107。即使两台 VPS 全部不可用，家里仍能出网。

```
[88.4] --AmneziaWG(jc 混淆, UDP 2408)--> [Cloudflare WARP] --> 互联网
                                         出口 104.28.x.x (LAX/US)
```

### 为什么需要 AmneziaWG

普通 WireGuard 到 Cloudflare 的握手包在 GFW 被丢弃（实测：发出 handshake initiation，无任何回包）。
加入 AmneziaWG junk 参数后握手成功 —— `jc: 4, jmin: 40, jmax: 70`（不要用 120/911 的激进值，反而不通）。

### 关键配置（三个坑，缺一不可）

```json
{
  "type": "warp",
  "tag": "warp-direct",
  "system": false,
  "name": "warp1",
  "amnezia": { "jc": 4, "jmin": 40, "jmax": 70 },
  "profile": { "detour": "bond-cc", "recreate": true },
  "address": "162.159.192.1",
  "port": 2408,
  "domain_resolver": "dns-warp"
}
```

| 坑 | 现象 | 解法 |
|---|---|---|
| **1. 注册被 FakeIP 污染** | `Post /reg: write tcp ...->198.18.0.2:443` | `profile.detour` 指向可用代理，注册请求由远端服务器解析域名，本地不查 DNS |
| **2. 内容 DNS 被劫持** | 只有非代理域名能通，google/github 全超时 | 专用 DoH `{type:https, server:1.1.1.1, detour:"warp-direct"}` — 走隧道内 TCP443，不经过被劫持的 53 端口 |
| **3. peer 用域名形成循环** | `failed to resolve endpoints: context deadline exceeded` | peer `address` 必须写 IP 字面量 `162.159.192.1`，隧道建立不需要 DNS |

配套 DNS 服务器：
```json
{ "tag": "dns-warp", "type": "https", "server": "1.1.1.1",
  "detour": "warp-direct", "tls": { "enabled": true, "server_name": "cloudflare-dns.com" } }
```

> ⚠️ `warp` 端点**不支持** `s1/s2/h1-h4` 参数（会 `FATAL: unknown field "s1"` 导致 sing-box 启动失败），只支持 `jc/jmin/jmax` 及 padding/timing 系列。`wireguard` 端点才支持全套。

### 实测数据（2026-09-15）

| 线路 | 吞吐 | 延迟 | 说明 |
|---|---|---|---|
| `warp-direct` | **19.18 Mbps** | 3324 ms | 独立出口，绕开所有 VPS |
| `cc-HY2` | 38.53 Mbps | 415 ms | 主力（经 148） |
| `bond-cc` | 41.77 Mbps | 393 ms | 默认（148 双协议聚合） |

### 出口地区说明

Cloudflare WARP 出口地区由**账号注册地**决定，不由端点 IP 决定。实测 7 个常见 CF 端点
（162.159.192.1 / 162.159.193.1 / 188.114.96-99.1 / 162.159.195.1）出口全部为 `104.28.195.192 / colo=LAX / loc=US`。
**要拿 HK/JP 出口，必须在 HK/JP 的 IP 上注册 WARP 账号**（`profile.detour` 指向 HK/JP 出口即可）。

---

## 第二出口（备选）：AmneziaWG 隧道到 148

```
[88.4] --AmneziaWG(jc 混淆, UDP 10003)--> [148] --> [WARP] --> 互联网
```

- 服务端配置: `configs/148-cc/35_cc-awg-endpoint.json`（`wireguard` 端点 + anmezia 全套参数）
- 148 路由规则: `{"inbound": ["awg-in"], "outbound": "warp-ep"}` → AmneziaWG 进来的流量走 WARP 出口
- 客户端: 88.4 的 `awg-cc` 端点，`amnezia: {jc:4, jmin:40, jmax:70, s1:0, s2:0, h1:1..h4:4}`
- ⚠️ 实测吞吐仅 **0.18 Mbps**（瓶颈在 88.4↔148 的 userspace WG 段，148 侧 WARP 单独测有 205 Mbps）
- ⚠️ 该路径仍依赖 148，价值低于 `warp-direct`

### WARP 服务端能力实测（148）

| 项目 | 结果 |
|---|---|
| 148 直连下载 | 342 Mbps |
| 148 经 WARP 下载 | **205 Mbps** |
| 88.4 直连 WARP | 19 Mbps |
| 88.4 经 AmneziaWG→148→WARP | 0.18 Mbps（不可用） |

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

### Reality 认证失败（processed invalid connection）

**症状**: 客户端 TLS 阶段被 RST，服务端 `box.log` 出现：
```
ERROR inbound/vless[cc-reality]: TLS handshake: REALITY: processed invalid connection
```

**根因**: 客户端 `tls.reality.public_key` 与服务端 `reality.private_key` 不是同一对密钥。

**解决**: 由服务端私钥派生公钥（见附录 Python 片段）后写入客户端，服务端与客户端 `short_id` 也要一致。

**验证**: `curl -x http://192.168.88.4:7891 https://www.gstatic.com/generate_204` 应返回 204。

### 服务端端口被 realm 占用（107）

**症状**: `FATAL start inbound/vless[rn-reality]: listen tcp 0.0.0.0:10000: bind: address already in use`

**原因**: 107 上的 `realm`(zhboner/realm) 中继占用了 10000-10011、10022、30281-30282。

**处置**（2026-09-15 已执行，用户确认 realm 不再需要）:
```bash
systemctl stop realm && systemctl disable realm
killall -9 realm          # systemd 停止后可能残留第二个实例
cp /etc/realm.json /root/realm-disabled-20260915/   # 配置已备份
```

### cache_file 初始化超时（服务端）

**症状**: `FATAL start service: initialize cache-file: timeout`

**根因**: bbolt 对 `/etc/sing-box/cache.db` 加排他锁；**旧 sing-box 进程未退出仍持有锁**，新实例 5s 后超时。

**解决**:
```bash
systemctl stop sing-box; killall -9 sing-box   # 确认 0 个残留进程
ps aux | grep '[s]ing-box run'
systemctl start sing-box
```

> 注意 `killall` 对已 `nohup` 启动的实例可能失效，必要时 `kill -9 <PID>`。

### 客户端标签命名规范

出站标签统一 `cc-*`(148) / `rn-*`(107)，与服务端 inbound 标签一一对应（`cc-reality` / `cc-xhttp` / `cc-hy2` / `cc-tuic` / `cc-bond`）。
改名时必须同步更新 `proxy` selector 的 `outbounds` 列表与 `default`，否则 Clash 面板切不动节点。

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
| `configs/88.4-sing-box-v13.json` | 88.4 客户端最终配置（cc-*/rn-* 统一命名） |
| `configs/88.4-sing-box-v12.json` | 上一版（HK-*/RN-* 命名），回滚用 |
| `configs/148-cc/` | 148 全部 inbound（cc-*） |
| `configs/107-rn/` | 107 全部 inbound（rn-*） |
| `scripts/singbox-watchdog.sh` | 看门狗脚本（当前未启用） |

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

### Reality Keypair 参考（2026-09-15 实测校验）

| 用途 | PrivateKey（服务端） | PublicKey（客户端） |
|---|---|---|
| 148 `cc-reality` :10000 | `6N9tOw3QOntBnALU0Xg-sAdzIYy5-E5LEv8tZXAd53w` | `DCbnS4mIPc1W2-wI0MGHhykwzf2nVuZvBadErSE6MxU` |
| 148 `cc-xhttp` :8443 | `2J29hyLn-essLpmjd7jBfOiMlx_sGDvAI7gCb-t8Ino` | `WjI3RtUeYBHCKhdv96xfN8FT4yWux2RU_RMoq2zSDXc` |
| 107 `rn-reality` :10000 | `kKWeFYkevzKDxaUjHWltihiU6xefJ5zZyVFKuBn8LnY` | `TU4gTCw7Ba9ZtclTKUnl9FDRcJYANyIpCVfgfKPtKQk` |
| 107 `rn-xhttp` :8443 | `sMgSngQoqibHsNTFImFL6qcCndo0-OYZoc22dfxlKkg` | `sSd8pr2G9jBWX9OsTAaE2yPk9U0FjPnrWesID7tCn08` |

**short_id 统一**: `a1b2c3d4`

> ⚠️ **客户端 `public_key` 必须由服务端 `private_key` 派生，不能凭记忆或抄文档。**
> 抄错的表现是服务端日志出现 `REALITY: processed invalid connection`，客户端表现为连接被 RST。
>
> 派生校验（本地 Python，已验证与 `sing-box generate reality-keypair` 输出一致）：
> ```python
> import base64
> from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
> from cryptography.hazmat.primitives import serialization
>
> def pub_from_priv(b64priv):
>     raw = base64.urlsafe_b64decode(b64priv + '=' * (-len(b64priv) % 4))
>     k = X25519PrivateKey.from_private_bytes(raw)
>     return base64.urlsafe_b64encode(k.public_key().public_bytes(
>         serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode().rstrip('=')
>
> print(pub_from_priv("2J29hyLn-essLpmjd7jBfOiMlx_sGDvAI7gCb-t8Ino"))
> # -> WjI3RtUeYBHCKhdv96xfN8FT4yWux2RU_RMoq2zSDXc
> ```
