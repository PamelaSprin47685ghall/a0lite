# 760K 远程入口排查（2026-11-18 04:0x CST）

侦察机：本机 `7940HS`，`192.168.123.80/24`（wlp4s0），**与 760K 同网段**，故 ping/端口探测有效。
全部只读：未改配置、未启停服务、未起后台进程、未扫公网。

## 1. 已知入口表

| 通道 | 地址:端口 | 最后可用 | 本次探测结果 | 证据命令 |
|---|---|---|---|---|
| frpc XTCP visitor（主入口） | `root@127.0.0.1:12022` → 760K:22 | 2026-11-17 23:06 | 不可用：8 s 无 banner，banner 交换超时 | `ssh -p12022 root@127.0.0.1 true`；`journalctl -u frpc` |
| frps 公网直连（同一 proxy） | `root@frp.kw92.cyou:12022` | 历史可用（`760K-connectivity-hunt.md` §7） | 不可用：TCP accept，无 banner | `/dev/tcp/83.136.210.113/12022` + `head` |
| 局域网 SSH | `root@192.168.123.92:22` | 23:06 前 | 不可用：ARP FAILED，ping 100% 丢包，端口 no | `ping -c2 -W2`；`ip neigh`；`recon-target.md` §10 记有 `22 sshd` |
| 局域网 12022 | `192.168.123.92:12022` | 从未存在 | 不可用（12022 不在 760K 的 `ss` 表，只在本机回环） | `recon-target.md` §0；本次 no |
| 本地服务（仅回环，需先有 SSH） | `127.0.0.1:5080`（UI）/`:11434`（Ollama）/`:14500`（Xpra） | 23:06 | 不可用；三者均绑 127.0.0.1，不可从局域网直连 | `recon-target.md` §4/§5/§10 |
| frps 上 5080/11434/14500 | `frp.kw92.cyou:5080/11434/14500` | 文档称曾映射 760K | TCP accept，HTTP 000 / 空响应 | `curl -m6`；`/dev/tcp` |
| 旧公网 HTTPS | `https://ai.kw92.cyou:12443` | 未知（仅见于 `ALLOWED_ORIGINS`） | TCP OPEN，无 HTTP/TLS 响应 | 原始 `GET /` 无字节 |
| 旧 ssh 别名 | `ai-xtcp` → `127.0.0.1:10023` | 已失效 | 无监听 | `ss -ltn`；`~/.ssh/config` |
| 11022 | `frp.kw92.cyou:11022` | 在用 | **是本机 SSH，不是 760K** | `frpc.service` 描述 |

VPN / 带外（Tailscale / ZeroTier / WireGuard / IPMI / KVM）无任何证据：文档与本轮 grep 均无命中。

## 2. 本次新探测（原始输出摘录）

```text
$ ip route | head -2
default via 192.168.123.254 dev wlp4s0 src 192.168.123.80

$ ping -c2 -W2 192.168.123.92 → 2 packets transmitted, 0 received, 100% packet loss
$ ip neigh show 192.168.123.92 → 192.168.123.92 dev wlp4s0 FAILED   # 文档 23:40 记 INCOMPLETE，本轮实测 FAILED
$ 全 /24 ping sweep → ICMP 可达仅 .38 .43 .79 .80 .97 .208 .253 .254；无 .92
   （未回 ICMP 不排除在线，但 .92 另有 ARP + 20 端口双重失败）
$ 20 端口探测（子 shell /dev/tcp，每个 2 s）:
   22 80 443 3000 5080 5900 623 8080 9090 11434 14500 5000 8000 7676 5201 18080 18081 19000 7890 7899
   → 全部 no；对照网关 .254:80 OPEN，证明不是扫描假阴性
$ .43 复核（7640HS，wlp2s0）: ip neigh → FAILED；ping → 100% loss
$ .97 复核（lubancat，有线 eth0）: ping → 100% loss
$ ping -6 ff02::1 -I wlp4s0 → 仅 4 个邻居（本机、.43、.97、网关 .254），无第 5 台
$ ping -b 192.168.123.255 → 0 received（仅记录，无判别力）
```

