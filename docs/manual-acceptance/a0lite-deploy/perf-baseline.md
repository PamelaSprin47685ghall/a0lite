# a0lite 性能基线（首屏 / 视图 / 运行时 / 包体）

- 日期：2026-11-18 04:57–05:22。实例 `http://127.0.0.1:5080`，flatpak commit `ab3d8e61`；`/api/health` 报源码 `058582f-dirty`，两者分层，别混用。
- Chrome 156.0.8078.79 `--headless=new`，1440×900，每轮独立临时 profile，全走 loopback；CDP 的 `Network.*`/`Performance.getMetrics`/`Page.captureScreenshot` 采集，LCP 由导航前注入的 `PerformanceObserver(buffered:true)` 记录。未构建、未改码、未重启实例；D9（`flatpak run` 到 health 200）需停实例，**跳过**。截图 `perf-firstpaint.png`，六视图在 `/tmp/a0perf/shot-*.png`。

## §1 首屏（冷 profile ×3）

首页 `/` 只出 splash，再用 `fetch /ui/index` + `document.write` 换页，`loadEventEnd` 只覆盖 splash（13–35 ms），不代表 UI。下表主指标是 `#chat-input` 出现。

| 轮次 | UI 就绪 ms | FCP ms | LCP ms | DCL ms | load ms | 请求 | page 会话传输 |
|---|---|---|---|---|---|---|---|
| 1 | 1212 | 496 | 952 | 19 | 20 | 364 | 2,385,374 B |
| 2 | 1347 | 492 | 948 | 33 | 35 | 364 | 2,385,374 B |
| 3 | 730 | 348 | 568 | 13 | 13 | 364 | 2,385,374 B |
| **中位** | **1212** | **492** | **948** | **19** | **20** | **364** | **2,385,374 B** |

LCP 元素是 welcome 区的 `H1`（"Hello! I'm Agent Zero"）。传输字节 = `loadingFinished.encodedDataLength` 的 page 会话合计；297/366 个响应由 Service Worker 返回并记 0 字节，所以它**不是**网络成本。旁路 SW 复测 3 次（`Network.setBypassServiceWorker`）：UI 就绪 687 / 1165 / 1272 ms（中位 **1165**），FCP 344 / 504 / 564，LCP 584 / 972 / 1056，传输 **5,688,630 B / 365 请求**；两套中位差 47 ms，落在 0.7–1.3 s 方差内，**看不出 SW 的净收益或净损失**。

按类型（旁路 SW，覆盖全部 365 请求）：JS 156 个 2,627,761 B；JSON 24 个 1,150,452 B；字体 4 个 1,178,391 B；HTML 组件 139 个 466,303 B；CSS 32 个 246,556 B；图片 10 个 19,167 B。

最大单文件 `/ui/asset-bundle` 886,760 B，splash 用它向 SW 灌缓存，串在关键路径。抽查的 JS/CSS 均未压缩：`ace.js` 473 KB、`katex.min.js` 277 KB 原样传输。

## §2 六个视图

同一文档的 SPA：除 chat 外都是 modal/面板，没有各自的 `navigationStart`，故给“触发→内容可见”的毫秒；请求数取就绪后 1.2 s 窗口。chat 的 2431 ms 来自另一次独立会话，首屏三次中位 1212 ms（同指标实测 0.7–2.4 s）；files/speech 的 0 字节是 SW 命中。

| 视图 | 入口 | 就绪 ms | 请求 | 字节 |
|---|---|---|---|---|
| chat | 首屏文档 | 2431* | 363 | 2,207,690 |
| settings | `openModal(/components/settings/settings.html)` | 292 | 80 | 215,330 |
| files | `openModal(/components/modals/file-browser/file-browser.html)` | 227 | 2 | 0 |
| memory | `openModal(/plugins/_memory/webui/memory-dashboard.html)` | 217 | 6 | 12,976 |
| tools | `openModal(/plugins/_agent_editor/webui/main.html)` | 412 | 5 | 211,235 |
| speech | `openModal(/plugins/_kokoro_tts/webui/main.html)` | 192 | 2 | 0 |

最慢视图 **tools（412 ms）**，最慢“页面”仍是首屏。

## §3 最慢 10 个资源

Network 视角（`loadingFinished − requestWillBeSent`，含排队），同 URL 只留一次；耗时为 loopback，只看排序。另记 `/api/settings_get` 31,118 B / 274 ms、`/api/get_work_dir_files` 2,659 B / 254 ms、`/api/banners` 三次重复。

