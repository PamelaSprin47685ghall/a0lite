# 760K 网络通路追查（换内核后整机失联）

- 追查时间：2026-11-17 23:24–23:40（本机 `7940HS`）
- 触发：`ssh -p 12022 root@127.0.0.1` 的 frpc xtcp visitor 报 `xtcp server for [ssh-tunnel-12022-xtcp] doesn't exist`
- 边界：**纯只读排查**。未修改任何配置，未重启任何服务，未安装软件，未扫描公网（只对配置里已知的 frps 地址与端口做过单点探测）。
- 结论先行：
  1. 本机在 `192.168.123.0/24`，Wi-Fi `wlp4s0` = `192.168.123.80/24`，网关 `192.168.123.254`；另有一条 mihomo 的 TUN `Meta`（`198.18.0.1/30`）。
  2. 本机是 **frpc 客户端**（不是 frps）：唯一进程 `frpc -c /etc/frp/frpc.toml`，用户 `frpc`(uid 955)，控制通道到 `83.136.210.113:7000` 一直 ESTAB，**本机侧完全健康**。
  3. 760K 的最后局域网地址是 **`192.168.123.92`**（frpc 日志 22:57:30 的 xtcp 打洞对端），现在该地址 ARP `INCOMPLETE`；ARP 表里**没有留下 760K 的 MAC**。
  4. 局域网 22 端口只有 `192.168.123.43`（7640HS）、`.97`（lubancat）、`.253`/`.254`（路由器）开放；**12022 在整个网段没有任何监听**，760K 不在线。
  5. 最可行救援：等 760K 的 frpc 重新注册（本机 visitor 会自动恢复，无需操作），同时借已可登录的 `192.168.123.43` 做同网段盯梢；若 24 小时仍无 ARP、无注册、公网 `frp.kw92.cyou:12022` 无 banner，则只能物理介入。

---

## 1. 本机网络身份

### 命令

```bash
ip -4 a; ip route; hostname; cat /etc/hosts
resolvectl status 2>/dev/null | head -30
cat /etc/resolv.conf; systemctl is-active systemd-resolved
```

### 原始输出

```
1: lo: <LOOPBACK,UP,LOWER_UP> ... inet 127.0.0.1/8 scope host lo
4: wlp4s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    inet 192.168.123.80/24 brd 192.168.123.255 scope global dynamic noprefixroute wlp4s0
6: Meta: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 9000 ...
    inet 198.18.0.1/30 brd 198.18.0.3 scope global Meta
```

```
default via 192.168.123.254 dev wlp4s0 proto dhcp src 192.168.123.80 metric 600
192.168.123.0/24 dev wlp4s0 proto kernel scope link src 192.168.123.80 metric 600
198.18.0.0/30 dev Meta proto kernel scope link src 198.18.0.1
```

```
7940HS
```

```
# /etc/hosts
127.0.0.1  localhost
::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters
83.136.210.113 frp.kw92.cyou
```

```
# /etc/resolv.conf (NetworkManager)
nameserver 114.114.114.114
nameserver fe80::1%wlp4s0
systemd-resolved: inactive
resolvectl status: (空)
```

补充：`hostname -I` 在本机不支持（`/usr/bin/hostname` 无 `-I`），已用 `ip -4 a` 代替；无线链路 `iw dev wlp4s0 link` 显示连在 `KunweiTYN_5G`，信号 −65 dBm。

### 判断

- 本机是单无线网卡的有线/无线双栈主机，`eno1`/`enp3s0` 均 `NO-CARRIER`，**唯一出口是 Wi-Fi**。
- `frp.kw92.cyou` 在 `/etc/hosts` 里硬编码为 `83.136.210.113`，**不依赖 DNS**，因此“域名解析失败”不是本次故障原因。
- 网段就是 `192.168.123.0/24`，网关 `.254`（实测 dropbear，见 §5）。

---

## 2. frpc / frps 在本机的角色

### 命令与输出

