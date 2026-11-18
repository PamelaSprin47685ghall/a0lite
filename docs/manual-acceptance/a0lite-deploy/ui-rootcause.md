# Settings / Projects 模态框主体空白：根因与最小修复

日期：2026-11-17
结论级别：**B. a0lite 打包问题**（运行树 webui 版本陈旧，与每次覆盖的 plugins 错配）
一句话根因：`flatpak/agent-zero.sh` 只对 `webui` 做一次性 seed（目录已存在就永不更新），却每次启动覆盖 `plugins`；升级后运行树留下**没有 `#welcome-channels` slot 的旧版 webui**，而新版 `_discovery` 插件无条件 `x-teleport="#welcome-channels"`。Alpine 3.14.9 在目标缺失时 `null.appendChild(...)` 抛 `TypeError`，该异常发生在 Alpine 全局 MutationObserver 的 `m()` 临界区内，`ue()` 重连被跳过，**observer 永久断开**；之后动态插入的 Settings / Projects 模态框不再被 `initTree`，所以主体空白。

---

## 1. `#welcome-channels` 定义与消费

### 1.1 定义（上游与 bundle）

```sh
rg -n 'welcome-channels' /home/kunweiz/Desktop/agent-zero/webui
```

输出：

```
/home/kunweiz/Desktop/agent-zero/webui/components/welcome/welcome-screen.html:135:                        <section id="welcome-channels" class="welcome-discovery-block" data-welcome-block="channels" data-welcome-label="Connect Channels" data-welcome-size="half"
```

bundle 内同样存在：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'grep -n "welcome-channels\|welcome-accounts" /app/share/agent-zero/webui/components/welcome/welcome-screen.html'
```

```
133:                        <section id="welcome-accounts" class="welcome-discovery-block" ...
135:                        <section id="welcome-channels" class="welcome-discovery-block" ...
```

上游结构（`welcome-screen.html` 第 10-13、120-137 行）：

- 第 10 行 `<template x-if="$store.welcomeStore">` 包住整个 welcome 容器；
- 第 56 行 `<div class="welcome-board">`；
- 第 133 行 `#welcome-accounts`，第 135 行 `#welcome-channels`；
- 第 173 行 `<x-extension id="welcome-actions-end">` 是插件注入点。

### 1.2 运行树：**没有这个 id**

```sh
rg -n 'welcome-channels' ~/.var/app/org.agentzero.AgentZero/data/agent-zero/webui
```

输出为空（exit 1）。运行树的 `welcome-screen.html` 是旧结构：

```sh
sed -n '128,143p' ~/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/components/welcome/welcome-screen.html
```

```
                    <section class="welcome-lower-grid">
                        <x-extension id="welcome-actions-end"></x-extension>

                        <article class="welcome-system-card"
                                 x-show="$store.welcomeStore.systemResourceBanner"
```

即：只有 `.welcome-lower-grid`，没有 `#welcome-channels` / `#welcome-accounts`，也没有上游的 `.welcome-board` 与 `welcome-layout.js`。

### 1.3 消费方（299 个警告的来源）

运行树全目录搜索：

```sh
rg -n 'welcome-channels' ~/.var/app/org.agentzero.AgentZero/data/agent-zero
```

```
.../plugins/_discovery/extensions/webui/welcome-actions-end/discovery-cards.html:12:
            <template x-teleport="#welcome-channels">
.../plugins/_discovery/AGENTS.md:20: ... teleports channels and the account-card list into `#welcome-channels` and `#welcome-accounts`; these slots must exist before the extension loads.
```

`discovery-cards.html` 第 12 行（channels）与第 57 行（accounts）各有一个 teleport：

```html
<template x-teleport="#welcome-channels">
  <section class="discovery-features-panel" ...>
...
<template x-teleport="#welcome-accounts">
  <div class="discovery-account-list">
```

该插件文件的 md5 在 **bundle / 运行树 / 上游三方一致**：

```sh
md5sum ~/.var/app/org.agentzero.AgentZero/data/agent-zero/plugins/_discovery/extensions/webui/welcome-actions-end/discovery-cards.html
flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'md5sum /app/share/agent-zero/plugins/_discovery/extensions/webui/welcome-actions-end/discovery-cards.html'
```

```
4ebd365e3316290ef8949b46b38d113c  .../discovery-cards.html
4ebd365e3316290ef8949b46b38d113c  .../discovery-cards.html
```

**结论**：一个定义（新版 welcome-screen），一个消费点（新版 _discovery 插件），但在运行树里定义缺席。CDP 观测到的 299（后续增长到 541）个 `x-teleport="#welcome-channels"` 不是 299 个不同消费者，而是同一模板在异常循环中的重复克隆，见 §3.3。

---

## 2. 两处 webui 是否一致：不一致，且是整棵树的新旧分叉

```sh
diff -rq /home/kunweiz/Desktop/agent-zero/webui \
          ~/.var/app/org.agentzero.AgentZero/data/agent-zero/webui 2>&1 | head -40
```

代表性输出：

```
Files .../webui/index.html and .../webui/index.html differ
Files .../webui/index.js and .../webui/index.js differ
Files .../webui/components/welcome/welcome-screen.html and .../welcome-screen.html differ
Files .../webui/components/welcome/welcome-store.js and .../welcome-store.js differ
Only in /home/kunweiz/Desktop/agent-zero/webui/components/welcome: welcome-layout.js
Only in ~/.var/app/.../webui/components/sidebar: tasks
Only in ~/.var/app/.../webui/css: scheduler.css
Only in ~/.var/app/.../webui/css: scheduler-datepicker.css
Files .../webui/components/modals/file-browser/file-browser.html and .../file-browser.html differ
Files .../webui/components/settings/settings.html and .../settings.html differ
...（共 60+ 条）
```

关键文件三方对比：

| 文件 | bundle `169f5e09` | 运行树 | 上游 `ba9b67d` | 判定 |
|---|---|---|---|---|
| `webui/components/welcome/welcome-screen.html` | 1015 行，`#welcome-channels` @135 | 785 行，无 slot | 1015 行，@135 | 运行树旧 |
| `webui/components/welcome/welcome-store.js` | 323 行，import `mountLayout` | 285 行，无 `mountLayout` | 323 行 | 运行树旧 |
| `webui/components/welcome/welcome-layout.js` | 存在（329 行） | **不存在** | 存在 | 运行树旧 |
| `webui/index.js` | 863 行，`/plugins/_scheduler/webui/sidebar/tasks-store.js` | 863 行，`/components/sidebar/tasks/tasks-store.js` | 863 行 | 运行树旧 |
| `webui/index.html` | 319 行 | 276 行 | 319 行 | 运行树旧 |
| `webui/components/sidebar/tasks/` | 不存在 | 存在 | 不存在 | 运行树旧 |
| `plugins/_discovery/.../discovery-cards.html` | 523 行，teleport @12 | 523 行，teleport @12 | 523 行 | 三方一致（新） |