| # | 资源 | 字节 | 耗时 |
|---|---|---|---|
| 1 | `/api/plugins/_plugin_installer/plugin_install` | 177,356 | 2671–3637 ms |
| 2 | `/ui/asset-bundle` | 886,760 | 310 ms |
| 3 | `/vendor/katex/katex.min.js` | 276,862 | 94 ms |
| 4 | `/vendor/katex/katex.auto-render.min.js` | 3,478 | 94 ms |
| 5 | `/api/plugins_list` | 30,198 | 93 ms |
| 6 | `/js/manifest.json` | 480 | 93 ms |
| 7 | `/vendor/katex/katex.min.css` | 23,112 | 91 ms |
| 8 | `/vendor/ace-min/ace.min.css` | 24,695 | 90 ms |
| 9 | `/js/initFw.js` | 5,412 | 89 ms |
| 10 | `/vendor/ace-min/ace.js` | 472,738 | 77 ms |

## §4 堆与交互

- 首页空闲 30 s：`JSHeapUsedSize` **19,465,576 B（18.6 MiB）**，25,914 节点，1,677 监听器；就绪瞬间 16,994,088 B。空闲只涨 2.5 MB，无泄漏迹象。
- 六视图开合后空闲：23,945,352 B（22.8 MiB）；关 modal 后节点从 71,040 回落到 42,518。
- 聊天 ack：点击发送 → `#chat-history` 出现用户消息 **331.7 ms**；`POST /api/message_async` 同毫秒返回 200，随后进入 `Calling LLM...` 并出现 Stop。ack 是本地乐观渲染，不含模型。
- 设置页往返：首次打开 9 请求、关闭 2 请求、再打开还是同样 9 请求，**无缓存复用**；`model_config_get`、`plugins_list`、`projects` 各重复 2 次。
- 旁路 SW 会话 365 请求只对应 285 个唯一 URL；**`/components/sidebar/chats/chat-tree.html` 被请求 73 次**（= 当刻会话数，每个侧栏行一次；详见 §6.1），是请求数虚高的主因。空闲 30 s 内另有 20 个轮询请求。

## §5 包与磁盘

| 项 | 值 |
|---|---|
| `flatpak info --user` Installed Size | 125.1 MB |
| Runtime | `org.freedesktop.Platform/x86_64/25.08` |
| bundles | 主包 58 M（59,920,792 B）；Cuda 820 M（859,752,760 B）；Wps 48 M（50,210,888 B） |
| 已装 runtimes | Cuda 1.4 GB；Models 5.4 GB；Platform 670.9 MB |
| `~/.var/app/org.agentzero.AgentZero` | 1.4 G：`data/agent-zero` 1.3 G（venv 853 M、tmp 426 M、webui 19 M、usr 19 M、plugins 11 M）、`data/uv` 117 M、`cache` 4.8 M |
| 当前实例已运行 | 2543 s（42.4 min，`/proc/<pid>/stat` 推算；D10）。`tmp` 426 M 与 `venv` 853 M 可在运行时再生，交付包本身 58 M |

## §6 判定与建议

可接受：首屏 UI 中位 1.2 s、视图切换 0.19–0.41 s、ack 0.33 s、空闲堆 19 MB、主包 58 M。本机够用。

明显低效，按性价比排序：

1. **chat-tree.html 每个会话行一次请求**（73 次 / 73 会话、67 次 / 67 会话，恒等）：占首屏请求数 20%。改法见 §6.1，请求数可降到 1，但首屏无可测变化，属结构清理。
2. **静态资源不压缩**：156 个 JS 共 2.63 MB 原样传输。开 gzip/brotli 是最省事的一项。
3. **首屏加载用不到的库**：`ace.js` 473 KB、`katex` 277+23 KB 只在编辑器/公式场景用，却走首屏 `<script>`。改按需 `import()`。
4. **字体 1.18 MB**：rubik 360 KB + rubik-italic 355 KB + roboto-mono 184 KB + 图标 279 KB 全在首屏。按实际字重子集化可砍大半。
5. **`/ui/asset-bundle` 886 KB 串在 splash 关键路径**：它只为灌 SW 缓存，可改空闲预热，首屏不必等。
6. **插件市场索引 177 KB / 2.5–3.6 s**：`_discovery` 欢迎卡片在首页自动触发 `fetch_index`。延后到打开 Plugins 再拉，首屏少一个长尾。
7. **设置页 9 请求含 3 对重复且不复用**：`model_config_get`/`plugins_list`/`projects` 各打两次，二次打开也不命中缓存。