```bash
pgrep -af frpc; pgrep -af frps
systemctl list-units --all | grep -i frp
systemctl cat frpc.service frpc-bypass-tun.service
ss -tn | grep ':7000'
stat -c '%A %U:%G %n' /etc/frp
```

```
277490 /usr/local/bin/frpc -c /etc/frp/frpc.toml        # 唯一 frpc 进程，用户 frpc
（pgrep frps 无输出，rc=1：本机没有 frps）
```

```
frpc-bypass-tun.service  loaded active exited  Bypass mihomo Meta TUN for frpc (uidrange)
frpc.service             loaded active running frp client - SSH tunnel (22 -> frp.kw92.cyou:11022)
```

```
# frpc.service
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
# /etc/systemd/system/frpc.service.d/10-bypass-tun.conf
[Service]
User=frpc
Group=frpc
```

```
# frpc-bypass-tun.service（oneshot, RemainAfterExit=yes）
ExecStart=/usr/local/sbin/frpc-bypass-tun
Active: active (exited) since Sun 2026-11-15 22:41:42 CST
```

```
drwxr-x--- root:frpc /etc/frp          # frpc.toml 本身 Permission denied；sudo -n 需要密码
ESTAB 192.168.123.80:44630  83.136.210.113:7000
```

从 journal 还原出的实际注册项（**这比读配置文件更可靠**，因为配置文件不可读）：

```
proxy added:   [localspace ssh-tunnel-11022 ssh-tunnel-11022-xtcp]
visitor added: [ssh-tunnel-10022-xtcp-visitor ssh-tunnel-12022-xtcp-visitor
                ssh-tunnel-13022-xtcp-visitor ssh-tunnel-14022-xtcp-visitor
                ssh-tunnel-15022-xtcp-visitor]
```

本机监听中与之对应：

```
LISTEN 127.0.0.1:10022 / 12022 / 13022 / 14022 / 15022
```

另有一份**用户级、非运行中的**配置 `/home/kunweiz/.config/frp/frpc.toml`（结构贴出，secret 打码）：

```toml
serverAddr = "frp.kw92.cyou"
serverPort = 7000

auth.method = "token"
auth.token = "<redacted>"

[[proxies]]
name = "devspace"
type = "tcp"
localIP = "127.0.0.1"
localPort = 7676
remotePort = 7676
```

### 判断

- 本机是 **frpc 客户端**，同时承担两个方向：
  - **出站代理**：`localspace`、`ssh-tunnel-11022`、`ssh-tunnel-11022-xtcp`（把本机 22 暴露为 `frp.kw92.cyou:11022`，实测 banner 为 `SSH-2.0-OpenSSH_10.6`，与本机 sshd 一致）。
  - **入站 visitor**：10022/12022/13022/14022/15022 五个 xtcp visitor，本机 `127.0.0.1:12022` 就是通往 760K 的入口。
- `frpc.service` 的 `Restart=always` + 控制通道 ESTAB，说明**本机 frpc 没有掉线**；报错是 frps 侧在拒绝 visitor 的打洞请求，不是本机进程问题。
- `/etc/frp/frpc.toml` 属 `root:frpc 0750`，`kunweiz` 读不到，`sudo -n` 要求密码，因此**无法贴出 visitor 的 `server_addr`/`server_port`/`secret` 字段**；只能由日志证明 visitor 名称与端口。`~/.config/frp/frpc.toml` 是历史遗留的用户配置（`devspace` 7676），**不是**当前运行的配置，不能拿它判断隧道拓扑；它把 token 以明文存放在用户可读路径，属既有安全隐患，本轮不改。

---

## 3. mihomo 的角色

### 命令与输出

```bash
pgrep -af mihomo; ps -o pid,lstart,cmd -p 1538074
ss -ltnp | grep -E ':(7890|7899)\b'
ip link show; ip rule show; ip route show table 2022
ip route get 83.136.210.113
```

```
1538074 /opt/mihomo/mihomo -d /opt/mihomo
STARTED Tue Nov 17 22:11:43 2026
LISTEN 127.0.0.1:7890            # 只有 7890，没有 7899
```