文件数：

```sh
find ~/.var/app/org.agentzero.AgentZero/data/agent-zero/webui -type f | wc -l   # 889
flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'find /app/share/agent-zero/webui -type f | wc -l'                            # 879
```

bundle 内目录：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'find /app/share/agent-zero/webui -maxdepth 2 -type d | sort | head -30'
```

```
/app/share/agent-zero/webui
/app/share/agent-zero/webui/components
/app/share/agent-zero/webui/components/welcome
...
```

**结论**：不是「少复制了一个文件」，而是运行树的 `webui/` 整棵树停留在旧版本（第一次 seed 的版本），而 `plugins/` 每次启动被覆盖成新版。构建取源本身没问题（见 §5）。

---

## 3. Alpine 是否正常启动、异常是什么

### 3.1 版本与观察点

- Alpine `3.14.9`（`webui/vendor/alpine/alpine.min.js`，`version:"3.14.9"`）。
- `window.Alpine` 由 `js/initFw.js:17-19` 的 `await import("../vendor/alpine/alpine.min.js")` 建立；`index.js` 不直接 import Alpine。
- 观察到的 `[x-data]` 数量：首页正常时 5+（静态节点）；旧版异常时 `document.querySelectorAll('[x-data]').length = 5`，`x-component` 只停在前 5 个，welcome/settings 均未初始化。
- `document.querySelectorAll('[x-teleport]').length` 在旧版页面从 244 增长到 541，`document.documentElement.outerHTML.length` 从约 1.2 MB 增长到 4.3 MB，说明存在持续克隆/异常循环。

### 3.2 完整异常（CDP `Runtime.exceptionThrown`）

首行原文：

```
TypeError: Cannot read properties of null (reading 'appendChild')
    at s (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:27406)
    at http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:27429
    at m (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:2:1816)
    at Function.<anonymous> (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:27422)
    at r (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:2327)
    at n (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:2357)
    at fr (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:2367)
```

配套 console warning 原文：

```
Alpine Warning: Cannot find x-teleport element for selector: "#welcome-channels"
Alpine Expression Error: Cannot read properties of null (reading 'appendChild')

    Expression: "$store.discoveryStore"

     template
```

触发组件：`$store.discoveryStore` 所在的 `discovery-cards.html`（插件 `_discovery` 的 `welcome-actions-end` 扩展）。不是 Settings 组件本身。

实测计数（旧版运行树，SW 关闭后普通刷新）：首页加载 + 点击 Settings 后共 **16** 个 `appendChild` 异常；`#welcome-channels` = 0，`#welcome-accounts` = 0，`.settings-pane` = 0。修复前另一个会话在更长观察窗口内累计到 244/299/541 个，属于同一循环的累积。

### 3.3 异常为什么会「杀死」Settings

Alpine 3.14.9 的 `x-teleport` 实现（minified，`vendor/alpine/alpine.min.js`）：

```js
d("teleport",(e,{modifiers:t,expression:r},{cleanup:n})=>{
  e.tagName.toLowerCase()!=="template"&&E("x-teleport can only be used on a <template> tag",e);
  let i=xn(r),                      // document.querySelector(selector) -> null
      o=e.content.cloneNode(!0).firstElementChild;
  let s=(a,c,l)=>{ ... c.appendChild(a) };
  m(()=>{ s(o,i,t), A(()=>{ S(o) })() }), ...
});
function xn(e){let t=A(()=>document.querySelector(e),()=>qi)();return t||E(`Cannot find x-teleport element for selector: "${e}"`),t}
function E(e,...t){console.warn(`Alpine Warning: ${e}`,...t)}
function m(e){if(!ft)return e();dt();let t=e();return ue(),t}
```

要点：

1. `xn()` 找不到目标只 `console.warn`，返回 `null`；
2. `s(o, null, [])` 走 `null.appendChild(o)`，抛 `TypeError`；
3. 异常发生在 `m()` 的 `dt()`（disconnect observer）之后、`ue()`（reconnect）之前，且 `m()` **没有 `try/finally`**；`ft` 永久保持 false；
4. 之后 Alpine 的全局 MutationObserver 不再投递 `initTree`。Settings / Projects 的 `openModal()` 通过 `importComponent()` 只做 fetch + `appendChild`，本身**不调用** `Alpine.initTree`（`js/components.js`、`js/modals.js`、`js/extensions.js` 均无此调用），完全依赖该 observer；observer 已死，所以 `.modal-bd` 里只有模板源码（7837 字节），`x-if` 不求值，`onOpen()` 不执行，`.settings-pane` 不生成。

**决定性实验**（旧版运行树，Settings 已空白）：

```js
const modal = document.querySelector('.modal-inner.settings-modal');
Alpine.initTree(modal);
// 3 秒后：.settings-pane = 1，nav tabs = 7；
Alpine.store('settings').onOpen();
// 4 秒后：settings 数据 40 个 key，面板完整可见
```

说明后端、store、模板都正常，**唯一缺的是 Alpine 对动态 modal 的初始化**。

---

## 4. 资源 404 / CSP

CDP `Network.enable` + 干净导航（`?syncfix=...`，禁用缓存）记录：

