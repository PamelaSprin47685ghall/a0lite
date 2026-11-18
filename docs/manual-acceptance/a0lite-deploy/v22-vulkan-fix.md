# v22：AMD Radeon 780M Vulkan 固化与验证

## §1 agent-zero.sh 改动

在 Ollama 启动块内、`CUDA_VISIBLE_DEVICES=-1` 之后新增 10 行（9 行内容 + 1 行空行）：

```diff
     export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:--1}"
 
+    # AMD integrated GPUs are dropped by default; enable Vulkan inference on
+    # them. A0_OLLAMA_IGPU=0 restores the previous CPU-only behaviour, and a
+    # value the operator already set wins. See
+    # docs/manual-acceptance/a0lite-deploy/amd-gpu-inventory.md.
+    if [ "${A0_OLLAMA_IGPU:-1}" = "1" ]; then
+        : "${OLLAMA_IGPU_ENABLE:=1}"
+        : "${GGML_VK_VISIBLE_DEVICES:=0}"
+        export OLLAMA_IGPU_ENABLE GGML_VK_VISIBLE_DEVICES
+    fi
+
     # OLLAMA_HOST is the URL clients dial; the server bind is separate because
```

`:=` 只在未设置时赋值，用户已有的 `OLLAMA_IGPU_ENABLE` / `GGML_VK_VISIBLE_DEVICES` 不被覆盖；`CUDA_VISIBLE_DEVICES=-1` 保留。

## §2 构建

- 命令：`A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh`
- 耗时：557 s，exit 0；日志 `~/a0-local-backup/build-v22-0952.log`
- v21 备份：`~/a0-local-backup/bundles-v21/`（先备份再清空 `bundles/`）

| 包 | size (B) | sha256 |
|---|---|---|
| agent-zero.flatpak | 60506136 | 97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7 |
| agent-zero-cuda.flatpak | 860271248 | 1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f |
| agent-zero-wps.flatpak | 50210992 | 3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772 |

## §3 五条验证

1. **size_vram > 0**：`lfm3-omni:2b-q4_K_M` → 1958341507 B（≈1.82 GiB）；`qwen3-embedding:4b-q4_K_M` → 7779836231 B（≈7.25 GiB）。
2. **Vulkan 日志原文**：
```
load_backend: loaded Vulkan backend from /app/share/agent-zero/models/lib/ollama/vulkan/libggml-vulkan.so
inference compute id=0 ... library=Vulkan ... name=Vulkan0 description="AMD Radeon 780M Graphics (RADV PHOENIX)" ... type=iGPU
```
3. **新基准**（`num_predict=64`、`temperature=0`、`seed=42`）：tps 58.36 / 57.30 / 67.03，三次 size_vram 均 1958341507。
4. **health**：HTTP 200，`commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`。
5. **security**：`verify-security-fix.sh --expect new` → 12/12 PASS。

## §4 加速比

- v21 CPU 基线（同模型，中位）：32.27 tps
- v22 Vulkan（中位）：58.36 tps
- **1.81×**（三次均值 60.90 vs 32.27 ≈ 1.89×）

## §5 回退

- 临时 CPU：`flatpak run --env=A0_OLLAMA_IGPU=0 org.agentzero.AgentZero`
- 持久 CPU：`flatpak override --user --env=A0_OLLAMA_IGPU=0 org.agentzero.AgentZero`
- 重装 v21：`flatpak install --user -y --reinstall ~/a0-local-backup/bundles-v21/*.flatpak`