```
6: Meta: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 9000 link/none
    inet 198.18.0.1/30
```

```
0:     from all lookup local
8900:  from all uidrange 955-955 lookup main          # frpc 绕过 TUN
9000:  from all to 198.18.0.0/30 lookup 2022
9001:  not from all dport 53 lookup main suppress_prefixlength 0
9001:  from all iif Meta goto 9010
9002:  not from all iif lo lookup 2022
9002:  from 0.0.0.0 iif lo lookup 2022
9002:  from 198.18.0.0/30 iif lo lookup 2022
9010:  from all nop
32766: from all lookup main
```

```
table 2022: default via 198.18.0.2 dev Meta
table main: default via 192.168.123.254 dev wlp4s0
ip route get 83.136.210.113 → via 198.18.0.2 dev Meta table 2022 src 198.18.0.1 uid 1000
```

### 判断

- mihomo 在跑，TUN 设备名 **`Meta`**（不是 `utun`/`mihomo`），有 `198.18.0.1/30`；**没有 `198.18.0.0/15` 的路由**，只有 `/30` 直连 + 策略路由表 2022 的默认路由 `198.18.0.2`。
- 普通进程（uid 1000）访问 `83.136.210.113` 会走 TUN → mihomo 代理；**frpc 被 `uidrange 955-955 lookup main` 规则单独放行，直连 Wi-Fi**。这解释了为什么 frpc 的控制连接源地址是 `192.168.123.80` 而不是 `198.18.0.1`。
- mihomo 于 **22:11:43** 重启过，但 760K 的隧道在 22:57 仍成功打洞、23:04–23:06 仍可 SSH，所以 **mihomo 重启与 23:12 失联没有时间相关性**；且 visitor 报错来自 frps，与本地出口无关。

---

## 4. ARP 与邻居表

### 命令与输出

```bash
ip neigh; arp -an 2>/dev/null
journalctl -k | grep -iE 'ath|r8169|enp|link up|link down' | tail -30
dmesg | grep -iE 'wlp4s0.*(associated|disconnect|deauth)' | tail
```

```
192.168.123.253 dev wlp4s0 lladdr ce:81:da:35:00:30 STALE
192.168.123.79  dev wlp4s0 lladdr ce:81:da:35:00:30 STALE
192.168.123.208 dev wlp4s0 lladdr ce:81:da:35:00:30 STALE
192.168.123.38  dev wlp4s0 lladdr 62:7d:be:a5:ad:f3 STALE
192.168.123.43  dev wlp4s0 lladdr 1c:79:2d:5b:5c:fa STALE
192.168.123.97  dev wlp4s0 lladdr 02:51:22:e5:67:53 STALE
192.168.123.254 dev wlp4s0 lladdr dc:d8:7c:d6:82:0e REACHABLE
192.168.123.84  dev wlp4s0 FAILED
192.168.123.92  dev wlp4s0 FAILED / INCOMPLETE
fe80::1 dev wlp4s0 lladdr 14:ab:02:53:c0:ef router REACHABLE
```

```
（arp 命令不存在；journalctl -k 只有 Nov 16 19:23 的 OOM 调用栈，没有网卡 link up/down 事件）
```

760K 的“历史 IP”唯一硬证据来自 frpc 日志：

```
2026-11-17 22:57:30 [I] [visitor/xtcp.go:312] [ssh-tunnel-12022-xtcp-visitor]
establishing nat hole connection successful, remoteAddr [192.168.123.92:43318]
```

### 判断

- **ARP 表里没有 760K 的 MAC**。`.92` 现在是 `INCOMPLETE`（本机与 7640HS 上都一样），`.84` 是 `FAILED`。
- 760K 的最后局域网地址是 `192.168.123.92`（22:57:30 打洞对端），不是 `192.168.123.84`。`.84` 只出现在 `~/.ssh/config` 的历史别名里（见 §6），不能当成本次故障的定位依据。
- `.253`/`.79`/`.208` 共用 `ce:81:da:35:00:30`（Mesh AP），`.254` 是主路由，`.43`、`.97` 是主机，`.38` 是随机 MAC 的 IoT 类设备。
- 内核日志没有任何无线 link down 记录，**失联发生在 760K 那一侧**，不是本机 Wi-Fi 掉线。