```text
$ frps 端口 7000 7500 8080 12022 11022 10022 13022 14022 15022 12443 5080 11434 14500 6080 7676 22
  → 全部 TCP OPEN；frps 对未注册端口同样 accept 后立即关闭，OPEN 不代表 760K 在线
$ curl :7500/api/proxy/tcp → curl(52) Empty reply，无 401，0 字节；:8080 同
$ curl :5080/ → 000；:11434/api/version → 000；:14500/ → 000
$ journalctl -u frpc -n 60 → 03:44–03:59 每 10 s：xtcp server for [ssh-tunnel-12022-xtcp] doesn't exist
$ ~/.config/frp/frpc.toml → devspace 7676（历史遗留，非当前 760K 配置）；备份指向旧域名 ai.kw92.cyou
$ grep -rl 760K/12022/192.168.123 于 ~/Desktop/a0lite 与 ~/a0-local-backup → 仅文档与构建缓存，无第二通道配置
$ known_hosts 主机 → .253 .254 .43 .97 ai.kw92.cyou（无 760K，无法用指纹认领回归的新 IP）
```

760K 上另有 `5201/7676/18081/19000/18080/7890/7899` 监听（`recon-target.md` §10），文档未记绑定地址，历史可达性**无法判定**；本轮全 no，且 ARP 已失败，端口层无意义。

## 3. 结论

**没有 12022 之外的活路。**

- 760K 在二层完全不响应：IPv4 ARP `FAILED`，IPv6 链路本地组播也没有它。这不是某服务没起，而是整机未接入网络（关机 / 卡引导 / 网卡未起）。
- 承载 SSH 的只有 frpc XTCP 一个 proxy；`127.0.0.1:12022` 与 `frp.kw92.cyou:12022` 是它的两种连法，同生同死。03:59 仍报 `doesn't exist`，对端从未注册。
- 无 VPN、无 IPMI/BMC、无 DDNS/独立端口转发、无备用隧道。frps 面板不可读（无 HTTP 响应，连 401 都没有），无法取证注册历史。
- 三方独立复核（本机无线、`.43` 无线、`.97` 有线）一致，排除 AP 客户端隔离误判。

→ **只能物理/带外介入。** 现场三件事：

1. **接显示器 + 键盘**，开机连按 `Esc`（或按住 `Shift`）进 GRUB，选 `Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)`；记录停在 GRUB / initramfs / 黑屏 / 登录提示。
2. **清掉一次性引导项并固定旧内核**（进系统后，或 Live USB + `manjaro-chroot /mnt`）：
   `grub-editenv /boot/grub/grubenv unset next_entry`
   `grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'`
   再用 `grub-editenv list` 确认无 `next_entry`。
3. **回传最小诊断集**：`uname -r`、`ip -br a`、`nmcli device status`、`systemctl list-units | grep -i frp`（真实单元名从未确认）、`journalctl -u frpc -n 40`、`lsmod | grep tun`、`dmesg | grep -iE 'firmware|mt79|rtw|iwlwifi'`。无线没起就先插网线。

## 4. 不要做的事

- 不扫公网、不爆破 frps 面板、不猜凭据；7500/8080 空回复不是认证问题。
- 不向 `.43/.97/.253/.254` 做写操作；本轮只做过只读 ping / ARP / `hostname` 查询。
- 不改 frpc/frps 配置，不重启本机 `frpc`/`mihomo`（会打断 10022/13022/14022/15022 其他 visitor）。
- 不因 frps 端口 TCP OPEN 判定 760K 在线；也不要用 11022 判断 760K（那是本机 SSH）。
- 现场恢复时不要跑 `pacman -Syu`；先恢复启动与远程，再谈升级。

## frpc visitor 日志时间线

日志没有独立文件，全在 journald：`journalctl -u frpc`（`/var/log/frp*` 不存在）。单元 `/etc/systemd/system/frpc.service` + `frpc.service.d/10-bypass-tun.conf`（`User=frpc`，`Requires=frpc-bypass-tun.service`）；`/etc/frp/frpc.toml` 属 `root:frpc 0750`，本用户不可读。`~/.config/frp/frpc.toml` 只是历史遗留的 `devspace` 7676，不含 760K。

