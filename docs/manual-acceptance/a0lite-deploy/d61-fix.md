# D61：STT 无静音判定

## 现象
v14 实测：1 s 全零 WAV → `{"success": true, "text": "Oh,"}`；1 s 粉噪 → `"Okay."`；0.2 s 截断 → `"So,"`。模型对无语音输入编造短词，调用方无法判断。

## 标定（24 kHz 单声道 16-bit WAV，RMS 为全部样本均方根）
| 音频 | RMS | 峰值 | 时长 |
| --- | --- | --- | --- |
| 1 s 全零 | 0.000000 | 0.000000 | 1.0 s |
| 1 s 粉噪 `anoisesrc` a=0.5 | 0.095123 | 0.336945 | 1.0 s |
| 正常中文 TTS | 0.081053 | 0.404755 | 4.16 s |
| 0.2 s 截断（TTS 开头） | 0.000632 | 0.001678 | 0.2 s |

## 阈值与理由
- `A0_STT_MIN_RMS` 默认 `0.005`：位于数字静音（0）与正常语音（0.081）之间，距语音 16 倍；a=0.02 的粉噪（RMS 0.003814）实测会被拦下。
- `A0_STT_MIN_DURATION` 默认 `0.3` s：不足 0.3 s 不送模型。
- 先判时长再判音量：0.2 s 截断常落在 TTS 静音前导，先判 RMS 会误报 silence。

## 改法（只改 `flatpak/a0flatpak/speech.py`）
1. `_wav_levels` 解析 RIFF/PCM/float（8/16/24/32-bit，单/多声道），返回 RMS、峰值、时长；非 WAV 或未知格式返回 `None` 放行。
2. `_stt_gate` 在 base64 解码后、送 Ollama 前执行；命中即返回，并写 `$A0_BASE_DIR/usr/logs/a0flatpak.log`。
3. `_wrap_stt_handler_class` 把 `silence`/`too_short`/`duration_s` 合并进 HTTP 响应；上游 handler 只保留 text/language。

## 验证（沙盒内独立 python，仓库 patch 树）
```text
静音      {"success": true, "text": "", "silence": true, "duration_s": 1.0}
0.2 s     {"success": true, "text": "", "too_short": true, "duration_s": 0.2}
粉噪 a=0.5 送模型，返回 "Yeah."（宽带噪声，已知限制）
中文 TTS  "今天天气很好，我们一起去公园散步吧。"
日志      speech.stt: silence: rms=0.000000 ...；speech.stt: too_short: duration=0.2s ...
```

## 构建后复验
```bash
ffmpeg -y -f lavfi -i anullsrc=r=24000:cl=mono -t 1 -c:a pcm_s16le /tmp/silence.wav
curl -sS -X POST http://127.0.0.1:5080/api/plugins/_whisper_stt/transcribe \
  -H 'Content-Type: application/json' \
  -d "{\"audio\":\"$(base64 -w0 /tmp/silence.wav)\"}" | jq '{text,silence,too_short,duration_s}'
# 期望 text="" 且 silence=true；鉴权会话需加 -b ~/.a0-cookies 与 X-CSRF-Token
```
