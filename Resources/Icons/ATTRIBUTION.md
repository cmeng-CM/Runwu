# Icon attribution

`brand-tailwind.svg` is the outline **Brand Tailwind** icon from [Tabler Icons](https://tabler.io/icons) (MIT License).

`history-clock.svg` and the derived History navigation images are based on the outline **Clock** icon from [Tabler Icons](https://tabler.io/icons) (MIT License).

Copyright (c) 2020-2025 Paweł Kuna / Tabler Icons contributors.

This project uses Tabler’s MIT-licensed SVG artwork only. It is **not** an official Tailwind CSS trademark asset and does not imply endorsement by Tailwind Labs.


## 润物应用图标 v2

用户于 **2026-10-09** 明确批准第二版「夜雨双语」图标。项目应用图标采用此批准原图，菜单栏和历史图标继续使用上面的既有资源。

- 工具：内置 `image_gen.imagegen`，`transparent_background=true`。
- 最终生成结果：`/Users/cm/.codex/generated_images/01a11a59-f4dd-7ab3-b4bd-29d05ca5756b/exec-43f21416-747c-40a8-b529-4931dce13d67.png`。
- 精修参考：上一版生成结果 `exec-ae493cce-0361-4732-9522-fff4b86ecb2c.png`；原有 Pico 的 P 图不是编辑对象。
- 仓库像素权威：`Resources/Icons/Runwu-AppIcon-v2.png`，1254 × 1254 PNG，带 alpha，原文件逐字复制；不裁切、改色、重绘、更换字体或旋转。
- 源文件 SHA-256：`744c3e3944668e3fa99bbb9dba1ea9a26f3f1cff0670efd6802e86c767931095`。

### 图标生成命令

```sh
swift Scripts/make-icon.swift
zsh Scripts/build-app.sh
```

`make-icon.swift` 从仓库原图直接使用 macOS `/usr/bin/sips` 生成 16/32/128/256/512 点各 1x/2x 的十张 PNG（16 至 1024 像素），保持 alpha 与原方向，再用 `/usr/bin/iconutil --convert icns` 写入 `Resources/AppIcon.icns`。临时 iconset 自动清理；没有 AppIcon asset catalog，也不会复活旧 Pico 绘制脚本。脚本从自身路径定位仓库，可在其他工作目录通过绝对脚本路径运行。

构建仍打包 classic `AppIcon.icns`，`CFBundleIconFile=AppIcon`。**构建的可复现来源是已批准 PNG，不是重新运行创作提示词**；以下提示词仅记录设计 provenance，生成工具重新创作不保证相同像素。

### 最终 imagegen 精修提示词（逐字）

```text
Refine this single macOS icon while preserving its core composition: midnight navy rounded square, gentle mint/jade spring raindrop with a wind-swept curve, large clean “文” and “A” bilingual glyphs. Keep the true transparency outside the rounded square.
The main correction is the typing caret: REMOVE the large luminous vertical stroke to the right of A completely. It currently makes the logo read “AI”, which is wrong. There must be exactly the two readable glyphs “文” and “A”, no I or other letters. Instead use a single small, crisp, vertical typing cursor to the LEFT of 文, about one-third of the glyph height, slightly offset toward the lower baseline and with ample spacing. This short accent should be clearly a tiny input cursor, not another letter and not a glowing decoration. Balance the two glyphs centrally in the broad drop; preserve readability.
Also simplify excessive material shading: reduce glow, glassiness and the embossed border on the navy tile. Aim for restrained satin, clear broad shapes and crisp contours that stay recognizable at 32–64 pixels. Retain subtle depth but avoid watery textures and excessive highlights. Preserve the flowing spring-rain silhouette and quiet night mood; the goal is a polished minimalist real-time Chinese-English translator logo, not a weather icon or generic AI brand. No additional symbols, captions, stars, poem text or mockup framing.
```