| 时间（CST） | 事件 | remoteAddr / 关键字段 |
|---|---|---|
| 11-17 14:59:14 | 五个 visitor 的 local/internal listener 全部 closed（frpc 重载） | — |
| 14:59:15 / 14:59:26 / 15:00:55 / 15:04:10 / 19:18:17 | `login to server success`，共 5 次重连；之后到 23:12 再没有 | run id `712035e83bddb673` |
| **22:57:28.948** | `nathole prepare success`，本机 assisted 为 `192.168.123.80:33697 198.18.0.1:33697` | nat type EasyNAT |
| 22:57:29.403 | `get natHoleRespMsg`，sid `1794927449e25a05a59c448495`，protocol quic | candidate `171.120.34.226:41105`；assisted `192.168.123.92:43318 10.81.0.2:43318 198.18.0.1:43318` |
| **22:57:30.427** | **最后一次成功**：`establishing nat hole connection successful` | **`192.168.123.92:43318`** |
| **23:12:16.108** | 第一条错误：`get tunnel connection error: timeout: no recent network activity` | 距重启 38 s |
| 23:12:16.342 | `nathole precheck error: xtcp server for [ssh-tunnel-12022-xtcp] doesn't exist` | 同秒即出现 |
| 23:12:36.109 | 首次 `open tunnel error: open tunnel timeout` | — |
| 23:12:16 → 05:06:56 | 累计 `doesn't exist` 497 次、`nathole precheck` 497 次、`open tunnel timeout` 436 次，约每 10 s 一轮 | 无一次 `prepare success` |

**`doesn't exist` 的语义**：frps 不预置 xtcp proxy，proxy 由 frpc 登录后动态注册（本机日志可见 `proxy added: [...]` → `start proxy success`）。所以它表示 **frps 上当前没有名为 `ssh-tunnel-12022-xtcp` 的已注册 proxy**，即 760K 的 frpc 控制连接已断开（进程消失或整机断电）。

排除"frps 重启/config 丢失"：若 frps 重启，本机 frpc 会重连并打印 `login to server success`，而 19:18:17 之后一条都没有；且 11022（本机自己的 SSH proxy）现在仍返回 `SSH-2.0-OpenSSH_10.6` banner，证明 frps 与本机注册均正常。时间线也吻合：23:11:38 执行 reboot → 38 s 后 QUIC 心跳超时 → 同秒 frps 注销 proxy。

## 路由器侧主机枚举

全段并发 ping + 立即读 ARP，另用 `.97`（lubancat，有线 eth0）独立复核；全段 TCP 22/12022 各扫一遍（每目标 1 s）。

| IP | MAC | 22 | 12022 | 身份 / 依据 |
|---|---|---|---|---|
| 192.168.123.38 | `62:7d:be:a5:ad:f3` | no | no | 随机 MAC 的 IoT 类设备 |
| 192.168.123.43 | `1c:79:2d:5b:5c:fa` | open | no | 7640HS（日志主机名） |
| 192.168.123.79 | `ce:81:da:35:00:30` | no | no | Mesh AP（与 .208/.253 同 MAC） |
| 192.168.123.97 | `02:51:22:e5:67:53` | open | no | lubancat（eth0 有线） |
| 192.168.123.208 | `ce:81:da:35:00:30` | no | no | Mesh AP |
| 192.168.123.253 | `ce:81:da:35:00:30` | open | no | RT-AC54U，HTTP 401 Basic |
| 192.168.123.254 | `dc:d8:7c:d6:82:0e` | open | no | JDC-1 主路由，HTTP 401 Basic |

- **活主机 7 台（不含本机），全段 12022 命中 0 台，全段 22 仅 4 台且身份全部已知**；`.97` 的 ARP 表也只有上述 6 个邻居 + 网关，`.92` 为 `FAILED`。
- 路由器 DHCP 列表**读不到**：`192.168.123.254`（JDC-1）与 `192.168.123.253`（RT-AC54U）都要 HTTP Basic（401），SSH 均为 `Permission denied (publickey,password)`；按边界未爆破、未改任何设置。
- 760K 的 MAC **无任何历史记录**：`recon-target.md` 只有 `Machine ID` / `Product UUID`，没有 `link/ether`；本机与 `.43` 的 ARP 也从未留下它的条目，无法用 OUI 反查。
- `10.81.0.2` 已排除：ping 不通，`10.81.0.2:22/12022` 的 "OPEN" 是 mihomo TUN 的假 accept（对照 `10.99.99.99:22` 同样 OPEN，ssh 均 `Connection closed`）；它更可能是 frps 主机的内网地址（`natHoleRespMsg` 的 assisted 字段由服务端给出），不是 760K 的第二个入口。

**"换 IP" 假说：排除（限定 `192.168.123.0/24`）**。该网段所有响应 ARP 的主机都已枚举，没有第 8 台未知主机；全段 12022 为 0。仅剩一种未观测可能：760K 连到了别的网段/SSID（本机与 `.97` 都看不到），但那要求它先正常启动并联网——与"整机二层不响应"并不矛盾，仍只能现场确认。