- `status >= 400` 的响应：**0 个**；
- `Network.loadingFailed` 且 `blockedReason` 非空（CSP）：**0 个**；
- `/ui/index`、`/index.js`、`/vendor/alpine/alpine.min.js`、`/index.css`、`/components/**/*.html`、`/plugins/**/*.html` 均 200（`curl` 抽查同样 200）。

唯一一次 32 个 `net::ERR_CONNECTION_REFUSED` 出现在第一次 `Page.reload` 的瞬间（服务仍在启动/重载窗口），随后复测为 0；不是稳定根因。

**但有一个缓存层必须注意**：

- 页面由 Service Worker 控制：`navigator.serviceWorker.controller.scriptURL = http://127.0.0.1:5080/sw.js?version=749c98f1ffe4211405ab`。
- `/ui/asset-bundle`（splash 注册 SW 时预载）返回 `version: 749c98f1ffe4211405ab`，其中 `/components/welcome/welcome-screen.html` 为 **29130 字节、不含 `welcome-channels`**。
- 在运行树修改该文件（29346 字节，含 slot）之后，`/ui/asset-bundle` 的 version 与内容**都不变**。说明 bundle 是应用启动时生成的快照；只改磁盘文件、不重启，前端与 SW 都看不到新内容。
- 因此：用户「加 ALLOWED_ORIGINS 后仍空白」「全新 profile 也空白」与后端/CSRF 无关，而是旧 webui 本身；修复时也必须重启应用以重建 asset-bundle，并让 splash 用新的 `bundle.version` 注册新 SW（旧 cache 由 `sw.js` 的 `cleanupCaches()` 清理）。

---

## 5. 责任边界：B（a0lite 打包/seed），不是 A，也不是 C

### 5.1 排除 A（上游 bug）

- 上游 HEAD `ba9b67d` 的 `welcome-screen.html:133-135` 同时有 `#welcome-accounts` 与 `#welcome-channels`；
- 上游同一版本有 `welcome-layout.js`，`welcome-store.js:8` 导入 `mountLayout`；
- bundle `169f5e09` 的 `webui` 与上游 `ba9b67d` **逐文件一致**（关键 md5 相同：`welcome-screen.html c79e447b...`，`welcome-store.js 1024418e...`）；
- bundle 的 `_discovery` 与上游一致（`discovery-cards.html 4ebd365e...`）；
- 上游的「新 webui + 新插件」是自洽的：slot 存在，teleport 有目标。实测将运行树 webui 同步为 bundle 版本后，`appendChild` 异常 **0**，Settings/Projects 均正常。

因此不是上游缺陷；上游只是没有对「插件被单独升级、slot 被单独留在旧版」这种打包错误做防御。

版本引入点：`welcome-channels` 与 `welcome-layout.js` 由上游 commit `0ef5d92c`（2026-10-30，`Make welcome blocks reorderable and extensible`）同时引入。运行树处于该 commit 之前。

### 5.2 排除 C（环境）

- 无 404、无 CSP 拒绝；
- Chrome 156 / X11 只是渲染载体；CDP 在无头式纯 DOM 检查下同样复现；
- 同一 Chrome、同一 profile，把运行树 webui 同步到 bundle 版本后立即正常（`#welcome-channels`=1，异常=0，Settings 完整），说明与浏览器版本/缩放/字体无关。

### 5.3 确认 B：seed 的不对称

`flatpak/agent-zero.sh`：

```
32  for name in conf prompts agents knowledge instruments webui; do
33      if [ -d "$APP_ROOT/$name" ] && [ ! -d "$BASE_DIR/$name" ]; then
34          cp -a "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
35      fi
36  done
...
72  for name in api plugins extensions; do
73      if [ -d "$APP_ROOT/$name" ]; then
74          mkdir -p "$BASE_DIR/$name"
75          cp -a "$APP_ROOT/$name/." "$BASE_DIR/$name/" 2>/dev/null || true
76      fi
77  done
```

- `webui` 在第 32 行的一次性列表里：**目录已存在就永久跳过**；
- `plugins` 在第 72-77 行：**每次启动覆盖**（不删除目标独有文件）；
- 构建取源没有版本混合：`flatpak/org.agentzero.AgentZero.yml:156-174` 用 `type: dir, path: ..`，即 `scripts/build.sh:29,63` 的 `$A0_SRC` = `/home/kunweiz/Desktop/agent-zero`（`ba9b67d`），bundle `webui` 与 upstream 一致；
- 时间线：数据树 `webui` 是 2026-11-01 旧部署 `44c0ae83` 首次 seed 的版本；2026-11-17 安装 `169f5e09` 时，launcher 只覆盖了 `plugins`（与 `usr`），`webui` 因已存在而未复制。于是「旧 webui + 新插件」。

这正是 `plugins/_discovery/AGENTS.md:20` 警告的情况：*these slots must exist before the extension loads*。

---

## 6. 最小修复方案

### 6.1 推荐（根治，改 a0lite 打包逻辑 + 同步一次已部署实例）

**改动 1：`flatpak/agent-zero.sh`**

把 `webui` 从一次性 seed 列表移到每次覆盖列表。webui 是只读代码，不承载用户数据（用户数据在 `usr/`、`conf/`、`data/`），覆盖安全。

```diff
@@ flatpak/agent-zero.sh:32
- for name in conf prompts agents knowledge instruments webui; do
+ for name in conf prompts agents knowledge instruments; do
...
@@ flatpak/agent-zero.sh:72
- for name in api plugins extensions; do
+ for name in api plugins extensions webui; do
```

（更稳的变体：保留 seed 列表，但在启动时比较 `$APP_ROOT/webui` 与 `$BASE_DIR/webui` 的版本戳，只在 bundle 更新时覆盖；行号同上，逻辑等价。）

**改动 2：修复当前已部署实例（不重建 Flatpak）**

```sh
R="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cp -a /app/share/agent-zero/webui/. "$R/webui/"
```

实测：同步后 `webui/components/welcome/` 出现 `welcome-layout.js`，`welcome-screen.html` md5 = `c79e447b09eaf5c260133596f2a3d10e`（bundle/上游一致）。

**改动 3：重启应用一次**

`/ui/asset-bundle` 是启动时快照；只改文件、不重启，bundle 仍是旧的 29130 字节、version 仍 `749c98f1...`（实测）。重启后：

