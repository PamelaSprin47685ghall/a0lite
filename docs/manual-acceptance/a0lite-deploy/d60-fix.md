# D60 修复：OCR 对过小图像拒识

## 现象

100x50 PNG 送入 `ImageParser`，`xiaomi-ocr` 返回 76 字符无关数学题文本，
`ok=true`，无 `OCR incomplete` 标记。调用方无法区分识别成功与模型编造。

## 门限取值

- `A0_OCR_MIN_PIXELS=40000`：等于 200x200，图标类小图仍放行。
- `A0_OCR_MIN_SHORT_EDGE=64`：短边低于 64px 时字高不足一个可读字形。
- 任一不满足即拒识；Pillow 读不到尺寸时放行，避免因测量失败误拒。

## 改法（只改 `flatpak/a0flatpak/ocr.py`）

- `_image_size()`：Pillow 只读文件头取宽高，不解码整图，不增加大图开销。
- `_reject_small_image()`：请求前抛 `ValueError("image too small for OCR:
  WxH, minimum 64px on the short edge and 40000 total pixels")`。沿用
  `_parse_image` 现有失败契约，上游 `parse` 原样传给调用方。
- `_low_confidence()`：可见字符 < 8，或连续 ≥2 字母的「词」总字母数 < 4 时，
  追加 `> OCR low confidence: ...`。不按「有无数学符号」判断；Markdown 表格
  的竖线与分隔线不计入字母，正常中英文表格不误报。

## 验证（沙盒 python3，含真实 `xiaomi-ocr`）

| 图 | 结果 |
|---|---|
| 100x50 | 拒绝，0.000 s，未调模型：`image too small for OCR: 100x50, minimum 64px on the short edge and 40000 total pixels` |
| 1200x800 | 通过，3.364 s，返回 `D60 OCR acceptance test 2026`，无尾注 |
| 200x200 | 通过（40000 恰为下限），返回 `AB 42`，因仅 4 字符追加 low confidence 尾注 |

桩验证另确认：`x = 1` 与纯符号噪声触发尾注；`| 名称 | 数量 |` 表格不触发。
`python3 -m py_compile flatpak/a0flatpak/ocr.py` 通过。

## 构建后复验

```bash
python3 -m py_compile flatpak/a0flatpak/ocr.py
flatpak run --command=sh org.agentzero.AgentZero -c \
  'find /app -name ocr.py -path "*a0flatpak*" -exec python3 -m py_compile {} +'
```

再在 Web UI 上传 100x50 PNG：应收到 `image too small for OCR` 错误，而不是数学题文本。