---

## 5. 扫描局域网找 760K

### 方法

先确认网段：`192.168.123.0/24`（§1）。只做 TCP 22/12022 的轻量探测，每个目标 1 秒超时，最多 64 并发；不做全端口、不用 nmap。

### 命令

```bash
seq 1 254 | xargs -P 64 -I{} sh -c \
  'ip=192.168.123.{}; for p in 22 12022; do
     timeout 1 bash -c "echo > /dev/tcp/$ip/$p" 2>/dev/null && echo "$ip:$p open"; done' \
  | sort -t. -k4,4n
```

### 输出

```
192.168.123.43:22 open
192.168.123.97:22 open
192.168.123.253:22 open
192.168.123.254:22 open
```

（12022 全网段无开放；`.92`、`.84` 不在结果中。）

对开放 22 的主机取 banner：

```
192.168.123.43  -> SSH-2.0-OpenSSH_10.6
192.168.123.97  -> SSH-2.0-OpenSSH_10.2p1 Ubuntu-2ubuntu3.8
192.168.123.253 -> SSH-2.0-dropbear_2017.75
192.168.123.254 -> SSH-2.0-dropbear_2025.88
```

进一步确认身份（只读命令 `hostname; uname -r`）：

```
192.168.123.43  -> hostname 7640HS, kernel 7.3.0-rc6-1-MANJARO, uptime 9 days 10:18
192.168.123.97  -> hostname lubancat, kernel 6.1.172, uptime 5 days 17:02
```

补充：`.79:80` 开放（AP 管理页），`.38/.79/.208` 无 22。

### 判断

- **760K 没有出现在局域网里**：既不在 `.92`，也没有以新 IP 出现（整个网段 12022 无监听、22 只有四台已知设备）。
- `.43` 是另一台同门 Manjaro 小主机（`7640HS`，仍是 rc 内核、uptime 9 天），**不是 760K**，但它同网段、可登录，正是最有用的观察点。
- `.97` 是 ARM 板（`lubancat`），`.253/.254` 是路由器/AP。
- 760K 的 hostkey 指纹无法用于比对：本机 `known_hosts` 里没有 760K 的任何条目（见 §6），因此无法用 `ssh-keyscan | ssh-keygen -lf` 做指纹匹配。目前只能靠“hostname=760K、内核从 rc 换成稳定版”这两个特征识别它回归后的新 IP。

---

## 6. known_hosts 与历史会话

### 命令与输出

```bash
grep -c '' ~/.ssh/known_hosts
ssh-keygen -F 127.0.0.1 -f ~/.ssh/known_hosts
ssh-keygen -F 760K -f ~/.ssh/known_hosts
cut -d' ' -f1 ~/.ssh/known_hosts | sort -u
grep -rn '760K\|12022\|192.168' ~/.ssh/config /etc/ssh/ssh_config.d/
sed -E 's/(IdentityFile|ProxyCommand).*/\1 <redacted>/' ~/.ssh/config
grep -nE '760K|12022' ~/.bash_history | tail
```

```
11
（ssh-keygen -F 127.0.0.1：空）
（ssh-keygen -F 760K：空）
ai.kw92.cyou
192.168.123.253
192.168.123.254
192.168.123.43
192.168.123.97
```

```
~/.ssh/config:11:Host 45.11.1.62 192.168.123.84
```

```
Host ai-xtcp
    HostName 127.0.0.1
    Port 10023
    User root

Host 45.11.1.62
    ProxyCommand <redacted>
    ConnectTimeout 20

Host 45.11.1.62 192.168.123.84
    ControlMaster auto
    ControlPath /home/kunweiz/.ssh/sm-%r@%h:%p
    ControlPersist 600
```