- `/ui/asset-bundle` 的 `version` 变化；
- bundle 内 `/components/welcome/welcome-screen.html` 含 `id="welcome-channels"`；
- splash 以新版本注册 `sw.js?version=...`，旧 CacheStorage 被清理。

**实测验证结果**（在运行树同步为 bundle 版本、浏览器绕过 SW 直连文件后）：

| 断言 | 修复前（旧运行树） | 修复后（bundle webui 同步） |
|---|---|---|
| `document.querySelectorAll('#welcome-channels').length` | 0 | **1** |
| `document.querySelectorAll('#welcome-accounts').length` | 0 | **1** |
| `#welcome-channels` 目标数 | 0 | **1** |
| `[x-teleport="#welcome-channels"]` 模板数 | 244 → 541（异常循环累积） | **1** |
| `Runtime.exceptionThrown`（首页 + 打开 Settings） | 16（短窗口）/ 334+（长窗口） | **0** |
| `.settings-pane` | 0 | **1** |
| `[data-settings-tab]` | 0 | **7** |
| `Alpine.store('settings').settings` | null | **40 个 key** |
| Settings 可见文本 | `Settings ×` | `Settings × search ... Agent Settings ... Save Cancel` |
| Projects 模态框 | 空白 | 含 `Projects ... Create project` |

截图：

- 修复前空白：`~/a0-shots/02-settings-233732.png`、`~/a0-shots/ui-rootcause/11-settings-cdp.png`、`~/a0-shots/ui-rootcause/19-prefix-settings-blank-repro.png`
- 手动 `Alpine.initTree(modal)` 后（证明只差初始化）：`~/a0-shots/ui-rootcause/12-settings-after-manual-initTree.png`
- 修复后 Settings：`~/a0-shots/ui-rootcause/17-settings-after-bundle-webui-sync.png`
- 修复后 Projects：`~/a0-shots/ui-rootcause/18-projects-after-bundle-webui-sync.png`

**验证命令（给合入者）**：

```sh
# 1) 服务端 bundle 已更新
curl -s http://127.0.0.1:5080/ui/asset-bundle | jq -r .version
curl -s http://127.0.0.1:5080/ui/asset-bundle \
  | jq -r '.files["/components/welcome/welcome-screen.html"][2]' \
  | grep -c 'id="welcome-channels"'        # 期望 1

# 2) 浏览器（CDP）
#    - Runtime.exceptionThrown 计数 === 0
#    - document.querySelectorAll('#welcome-channels').length === 1
#    - document.querySelectorAll('[x-teleport="#welcome-channels"]').length === 1
#    - 点击 #header-settings 后：
#      document.querySelectorAll('.settings-pane').length === 1
#      document.querySelectorAll('[data-settings-tab]').length === 7
#      Alpine.store('settings').settings !== null
#    - Alpine.store('projects').openProjectsModal() 后：
#      最后一个 .modal-inner 的 innerText 含 "Create project"
```

### 6.2 备选（最小止血，不推荐作为最终方案）

在运行树 `webui/components/welcome/welcome-screen.html` 的 `<section class="welcome-lower-grid">`（原第 136 行）内插入两个隐藏容器：

```html
<div id="welcome-channels" hidden></div>
<div id="welcome-accounts" hidden></div>
```

实测（绕过 SW 后）：Settings 恢复（`.settings-pane`=1、tabs=7），但仍有 **263** 个 `appendChild` 异常、20 个 teleport 模板；且 channels/accounts 卡片被隐藏。它只消除了「目标缺失」这一半，没有消除重复克隆/异常循环，也没有恢复新版 welcome 布局与 `welcome-layout.js`。因此只适合作为紧急止血，且必须重启以更新 asset-bundle。

### 6.3 防御性修复（上游，可选）

`plugins/_discovery/extensions/webui/welcome-actions-end/discovery-cards.html:12,57` 的 teleport 外层加目标存在判断，例如：

```html
<template x-if="document.getElementById('welcome-channels')">
  <template x-teleport="#welcome-channels">...</template>
</template>
```

Alpine 3.14.9 的 `x-teleport` **没有** `destination` 之类的「目标可选」参数；目标缺失时必然 `null.appendChild`，这是 Alpine 的实现特性。该改法只能防止 observer 被杀死，不能替代版本对齐。

---

## 7. 风险与副作用

1. **每次覆盖 webui 会抹掉用户对 webui 代码的本地改动**。webui 应视为只读代码；a0lite 的定制应放 `plugins/` 或 `extensions/`。当前运行树没有用户改动（除本次诊断临时补丁，已恢复）。
2. **重启会中断正在进行的会话**。单用户桌面可接受；这是让 `/ui/asset-bundle` 与 SW 版本更新的必要条件。
3. **`cp -a` 不删除旧文件**。同步后运行树仍残留旧 `components/sidebar/tasks/`、`css/scheduler.css`、`css/scheduler-datepicker.css`；新版 `index.js` 已改为引用 `/plugins/_scheduler/...`，实测无影响。若要干净，改用 `rsync -a --delete`，但必须确认没有运行树独有的用户文件（当前无）。
4. **Service Worker 缓存**：不重启时，`/ui/asset-bundle` 与 SW 都保持旧版本，改文件无效（实测）。修复流程必须包含「重启」或「显式清理 `/ui/asset-bundle` 缓存并 bump version」。
5. **`self-update-store` 在 Flatpak 内报 `Error: [Errno 2] No such file or directory: 'git'`**：这是 console error，不阻断 Settings（修复后 settings 正常，40 个 key），但会让「Check for updates」不可用。与本空白缺陷无关，另行处理。
6. **补 slot 方案的布局副作用**：旧版 `.welcome-lower-grid` 没有 `.welcome-discovery-block` 的 grid 规则；隐藏容器会让 channels/accounts 卡片不可见，且异常不归零。
7. **版本对齐后仍需回归**：旧 webui 与其它新插件可能还有其它 API 错配；本次同步后异常 0，暂未发现，但建议按 `a0lite-deploy` 的验收矩阵跑一遍 Settings 各 tab 与 Projects 交互。

