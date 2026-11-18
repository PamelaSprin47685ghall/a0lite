# v24 tuning apply — Vulkan / Radeon 780M

## §1 当前 vs 实际环境变量

交接文档称主实例为 `OLLAMA_MAX_LOADED_MODELS=1`、`OLLAMA_KEEP_ALIVE=10m`；实测 `flatpak/agent-zero.sh:154-155` 与运行中 `ollama serve` 的 `/proc/PID/environ` **都是 2 / 30m**，无 override、无第二处赋值。=2 是有意选择：OCR（xiaomi-ocr）、embedding（qwen3-embedding）、speech（lfm3-omni）各用不同模型，=1 会互相换出重载（`probe-pdf.md`）。此前 `OLLAMA_CONTEXT_LENGTH`、`OLLAMA_FLASH_ATTENTION`、`OLLAMA_KV_CACHE_TYPE` 均未设，主实例按模型默认 32768 ctx 加载。

## §2 改了什么（`flatpak/agent-zero.sh`，+15 行）

```diff
@@ -148,4 +148,8 @@
+# Two models stay resident on purpose: OCR, embeddings and speech each use a
+# different model, and MAX_LOADED_MODELS=1 made them evict and reload each
+# other (docs/manual-acceptance/a0lite-deploy/probe-pdf.md).  Operators with
+# less VRAM can lower it; nothing here overrides a value already set.
 export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-2}"
@@ -272,4 +276,15 @@
+    : "${OLLAMA_CONTEXT_LENGTH:=4096}"
+    : "${OLLAMA_FLASH_ATTENTION:=1}"
+    : "${OLLAMA_KV_CACHE_TYPE:=q8_0}"
+    export OLLAMA_CONTEXT_LENGTH OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE
```

`:=` 不覆盖用户已有值。未加 `OLLAMA_VULKAN`（`vulkan-knobs.md` 无生效证据，默认已加载 Vulkan）；未动 `OLLAMA_NUM_PARALLEL`；未设 `num_batch`——Ollama 0.40 无 `OLLAMA_NUM_BATCH`，且 a0flatpak 的 `embeddings.py`/`ocr.py`/`parsers.py`/`speech.py` 各自直连 httpx，无公共入口，不为此重构（收益 320 MB，优先级低）。

## §3 v24 三件套（`bundles/`，构建 RC=0，476 s）

| 包 | bytes | sha256 |
|---|---|---|
| agent-zero.flatpak | 60584984 | `02a60a5c5519f82da5c5bc94c00197e6e3088a83953bacadbc905c0071f23c48` |
| agent-zero-cuda.flatpak | 860282288 | `8c6a7c728313d125e229b3cfdb9615829ddba315dd18f6c043ca7f5c0bdc0c64` |
| agent-zero-wps.flatpak | 50210248 | `d907deea56ad306153afc75bbb19c9606905500fab1312655516906be9f4be63` |

安装后 commit `244441f71b194030a20c0968f1296bc300dc7ea128defe2423452fc2d0c24103`，health 200。

## §4 验证（全部实测）

1. **进程 env**：`OLLAMA_CONTEXT_LENGTH=4096`、`OLLAMA_FLASH_ATTENTION=1`、`OLLAMA_KV_CACHE_TYPE=q8_0`、`MAX_LOADED_MODELS=2`、`KEEP_ALIVE=30m` 全部进入 `ollama serve`（pid 2321332）；日志见 `--cache-type-k q8_0 --flash-attn on -c 4096`、`flash_attn = enabled`、`llama_kv_cache: 306.00 MiB (4096 cells, 36 layers)`。
2. **VRAM**：lfm3-omni `size_vram` **1.606 GB**，基线 1.958 GB，**−18.0%**。embedding 3.152 GB 同时驻留（=2 的预期）。
3. **tps**：65.50 / 65.20 / 65.58 → 中位 **65.50**（基线 65.15，+0.5%；门槛 ≥63 通过）。
4. **功能**：嵌入 dim=2560、L2=1；OCR 1200×800 三行文字全对（xiaomi-ocr 自带 ctx 8192，不受全局 4096 影响）；TTS→STT 中文往返完全正确。
5. **回归**：`verify-security-fix.sh --expect new` **12/12**；`verify-ui-fix.sh 244441f7` **6/6**。chat 无截断：n_ctx_slot=4096，实测 prompt 峰值 2694 tokens < 4096。

## §5 回退

无。没有变量被回退；无 unknown env 警告，无速度/功能退化。

## §6 结论

v24 **可以作基线**：显存降 18%，速度持平，功能与回归全过。`MAX_LOADED_MODELS=2` 保持不变（有意为之，见 §1）。`num_batch=512` 仍可按请求传，留给后续统一客户端时再做。

## §7 提交记录

提交 `b446c4b` “Tune Vulkan for VRAM, not throughput”（4 files, +222）：`flatpak/agent-zero.sh` 与 `vulkan-tuning.md`、`vulkan-knobs.md`、本文。
`git push origin main` → `8a8559b..b446c4b  main -> main`；远端 `refs/heads/main` 与本地 HEAD 同为 `b446c4bfad738957c5bdf2fc9eaf36d39055e313`。