```
.bash_history:487  ssh -p12022 root@127.0.0.1
.bash_history:489  ssh -p12022 root@frp.kw92.cyou
...
```

### 判断

- `known_hosts` 只有 11 行、5 个主机：`ai.kw92.cyou`、`.253`、`.254`、`.43`、`.97`。**没有 `[127.0.0.1]:12022`，也没有 `.84/.92`**。说明此前连 760K 的 SSH 是用别的工作目录/别的主机键库（或每次都 `UserKnownHostsFile=/dev/null`），本账户没有留存 760K 的 hostkey，指纹比对这条路走不通。
- `~/.ssh/config` 里没有 `760K` 别名，也没有 12022 的 Host；`Host ai-xtcp` 指向 `127.0.0.1:10023`，该端口**当前没有监听**，是一条已失效的旧入口。
- `45.11.1.62` 与 `192.168.123.84` 共用一段配置，是另一处站点/路由的入口，与本次 760K（`.92`）不是同一台。
- **历史入口确认**：`ssh -p12022 root@frp.kw92.cyou` 曾被反复使用，说明除本地 visitor 外，760K 的 SSH 还曾经由 frps 的公网 12022 端口暴露（见 §7 的差异测试）。

---

## 7. frps 侧是否还能看到 760K 的代理

### 尝试管理接口

```bash
nc -vz 83.136.210.113 7500            # succeeded
curl -sS -m 5 http://83.136.210.113:7500/api/proxy/tcp        # 000, Empty reply
curl -skS -m 5 https://83.136.210.113:7500/api/proxy/tcp      # TLS unexpected eof
openssl s_client -connect 83.136.210.113:7500 </dev/null      # CONNECTED, no peer certificate
```

```
frps 7500 端口开放，但既不说 HTTP 也不说 TLS（空回复 / EOF）
本机没有任何可读的 frps 配置或 webServer 凭据（pgrep frps 无进程，/etc/frp 为 frpc 配置）
```

### 差异测试（替代证据）

| 端口 | 行为 | 含义 |
|---|---|---|
| `frp.kw92.cyou:11022` | 立即返回 `SSH-2.0-OpenSSH_10.6`，连接保持 | 本机 sshd 的 tcp 代理正常，**frps 转发链路健康** |
| `frp.kw92.cyou:12022` | TCP 接受，**6 秒后关闭，0 字节**；`ssh` 报 `Connection closed by 83.136.210.113 port 12022`；HTTP 请求 5 秒无响应 | frps 上存在 12022 的登记，但后端 work 连接取不到数据 |
| `frp.kw92.cyou:7000` | 控制端口开放，本机 frpc ESTAB | frps 主服务在线 |
| `83.136.210.113:80` | `301 → https://83.136.210.113/`，`Server: Caddy` | 同机另有 Caddy，与 frp 无关 |

### 判断

- frps 管理接口**不可用**（7500 非 HTTP/TLS，且没有凭据），因此拿不到 `last_start_time`/`last_close_time`，按任务要求跳过。
- 但差异测试给出了等价信息：**frps 本身健康**（11022 正常、7000 正常），而 **760K 的 xtcp 代理确实不存在**（visitor 报错 + 12022 无 banner）。
- 12022 的“接受后 6 秒关闭”有两种解释，目前无法区分：
  1. frps 侧还挂着一个 12022 的 tcp 代理登记，但它对应的 work 连接取不到数据（客户端半死）；
  2. 12022 由另一台/另一实例的代理占用，并非 760K。
  无论哪种，**都没有 SSH 服务可用**；要定性必须看 frps dashboard，这一条列为“未能确认”。

---

## 8. 是否有其他已建立的到 760K 的通路

### 命令与输出

```bash
ss -tnp | grep ESTAB | head -30
ip route get 83.136.210.113
```

```
192.168.123.80:44630      → 83.136.210.113:7000      # frpc 控制通道
192.168.123.80%wlp4s0:41582/41596/41608/41618 → 83.136.210.113:80   # syncmount / rclone（Caddy）
198.18.0.1:40054/40058/40068/40080 → 83.136.210.113:80             # syncmount 经 TUN
192.168.123.80%wlp4s0:46760 → 83.136.210.113:8000
127.0.0.1:12022  LISTEN（frpc visitor）
```