---

## 8. 旧文件残留是否会被引用

结论：**不会被功能引用**；但会让 `diff -rq` 非 0，并让 `ui_bundler` 的 signature 遍历到它们（版本号抖动），不会进入 `files`，也不会被 Service Worker 主动预取。

证据：

1. `/ui/asset-bundle` 的内容由 `helpers/ui_bundler.py` 的 `_build_asset_bundle` 生成：从入口 `/index.html` 开始 BFS，`_extract_references` 解析 HTML 的 `<link href>`、`<script src>`、`<x-component path>`、CSS 的 `url()/@import`、JS 的 `import/export/import()/Worker/importScripts` 以及引号资源路径；只有被引用到的 URL 才进入 `entries`。它**不扫描** webui 目录来收集文件。
2. `_bundle_signature`（同文件）确实用 `_iter_root_files(root.path, suffixes=_BUNDLE_SUFFIXES)` 递归遍历整个 webui，把每个文件的 `mtime_ns` 与 `size` 计入 version；所以旧残留会让 version 变化（每次启动可能抖动），但不会出现在 `files` 键集合里。
3. `sw.js` 的 `preloadBundle()` 只把整个 bundle JSON 存进 CacheStorage（`cacheBundleRequest`），不逐个下载 `files`；`bundleEntries()` 只遍历 `bundle.files` 建立 URL→entry 映射；`respondToCacheableRequest()` 只在浏览器实际请求某个 URL 时命中。**没有目录扫描或主动 precache 清单**。
4. 新版 `index.html`/`index.js` 不再引用旧路径：bundle/上游的 `index.html` 中没有 `css/scheduler.css`、`css/scheduler-datepicker.css`；`index.js:12` 引用 `/plugins/_scheduler/webui/sidebar/tasks-store.js`，不是 `/components/sidebar/tasks/...`。当前旧 bundle 的 333 个键里之所以出现 `/components/sidebar/tasks/*` 和 `css/scheduler*.css`，是因为当前运行树仍是旧版 `index.html`/`index.js` 在引用它们；修复并重启后重建的 bundle 不再包含这些键。
5. `webui/components/sidebar/tasks/`、`webui/css/scheduler.css`、`webui/css/scheduler-datepicker.css` 在新 bundle 中不存在（`ls` 确认 `No such file or directory`）。它们是旧版遗留，不是新代码的依赖。

影响：

- 不会造成功能错误；最多让 asset-bundle 的 version 对残留文件的 mtime 敏感（无害）。
- 严格 `diff -rq` 会报 `Only in runtime: ...`，验证脚本 c 会因此失败；这是「代码已对齐但磁盘不干净」，应清理。

清理方案（不 `rm -rf webui`）：

在 `flatpak/agent-zero.sh` 的 webui 覆盖之后，删除**已知废弃路径**：

```sh
rm -rf "$BASE_DIR/webui/components/sidebar/tasks" \
       "$BASE_DIR/webui/css/scheduler.css" \
       "$BASE_DIR/webui/css/scheduler-datepicker.css"
```

理由：

- 这三项在 bundle 中已不存在，且新版 `index.html`/`index.js` 与插件都不再引用；
- 只删已知路径，不会碰用户在 `webui/public/` 放的自定义图标或其它资源；
- 若以后还有废弃文件，维护一个 `webui/.a0-obsolete` 清单（每行一个相对路径）循环删除，而不是整目录重建；
- `rsync -a --delete` 也能让 `diff=0`，但它会删除用户在 webui 内的任何文件；证据只支持「上游代码不使用用户资源目录」，不支持「用户从不放文件」，所以不推荐默认启用。

---

## 9. 未确认项

1. **`/ui/asset-bundle` 的实现已定位到 `helpers/ui_bundler.py`**（`get_ui_asset_bundle` / `_build_asset_bundle` / `_bundle_signature`）；Flatpak 内 `ui_server.py` 的缓存清理时机未逐行核对，但「启动快照、改文件不更新」已由两次实测证明（version 恒为 `749c98f1...`，welcome-screen 恒为 29130 字节）。
2. **Alpine `ft` 标志未在运行时直接读取**：结论基于 minified 源码（`m()` 无 try/finally，`dt()` 后抛错跳过 `ue()`）与现象（手动 `Alpine.initTree` 立即恢复；同步后异常 0）互证。
3. **299 / 541 不是固定值**：是异常循环随时间累积的模板数；实测旧版页面从 244 增长到 541，短窗口复现为 16 个异常。报告中的「299」沿用前一位工程师的现场观测。
4. **旧 webui 与其它新插件的其他错配未逐项审计**：本次只验证了 Settings/Projects 主路径与 `discovery` 插件；同步后 `Runtime.exceptionThrown` 为 0，未发现其它阻断。
5. **Projects 的修复前空白未重复实测**：沿用用户 `04-projects-233923.png`；修复后已验证 `Create project` 文本与 5 个按钮。
6. **未在真实 X11 截图上做像素级对比**：修复后截图来自 CDP `Page.captureScreenshot`（`17/18`），与用户宿主 Chrome 截图（`01-06`）为同一页面、同一 5080 服务。

---

## 10. 验证脚本（装完新版后一键跑）

脚本：`~/a0-local-backup/verify-ui-fix.sh`（已 `chmod +x`；`bash -n` 通过；内嵌 CDP 脚本 `node --check` 通过）。它只读运行状态，唯一写入是 `~/a0-shots/verify-ui-fix-settings.png` 和 `$TMPDIR` 下的临时 Chrome profile；不会杀它没有启动的 Chrome。

三行运行：

```sh
chmod +x ~/a0-local-backup/verify-ui-fix.sh
~/a0-local-backup/verify-ui-fix.sh a8f9321
# 若 9223 已被占用：A0_DEBUG_PORT=9224 ~/a0-local-backup/verify-ui-fix.sh a8f9321
```

前提：新版 `a8f9321` 已安装、应用已启动、`/api/health` 返回 200。脚本先做健康检查；应用没跑时直接打印 `RESULT: FAIL (0/6 passed; app not running)` 并退出，不会挂死。每一项都有超时（`flatpak` 15s、`curl` 5-20s、`diff` 60s、Chrome/CDP 启动 20s、CDP 脚本 50s）。

