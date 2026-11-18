# STT 拼音输出的根因（v18，包 commit `be957363ef7e`）

- 时间 2026-11-18 06:35–06:45；实例 PID 2123135（06:30:14 启动），health 200
- 证据 `~/a0-shots/edge-media-20261118-050021/`（`stt_probe.py`、`a1.wav`、`tts-v12.wav`）；未构建、未重启、未触发 purge、未改 `speech.py`

## 1. 现象与原始输出

用户报告：同一中文 WAV、同一进程，正常调用 3/3 为 `Nihau. Zhi shi yan shou tan zhen. Qing he cheng yu yin.`（`language: english`）；purge 后为 `你好,这是验收探针,请合成语音。`。本轮在 v18 端点复现"正常调用"一侧（`tts-v12.wav`，同一句，连跑 2 次）：

```text
{"success": true, "text": "Nihao. This is Yen Shou Tan Zhen.", "language": "english"} [HTTP=200 T=1.907]
{"success": true, "text": "Nihao. This is Yen Shou Tan Zhen.", "language": "english"} [HTTP=200 T=1.180]
```

同文件直连 Ollama、不传 `language` 即得 `你好，这是验收探针。`。差异只在 `language`。

## 2. 两条路径的 module 与参数

| 状态 | `runtime.transcribe.__module__` | 传给 Ollama |
|---|---|---|
| `a0flatpak.apply()` 后 | `a0flatpak.speech` | `model=lfm3-omni:2b-q4_K_M`、`response_format=verbose_json`、`language=en`（无 prompt） |
| `purge_namespace("plugins")` 后 | **仍是 `a0flatpak.speech`**（`plugin_guard` 的 purge hook 立即 re-apply） | 同上 |
| 未 patch 的原始实现 | `plugins._whisper_stt.helpers.runtime` | `whisper.load_model` + `language=en`；沙盒里 whisper 是空 stub，实测抛 `module 'whisper' has no attribute 'load_model'`，**不可能返回汉字** |

`language=en` 来自 `usr/plugins/_whisper_stt/config.json` 与三处 `DEFAULT_CONFIG`（均为 `en`）。patch 版与原始版取值相同；不存在"patch 丢了中文 prompt"——patch 版从不发送 prompt。

## 3. 直连 Ollama 实验（同一 WAV）

| 请求 | 输出 | language |
|---|---|---|
| 不传 `language` | `你好，这是验收探针。` | null |
| `language=zh` | `你好，这是验收探针。` | chinese |
| `language=en` | `Nihao. This is Yen Shou Tan Zhen.` | english |
| `language=auto` | `400 unsupported language "auto"` | — |
| `language=`（空字段） | `你好，这是验收探针。` | null |
| `language=en` + 中文 `prompt` | `Nihao. This is Yen Shou Tan Zhen.` | english |

结论：`language` 是唯一开关；prompt 在 `language=en` 下不生效；`auto` 不是合法取值。

## 4. 判定

**真缺陷（中），但不是"丢 prompt"。** 插件默认 `language: en` 被 patch 忠实传给多语模型，中文音频因此被强制音译（拼音）或翻译。`_resolve_language` 已把 `auto`/空值映射为 `None`，默认值改成 `auto` 即可自动识别中文。"purge 后汉字"本轮无法复现：v18 的 `plugin_guard` 让 purge 后仍是 `a0flatpak.speech`，输出仍为英文；未 patch 的 whisper 路径会直接报错。那一次更可能是 config 的 `language` 为空/`auto`，需用 `runtime.transcribe.__module__` 与 `cfg["language"]` 当场确认，不能凭输出反推。

## 5. 修法（仅思路，未改）

1. `plugins/_whisper_stt/default_config.yaml`、`migration.DEFAULT_CONFIG`、`runtime.DEFAULT_CONFIG` 的 `language` 从 `en` 改为 `auto`；`_resolve_language` 已有 `auto → None` 映射。
2. `normalize_config` 对空串保留默认值；若要"清空即自动"，把空串也映射为 `auto`。
3. 不在 `a0flatpak.speech` 硬编码 `zh`（会改坏英/日用户），也不把 `en` 静默当 `auto`（显式选英文者会收到中文）；`config.html` 的 placeholder 只有 `en`，可补一句"留空或 `auto` 表示自动识别"。