```
ip route get 83.136.210.113 → via 198.18.0.2 dev Meta table 2022 src 198.18.0.1 uid 1000
```

### 判断

- 没有任何到 760K 的已建立连接；唯一相关的是本机 frpc 到 frps 的控制通道。
- 到 `83.136.210.113` 的连接分两类：frpc（uid 955，走 main 表 → 直连 Wi-Fi）与 syncmount/rclone（uid 1000，走 TUN → mihomo）。**两类都只到 frps 主机，与 760K 无关。**
- 没有 WireGuard/Tailscale/ZeroTier 之类的备用接口（`ip -brief link` 只有 lo/wlp4s0/eno1/enp3s0/Meta）。

---

## 9. 失联时间线（本机 journal 证据）

| 时间（CST） | 事件 |
|---|---|
| 22:11:43 | mihomo 重启（与本故障无相关性） |
| **22:57:28** | `ssh-tunnel-12022-xtcp-visitor` nathole prepare success |
| **22:57:30** | 打洞成功，`remoteAddr [192.168.123.92:43318]`（760K 最后在线证据） |
| 23:04–23:06 | 本机对 760K 的部署前准备任务全部成功（备份、快照、sha256 对比） |
| **23:12:16** | 首次 `get tunnel connection error: timeout: no recent network activity`，随后 `xtcp server for [ssh-tunnel-12022-xtcp] doesn't exist` |
| 23:12–23:40 | 每 10 秒重复上述两条错误，持续至今 |
| 23:29 | 7640HS（`.43`）侧确认 `192.168.123.92` 为 `INCOMPLETE`，`.92:22`/`.92:12022` 均不通 |

补充事实：本机 frpc 在 23:00–23:14 没有任何 `login to server success`，说明 **frps 没有重启**；是 760K 那一侧的 frpc 消失（或它的 work 通道失效）。

### 判断

- 失联起点是 **23:12:16**，落在“23:06 仍正常 → 内核更换/重启”的窗口内，与换内核操作吻合。
- 症状不是“隧道建立失败”，而是“**对端代理不存在**”：760K 的 frpc 没有在 frps 上注册，或者注册已过期。
- 结合局域网扫描（`.92` ARP 不通、无新 IP），最可能是 **760K 没有正常起来 / 起来但没联网**；单看网络层无法区分这两种。

---

## 10. 可行的救援路径

按可行性排序。每条都给出前提与命令；本轮不执行任何修改。

### A. 等 frpc 自己重新注册（最可行，零操作）

**前提**：760K 能开机、能联网，frpc 服务 `enabled`（旧部署里是系统服务，开机自启）。
**命令**（本机）：

```bash
journalctl -u frpc -f | grep --line-buffered 12022
# 另开一个窗口：
while :; do date +%T; nc -z -w 2 127.0.0.1 12022 && echo open; sleep 10; done
```

**判据**：出现 `start proxy success` 或 visitor 不再报 `doesn't exist`，`ssh -p 12022 root@127.0.0.1` 能拿到 banner。
**代价**：0。**不需要重启本机 frpc**（它的控制通道一直正常，visitor 监听也一直在）。

### B. 借 7640HS（`192.168.123.43`）做同网段盯梢（现在就能做）

**前提**：`.43` 保持在线（当前 uptime 9 天、同 rc 内核、可免密 SSH）。
**命令**：

```bash
ssh 192.168.123.43 'ip neigh; ping -c 3 192.168.123.92'
# 盯梢：一旦 760K 回来，ARP 会立刻出现 MAC
ssh 192.168.123.43 'while :; do ip neigh show 192.168.123.92; sleep 15; done'
```

**判据**：`.92` 从 `INCOMPLETE` 变成 `REACHABLE` 并出现 `lladdr`，即可拿到 760K 的 MAC 与新 IP。
**价值**：这是当前唯一能“主动观察”的同网段探针；也能在 760K 换 IP 后第一时间发现（配合 B2 的 22 端口扫描）。