六项检查与失败时最可能的三个原因：

| 项 | 检查 | 失败时最可能原因 |
|---|---|---|
| a | 运行 commit 前缀 = `a8f9321` | ① 新版未安装或装的是旧 commit；② `flatpak --user info` 看到的是另一个安装（system vs user）；③ 应用进程仍跑旧部署，需要重启 |
| b | `/ui/asset-bundle` 的 version ≠ `749c98f1ffe4211405ab` | ① 应用未重启（bundle 是启动快照）；② 运行树 webui 未刷新（seed 未生效）；③ 反向代理/中间缓存返回旧 JSON |
| c | 运行树 webui 与安装 bundle `diff -rq` = 0 | ① 旧文件残留（`components/sidebar/tasks`、`css/scheduler*.css`），见 §8；② webui 未复制（seed 逻辑仍是一次性）；③ `--show-location` 指向的安装与运行中的应用不是同一个 commit |
| d | `#welcome-channels` ≥ 1 且 `welcome-screen.html` 行数 ≥ 1000 | ① 运行树仍是 785 行旧版；② 只 seed 了顶层目录/复制中断；③ 文件被用户或旧脚本改回旧版 |
| e | DOM：`#welcome-channels`=1、teleport=1、Settings pane 可见、`Runtime.exceptionThrown`=0 | ① 页面仍走旧 SW/asset-bundle（重启应用并刷新）；② 9223 连到了别的 Chrome/页面；③ 5 秒内组件未加载完（网络慢或服务忙） |
| f | 截图存在且 `identify` 能给出尺寸/mean/sd | ① e 未跑到截图（CDP 失败）；② `identify`/`magick` 缺失；③ `~/a0-shots` 不可写 |

脚本输出格式：每项 `PASS:`/`FAIL:` + 实测值；末尾一行 `RESULT: PASS (6/6)` 或 `RESULT: FAIL (k/6 failed: a,b,...)`。脚本全文见附录 C。

---

## 附录 A：关键命令与原始输出索引

| 证据 | 命令/文件 |
|---|---|
| slot 定义（上游） | `rg -n 'welcome-channels' /home/kunweiz/Desktop/agent-zero/webui` → `welcome-screen.html:135` |
| slot 缺失（运行树） | `rg -n 'welcome-channels' ~/.var/app/.../webui` → 空 |
| teleport 消费 | `rg -n 'welcome-channels' ~/.var/app/.../agent-zero` → `plugins/_discovery/.../discovery-cards.html:12` |
| 两树差异 | `diff -rq /home/kunweiz/Desktop/agent-zero/webui ~/.var/app/.../webui` |
| 关键 md5 | `welcome-screen.html`: bundle/上游 `c79e447b...`，运行树 `1d52baec...`；`welcome-store.js`: bundle `1024418e...`，运行树 `ce0c6a2f...`；`discovery-cards.html`: 三方 `4ebd365e...` |
| Alpine 版本 | `grep -o 'version:"3.14.9"' webui/vendor/alpine/alpine.min.js` |
| 异常原文 | `~/a0-shots/ui-rootcause/cdp-errors-234920.log`、`prefix-repro.log`、`store-state.log` |
| 修复后验证 | `17-settings-after-bundle-webui-sync.png`、`18-projects-after-bundle-webui-sync.png` |
| 旧版复现 | `19-prefix-settings-blank-repro.png` |
| 手动初始化证明 | `12-settings-after-manual-initTree.png`、`13-settings-after-onopen.png` |

## 附录 B：现场操作记录

- 运行树备份：`~/a0-local-backup/webui-before-slot-235148/`（19 MB，诊断前完整 `webui/`）。
- 诊断期间对运行树的临时改动（`welcome-screen.html` 两个隐藏 slot）已恢复；恢复后 md5 `1d52baec...`，与诊断前一致。
- 未修改 `/home/kunweiz/Desktop/a0lite` 的源码；仅新增本报告。
- 未重启应用（全程通过页面刷新与 CDP 注入验证）。
- 复用的 Chrome：`--remote-debugging-port=9223`，profile `~/.cache/a0-shots-chrome3`；未新起 Chrome，全部 CDP 脚本均为一次性 Node/Bun 进程，已退出。

## 附录 C：`verify-ui-fix.sh` 全文

文件：`~/a0-local-backup/verify-ui-fix.sh`
sha256：`de9643fc43e139fc99dd7255a749af86a5b49ade198cadb67828df943dbf07fc`
行数：312