未观察到内存泄漏、白屏或运行时异常；首屏方差主要来自 asset-bundle 与 plugin_install 两个长尾请求的先后。

## §6.1 chat-tree.html 重复请求：根因与修复

**确切对象**：只有一条 URL，`/components/sidebar/chats/chat-tree.html`（2557 B，`cache-control: no-cache` + ETag），冷启动请求次数**恒等于会话数**：05:22 那轮 73 次 / 73 个会话，06:10 复测 67 次 / 67 个会话，06:34 已 68 个会话。全部无 `parent_context_id`，即侧栏每个顶层行各发一次。发起栈唯一：`importComponent@/js/components.js:40` ← `loadComponents@...:207` ← MutationObserver `@...:263`。

**谁在请求**：`webui/js/components.js` 的 `importComponent()`。`chats-list.html` 的 `x-for` 在一个 tick 内为每个会话建一个 `<x-component path="sidebar/chats/chat-tree.html">`（本次 67 个），全局 MutationObserver 逐个调用它。三处叠加：
1. `componentCache[componentUrl]` 只在 `await fetch()` + `await response.text()` **之后**写入（36–49 行），并发调用全都读到空值；
2. `importLocks` 的键是**目标元素**（8–22 行），每个节点各持一把锁，等于没按 URL 去重；
3. `chat-tree.html` 自己递归 include 自己（37 行），有子行时同样走这条路。

**不是**每次渲染都重取：缓存写入后再 import 同一组件不再发请求（warm 探针 0 次）。所以这 67 次只发生在首屏和每次整页刷新。

**代价（实测，与之前的估计不同）**：正常路径下这些请求全部由 Service Worker 从 Cache Storage 返回——`fromServiceWorker=true`、`encodedDataLength=0`、单请求 ≈1 ms、67 个请求的爆发窗口仅 **11–14 ms**。旁路 SW 时才落到网络：220–230 ms/个、264 B/个（仅响应头），完整体上限 67×2557≈171 KB。

**A/B 验证**：在页面里注入 fetch 去重钩子（同 URL 共享 Promise），请求数 67→1、窗口 13→1 ms；首屏 UI 就绪 baseline 566/603/701（中位 603）vs 去重 645/682/1059（中位 682）——**没有可测收益**，差异被 loadavg 3.4→4.5 的漂移吞掉。结论：这是结构性缺陷（20% 请求数花在一个文件上），但在 SW 正常工作时**不显著影响首屏**；风险在 SW 未生效或网络冷启动时放大成 200 ms 级爆发。

**最小修复**（`flatpak-ui.patch` 可承载，`-p1 -d /app/share/agent-zero`，路径 `a/webui/js/components.js`，已 `patch --dry-run` 通过）：把缓存值从「文本」改成「Promise」，并只在失败时删键：
```js
if (!componentCache[componentUrl]) {
  componentCache[componentUrl] = fetch(componentUrl).then((r) => {
    if (!r.ok) throw new Error(`Error loading component ${path}: ${r.statusText}`);
    return r.text();
  }).catch((e) => { delete componentCache[componentUrl]; throw e; });
}
const html = await componentCache[componentUrl];
```
**风险**：loader 同时服务 modal（`js/modals.js`），改的是缓存语义而非 DOM 语义——每个调用者仍各自 `DOMParser` 出独立文档，实例不共享；并发调用改为共享同一份 HTML 文本，行为等价。失败分支保留重试。**收益定位**：请求数 67→1、爆发窗口 13→1 ms，首屏无可测变化；值得做，但不要指望它提速。

## §7 建议的性质

**可修且低风险**：① 静态资源 gzip/brotli——JS 2.63 MB + CSS 247 KB + HTML 466 KB，估算降约 2.5 MB（gzip 比约 0.25），loopback 约 −50~150 ms，真实网络更大；② `ace.js`/`katex` 按需加载——−750 KB、−77~94 ms；③ 插件市场索引延后到打开 Plugins——−177 KB，去掉 2.5–3.6 s 长尾。

**不建议改**：④ 字体子集化（1.18 MB）要引入构建期 fonttools 流程并处理字形回退，本机收益仅数十 ms；⑤ `/ui/asset-bundle` 886 KB 是 SW 预热的前提，移出关键路径会让首屏二次加载或闪烁，属设计取舍；⑥ 设置页 3 对重复请求需 3 个 store 共享生命周期，收益仅约 90 ms、60 KB，改动面与回归风险不匹配。