```bash
# B2：从 .43 轻量扫 22，找新 IP
ssh 192.168.123.43 'seq 1 254 | xargs -P 64 -I{} sh -c "timeout 1 bash -c \"echo > /dev/tcp/192.168.123.{}/22\" 2>/dev/null && echo 192.168.123.{}:22"'
```

### C. 局域网直连（760K 一上线就最快）

**前提**：760K 起得来且 Wi-Fi 正常；IP 仍是 `.92` 或由扫描发现新 IP。
**命令**：

```bash
ssh -p 22 root@192.168.123.92
# 若已换 IP：
ssh -p 22 root@<扫描到的 IP>
```

**当前**：`.92` ARP 不通，`.84` 也不通，不可行。

### D. 公网 frps 入口（与 A 同时恢复，备用）

**前提**：同 A；历史上可用。
**命令**：

```bash
ssh -p 12022 root@frp.kw92.cyou
```

**当前**：TCP 接受但 6 秒关闭、无 banner，不可行。恢复后它会和本地 visitor 同时可用，二者等价。

### E. 查 frps dashboard 的 `last_close_time`（不可用，除非拿到凭据）

**前提**：frps 的 webServer 端口说 HTTP 且有账号。
**现状**：7500 端口既不响应 HTTP 也不响应 TLS；本机没有 frps 配置或凭据。**跳过**。
若后续拿到凭据，用：

```bash
curl -u '<user>:<pass>' http://83.136.210.113:7500/api/proxy/tcp | jq '.[] | select(.name|test("12022"))'
```

### F. 物理介入（最后手段）

**前提**：A–D 全部无效。
**判据**：到 **2026-11-18 23:12**（失联满 24 小时）仍满足：`.92` 无 ARP、frpc 日志无新注册、`frp.kw92.cyou:12022` 无 banner。
**可能原因**（按概率）：新内核缺少/不匹配无线驱动或固件 → 机器起来了但没网；nvidia 驱动与内核不匹配导致启动停在图形阶段；引导失败。三者都需要键盘/显示器或串口/IPMI 才能区分。
**动作**：接显示器与键盘，看是否停在 initramfs/黑屏；或用 Live USB 挂载根分区检查 `journalctl -b -1`。**本轮不做。**

### 不要做的事

- **不要重启本机 `frpc`/`mihomo`**：本机控制通道与 visitor 监听都正常，重启无益且会打断其他 visitor（10022/13022/14022/15022）。
- **不要改 `frpc.toml` 或 override**：问题在对端注册，不在本机配置。
- **不要扫公网**：除已知的 `frp.kw92.cyou` 端口外，没有做任何公网探测。

---

## 11. 未能确认 / 限制

1. **`/etc/frp/frpc.toml` 内容不可读**（`root:frpc 0750`，`sudo` 需要密码）。因此 visitor 的 `server_addr`/`server_port`/`secret` 无法贴出，只能由日志证明 `ssh-tunnel-12022-xtcp-visitor` 存在、监听 `127.0.0.1:12022`。
2. **760K 的 MAC 无法获得**：本机与 7640HS 的 ARP 都没有历史条目，`.92` 已是 `INCOMPLETE`。只能用“最后 LAN IP = 192.168.123.92”定位。
3. **frps 管理接口不可用**：7500 非 HTTP/TLS，且无凭据，`last_start_time`/`last_close_time` 拿不到。
4. **12022 在 frps 上“接受后 6 秒关闭”的归属未定**：可能是 760K 的半死 tcp 代理，也可能是另一台设备的代理。要定性只能看 dashboard。
5. **没有 760K 的 hostkey 指纹**：本账户 `known_hosts` 不含 760K，无法用指纹确认“回归的新 IP 就是 760K”；只能用 hostname/内核特征人工确认。
6. 未做任何修改、未停服务、未安装软件、未扫公网；以上全部为只读探测。