```bash
#!/usr/bin/env bash
# verify-ui-fix.sh
#
# Verify the Agent Zero Flatpak UI fix (Settings / Projects modal body blank).
#
# Usage:
#   ./verify-ui-fix.sh [expected-commit-prefix]
#
# Defaults:
#   expected commit prefix : a8f9321
#   app URL                : http://127.0.0.1:5080
#   CDP port               : 9223
#   screenshot             : ~/a0-shots/verify-ui-fix-settings.png
#
# The script is read-only except for the screenshot and a temporary Chrome
# profile under $TMPDIR. It never kills a Chrome it did not start.

set -uo pipefail

EXPECTED_COMMIT="${1:-a8f9321}"
BASE_URL="${A0_URL:-http://127.0.0.1:5080}"
DEBUG_PORT="${A0_DEBUG_PORT:-9223}"
APP_ID="org.agentzero.AgentZero"
RUNTIME_WEBUI="${A0_RUNTIME_WEBUI:-$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/webui}"
SHOT_DIR="${A0_SHOT_DIR:-$HOME/a0-shots}"
SHOT="$SHOT_DIR/verify-ui-fix-settings.png"
OLD_BUNDLE_VERSION="749c98f1ffe4211405ab"

PASS=0
FAIL=0
FAILED=()

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); echo "FAIL: $*"; }
need() { command -v "$1" >/dev/null 2>&1; }

# --- preflight: the app must be running ------------------------------------
if ! curl -sf --max-time 5 "$BASE_URL/api/health" >/dev/null 2>&1; then
    echo "FATAL: $BASE_URL/api/health is not reachable."
    echo "Start the app first, e.g.:"
    echo "  flatpak run --user $APP_ID &"
    echo "Then wait for /api/health to return 200 and rerun this script."
    echo "RESULT: FAIL (0/6 passed; app not running)"
    exit 2
fi

echo "== verify-ui-fix: expected commit prefix '$EXPECTED_COMMIT' =="
echo "   url=$BASE_URL  cdp=$DEBUG_PORT"
echo

# --- a) running commit ------------------------------------------------------
COMMIT="$(timeout 15 flatpak --user info "$APP_ID" 2>/dev/null \
    | sed -n 's/^[[:space:]]*Commit:[[:space:]]*//p' | head -1)"
if [[ -n "$COMMIT" && "$COMMIT" == "$EXPECTED_COMMIT"* ]]; then
    pass "a) running commit: ${COMMIT:0:12} (matches $EXPECTED_COMMIT)"
else
    fail a "a) running commit: '${COMMIT:-<none>}' does not match prefix '$EXPECTED_COMMIT'"
fi

# --- b) startup asset bundle is new ---------------------------------------
BUNDLE_JSON="$(curl -s --max-time 20 "$BASE_URL/ui/asset-bundle" 2>/dev/null || true)"
BUNDLE_VER=""
if need jq; then
    BUNDLE_VER="$(printf '%s' "$BUNDLE_JSON" | jq -r '.version // empty' 2>/dev/null)"
elif need bun; then
    BUNDLE_VER="$(printf '%s' "$BUNDLE_JSON" \
        | bun -e 'const s=await Bun.stdin.text();try{console.log(JSON.parse(s).version||"")}catch(e){}' 2>/dev/null)"
elif need node; then
    BUNDLE_VER="$(printf '%s' "$BUNDLE_JSON" \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).version||"")}catch(e){}})' 2>/dev/null)"
fi
if [[ -n "$BUNDLE_VER" && "$BUNDLE_VER" != "$OLD_BUNDLE_VERSION" ]]; then
    pass "b) /ui/asset-bundle version: $BUNDLE_VER (differs from old $OLD_BUNDLE_VERSION)"
else
    fail b "b) /ui/asset-bundle version: '${BUNDLE_VER:-<empty>}' (must differ from $OLD_BUNDLE_VERSION; restart the app)"
fi

# --- c) runtime webui matches the installed bundle -------------------------
INSTALL_DIR="$(timeout 15 flatpak --user info --show-location "$APP_ID" 2>/dev/null || true)"
BUNDLE_WEBUI="${INSTALL_DIR%/}/files/share/agent-zero/webui"
DIFF_OUT=""
DIFF_COUNT=-1
if [[ -d "$BUNDLE_WEBUI" && -d "$RUNTIME_WEBUI" ]] && need diff; then
    DIFF_OUT="$(timeout 60 diff -rq "$BUNDLE_WEBUI" "$RUNTIME_WEBUI" 2>&1 || true)"
    DIFF_COUNT="$(printf '%s\n' "$DIFF_OUT" | sed '/^[[:space:]]*$/d' | wc -l)"
    if [[ "$DIFF_COUNT" -eq 0 ]]; then
        pass "c) runtime webui == bundle webui (0 differences)"
    else
        echo "     first differences:"
        printf '%s\n' "$DIFF_OUT" | head -10 | sed 's/^/     /'
        if printf '%s\n' "$DIFF_OUT" | grep -q '^Only in '; then
            echo "     note: 'Only in' lines are leftovers in the runtime tree; see report section 8."
        fi
        fail c "c) runtime webui != bundle webui ($DIFF_COUNT difference lines)"
    fi
elif [[ -f "$BUNDLE_WEBUI/components/welcome/welcome-screen.html" \
     && -f "$RUNTIME_WEBUI/components/welcome/welcome-screen.html" ]]; then
    # Fallback when diff is unavailable: compare the file that carries the slots.
    BMD5="$(md5sum "$BUNDLE_WEBUI/components/welcome/welcome-screen.html" | awk '{print $1}')"
    RMD5="$(md5sum "$RUNTIME_WEBUI/components/welcome/welcome-screen.html" | awk '{print $1}')"
    if [[ "$BMD5" == "$RMD5" ]]; then
        pass "c) welcome-screen.html md5 matches bundle ($BMD5; diff unavailable)"
    else
        fail c "c) welcome-screen.html md5 differs (bundle $BMD5, runtime $RMD5; diff unavailable)"
    fi
else
    fail c "c) cannot compare: bundle='$BUNDLE_WEBUI' runtime='$RUNTIME_WEBUI'"
fi

# --- d) the welcome slot exists and the file is the new version ------------
SLOT_FILE="$RUNTIME_WEBUI/components/welcome/welcome-screen.html"
SLOT_COUNT="$(grep -c 'id="welcome-channels"' "$SLOT_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
SLOT_LINES="$(wc -l < "$SLOT_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
SLOT_COUNT="${SLOT_COUNT:-0}"
SLOT_LINES="${SLOT_LINES:-0}"
if [[ "$SLOT_COUNT" -ge 1 && "$SLOT_LINES" -ge 1000 ]]; then
    pass "d) welcome-screen.html: slot count=$SLOT_COUNT, lines=$SLOT_LINES (>=1000)"
else
    fail d "d) welcome-screen.html: slot count=$SLOT_COUNT (need >=1), lines=$SLOT_LINES (need >=1000)"
fi

# --- e) DOM assertions through a clean Chrome -----------------------------
if curl -s --max-time 2 "http://127.0.0.1:$DEBUG_PORT/json/version" >/dev/null 2>&1; then
    fail e "e) CDP port $DEBUG_PORT is already in use; close that Chrome or set A0_DEBUG_PORT"
else
    CHROME_BIN="${CHROME_BIN:-}"
    if [[ -z "$CHROME_BIN" ]]; then
        for candidate in google-chrome google-chrome-stable chromium chromium-browser chrome; do
            if need "$candidate"; then CHROME_BIN="$(command -v "$candidate")"; break; fi
        done
    fi
    JS_RUNNER=""
    if need bun; then JS_RUNNER="bun"; elif need node; then JS_RUNNER="node"; fi

    if [[ -z "$CHROME_BIN" || -z "$JS_RUNNER" ]]; then
        fail e "e) missing Chrome or bun/node (chrome='$CHROME_BIN' runner='$JS_RUNNER')"
    else
        mkdir -p "$SHOT_DIR"
        PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/a0-verify-chrome.XXXXXX")"
        CHROME_LOG="$PROFILE/chrome.log"
        CDP_JS="$PROFILE/cdp.mjs"

        cat > "$CDP_JS" <<'CDP'
const base = process.env.BASE_URL;
const port = process.env.PORT;
const shot = process.env.SHOT;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const host = new URL(base).host;

function out(obj) { console.log(JSON.stringify(obj)); }

try {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const target = targets.find((x) => x.type === 'page' && x.url.includes(host));
  if (!target) { out({ ok: false, error: 'no page target' }); process.exit(0); }

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });

  let id = 0;
  const pending = new Map();
  let exceptions = 0;
  let firstException = null;
  let counting = false;

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
      return;
    }
    if (msg.method === 'Runtime.exceptionThrown' && counting) {
      exceptions += 1;
      if (!firstException) {
        const detail = msg.params.exceptionDetails;
        firstException = (detail.exception?.description || detail.text || '').split('\n')[0];
      }
    }
  };

  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const mid = ++id;
    pending.set(mid, { resolve, reject });
    ws.send(JSON.stringify({ id: mid, method, params }));
  });

  const evaluate = async (expression) => {
    const res = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (res.exceptionDetails) {
      throw new Error('evaluate: ' + (res.exceptionDetails.text || 'error'));
    }
    return res.result.value;
  };

  await send('Runtime.enable');
  await send('Page.enable');
  await send('Network.enable');
  await sleep(150);

  counting = true;
  await send('Page.navigate', { url: `${base}/?verify=${Date.now()}` });
  await sleep(5000);

  const home = await evaluate(`(() => ({
    channels: document.querySelectorAll('#welcome-channels').length,
    teleports: document.querySelectorAll('[x-teleport="#welcome-channels"]').length,
    ready: document.readyState,
    components: document.querySelectorAll('x-component').length
  }))()`);

  const clicked = await evaluate(`(() => {
    const button = document.getElementById('header-settings');
    if (!button) return 'no-button';
    button.click();
    return 'clicked';
  })()`);
  await sleep(3000);

  const settings = await evaluate(`(() => {
    const modal = document.querySelector('.modal-inner.settings-modal');
    const pane = document.querySelectorAll(
      '#settings .settings-pane, #settings .pane, #settings [x-show], .settings-pane'
    ).length;
    const text = (modal?.innerText || '').replace(/\\s+/g, ' ').trim();
    let loaded = false;
    try { loaded = !!Alpine.store('settings')?.settings; } catch (_error) {}
    return { modal: !!modal, pane, textLen: text.length, text: text.slice(0, 180), settingsLoaded: loaded };
  })()`);

  const shotRes = await send('Page.captureScreenshot', { format: 'png' });
  const { writeFileSync } = await import('node:fs');
  writeFileSync(shot, Buffer.from(shotRes.data, 'base64'));

  const ok = home.channels === 1
    && home.teleports === 1
    && settings.pane > 0
    && settings.textLen > 100
    && exceptions === 0;

  out({ ok, home, clicked, settings, exceptions, firstException, shot });
  ws.close();
} catch (error) {
  out({ ok: false, error: String(error) });
}
CDP

        "$CHROME_BIN" --headless=new --disable-gpu --disable-dev-shm-usage --no-sandbox \
            --no-first-run --no-default-browser-check \
            --remote-debugging-port="$DEBUG_PORT" --user-data-dir="$PROFILE" \
            --window-size=1440,960 "$BASE_URL/" >"$CHROME_LOG" 2>&1 &
        CHROME_PID=$!
        trap 'kill "$CHROME_PID" 2>/dev/null; wait "$CHROME_PID" 2>/dev/null; rm -rf "$PROFILE"' EXIT

        CDP_READY=0
        for _ in $(seq 1 40); do
            if curl -s --max-time 1 "http://127.0.0.1:$DEBUG_PORT/json/version" >/dev/null 2>&1; then
                CDP_READY=1
                break
            fi
            sleep 0.5
        done

        if [[ "$CDP_READY" -ne 1 ]]; then
            fail e "e) Chrome CDP did not start on port $DEBUG_PORT"
            tail -20 "$CHROME_LOG" 2>/dev/null | sed 's/^/     /'
        else
            CDP_OUT="$(BASE_URL="$BASE_URL" PORT="$DEBUG_PORT" SHOT="$SHOT" \
                timeout 50 "$JS_RUNNER" "$CDP_JS" 2>&1 || true)"
            printf '%s\n' "$CDP_OUT" | sed 's/^/     /'
            if printf '%s' "$CDP_OUT" | grep -q '"ok":true'; then
                pass "e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0"
            else
                fail e "e) DOM assertions failed (see JSON above)"
                tail -20 "$CHROME_LOG" 2>/dev/null | sed 's/^/     /'
            fi
        fi
    fi
fi

# --- f) screenshot exists and has real dimensions --------------------------
if [[ -f "$SHOT" ]]; then
    IMG_INFO=""
    if need identify; then
        IMG_INFO="$(identify -format '%wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]' \
            "$SHOT" 2>/dev/null || true)"
    elif need magick; then
        IMG_INFO="$(magick identify -format '%wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]' \
            "$SHOT" 2>/dev/null || true)"
    fi
    if [[ -n "$IMG_INFO" ]]; then
        pass "f) screenshot: $SHOT ($IMG_INFO)"
    else
        fail f "f) screenshot exists but identify/magick is unavailable or failed: $SHOT"
    fi
else
    fail f "f) screenshot missing: $SHOT (CDP capture did not run)"
fi

# --- summary ---------------------------------------------------------------
echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "RESULT: PASS ($PASS/6)"
else
    echo "RESULT: FAIL ($FAIL/6 failed: ${FAILED[*]})"
fi
```
