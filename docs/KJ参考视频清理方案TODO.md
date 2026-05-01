# KJ 参考视频清理方案 TODO

本文只记录 `wan22_kj_30s` / `wan22_kj_30s_segmented` 的参考视频清理路线。

## 背景

KJ 工作流不是只读取提示词和人物图。参考视频会进入动作、姿态、表情和参考图条件链路。字幕、横幅、红色对勾、定位气泡、贴纸、平台水印等前景 UI 即使没有被完整重绘到最终视频，也可能污染动作条件。

已观察到的表现：

- 手部漂移、多手、额外手势。
- 短时红点、贴纸残留、彩色小块。
- 局部肢体、椅子或接触区域变形。

这类问题是概率性的：同一类参考遮挡可能这次通过，下次在另一个分段或 seed 下泄漏。因此固定 seed 只能复现一次结果，不能证明参考源安全。

## 2.0 当前方案

目标：先不接新 ComfyUI 插件，不大改 KJ 主工作流，优先解决当前 60s 两段测试。

流程：

1. 对参考视频运行 `scripts/analyze_reference_overlay_risk.py`，生成高风险窗口和抽帧拼图。
2. 人工确认 UI 是否靠近人物身体、手、脸、椅子、腿部接触区域。
3. 对明确高危窗口做小范围局部清理：
   - 远离人物的天空/背景 UI：可用 `drawbox`、模糊、局部覆盖。
   - 靠近手和身体的横幅/贴纸：优先只清污染源，不破坏手部动作轮廓。
   - 红色对勾、定位 pin、明显贴纸色块：优先去色或小范围覆盖。
4. 重新切成 `30s` 分段，只复跑受影响的那一段。
5. 合并后运行 `scripts/analyze_generated_artifact_risk.py`，再做人工逐帧复查。

适用范围：

- 适合当前这类固定背景、单人、口播、两段到四段的测试。
- 对“孤立红点/贴纸残留”有效。
- 对“大面积 UI 遮住手或身体”的场景只能部分有效，容易出现覆盖过度或动作信息丢失。

当前策略：

- 继续用 2.0 完成 `30s + 30s` 验证。
- 不把 2.0 说成最终通用清理方案。
- 如果生成结果只是局部小红点，优先考虑成片局部修复。
- 如果手、脸、身体结构错误，回到参考视频窗口清理并复跑对应分段。

### 2026-05-01 成片自动精修一条龙

已新增本地后处理脚本：

- `scripts/polish_generated_artifacts.py`

处理链路：

1. 调用 `scripts/analyze_generated_artifact_risk.py` 做成片前检。
2. 从风险报告里定位短时红色候选框。
3. 用 FFmpeg 抽帧。
4. 用 OpenCV 对候选红色连通域做小范围 mask 和 `cv2.inpaint`。
5. 跳过持久红色元素、脸/嘴区域、底部鞋/脚区域和皮肤相似红色区域，降低误修手、嘴唇、鞋的概率。
6. 用 FFmpeg 重新编码视频并保留音频。
7. 再跑一次成片异常扫描，输出 `polish-report.json`、`polish-summary.md`、before/after 拼图。

结论：

- 只靠 FFmpeg 不够。FFmpeg 适合抽帧、编码、音频封装、粗遮盖/模糊，但无法自动判断“这个红色是手掌/嘴唇还是污染物”。
- 当前可用方案是 FFmpeg + Python/OpenCV。
- 适用范围是孤立小红点、红色 pin、贴纸色块、短时小 UI 残留。
- 不适合修手部结构、多手、脸崩、身体/椅子错位，这类问题要清理参考视频或复跑对应 30s 分段。

验证：

- 输入：`kj60-b11-sameframe-30x2-20260501` 合并视频。
- v2 全片一条龙用时约 `4分18秒`，但仍可能误修手掌偏红区域。
- v3 增加皮肤重叠保护，全片一条龙用时 `279.4s`，只触达 `4` 帧、修复 `4` 个红色组件、跳过 `702` 个组件。
- v3 输出：`output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v3.mp4`。
- v3 定点对比：`output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/frame_review/polished_auto_v3/target_28p5_30p0_before_after.jpg`。
- v3 仍漏掉 `29.750s` 附近一帧，因为这个污染不足 1 秒，检测目标帧范围边界太紧。
- v4 新增 `--target-frame-padding 2`，只把每个检测目标前后补 `2` 帧，不扩大到整秒窗口；全片用时 `275.5s`，触达 `5` 帧、修复 `5` 个红色组件、跳过 `911` 个组件。
- v4 输出：`output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v4.mp4`。
- v4 定点对比：`output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/frame_review/polished_auto_v4/target_28p5_30p0_before_after.jpg`，确认 `29.500s-29.750s` 红色挂件已清除，`28.562s` 和 `29.812s` 手部控制帧未被误修。
- v5 从红色专修升级为多颜色候选：默认自动修 `red/yellow/green/magenta`，`cyan/blue` 支持但默认关闭，因为当前光伏场景的天空和光伏板会造成较多蓝青色误报。
- v5 对已确认目标增加银白/低饱和高亮残留 mask，用于尝试处理红球被清掉后剩下的高光、描边、细绳。
- v5 全片输出：`output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v5.mp4`，用时 `424.8s`，触达 `5` 帧，修复 `5` 个彩色组件，跳过 `911` 个组件。
- v5 定点对比：`output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/frame_review/polished_auto_v5/target_28p5_30p0_before_after.jpg`。
- 重要限制：不要把大 halo 当默认方案。`--halo-padding 48` 小样本能吃掉更多绳子/高光，但会把腿边和光伏背景补成明显蓝灰块；v5 默认以不误伤人物为优先。

### 2026-05-01 KJ 2.0 同图锚定版验证

当前 2.0 固定场景可用方案对外统一叫：

- `KJ 2.0 同图锚定版`

内部追踪名保留：

- `B1.1 same-frame anchor`

规则：

- 用同一张完整人物+光伏背景 anchor 图作为每个分段的 `ip_image.png`。
- 不连接 `WanVideoAnimateEmbeds.bg_images`。
- 不连接 `WanVideoAnimateEmbeds.mask`。
- 每个 `30s` 分段复用同一张 anchor、同一条提示词、同一组负面词和 seed。

验证结果：

- job：`kj60-b11-sameframe-30x2-20260501`。
- 输出：`59.648s`、`720x720`、`16fps`、带音频。
- 动作指标：`body mean 8.254`、`mouth mean 10.239`、`background mean 0.366`。
- 人工复查：关键帧、`26-30s`、`28-33s` 接缝、`48-52s` 未见双头、多人、明显多手或贴图文字污染。
- 自动异常扫描高分主要来自嘴唇、鞋、手、光伏板线条等候选，人工判定未形成成片硬伤。

这个方案解决的是“固定背景长视频分段一致性”和“动作恢复”的问题，不等于参考视频清理已经通用解决。参考视频里字幕、贴纸、红点、横幅靠近手/身体时，仍然要走前置污染体检和成片复查。

### 2026-05-01 KJ 2.0 背景/Mask失败版

失败实验对外统一叫：

- `KJ 2.0 背景/Mask失败版`

内部追踪名保留：

- `B2 bg_images/mask`

它不是当前可用方案：

- 它把 `bg_image.png` 重复后接入 `WanVideoAnimateEmbeds.bg_images`，又用 `ip_image.png` alpha 生成 mask 接入 `WanVideoAnimateEmbeds.mask`。
- 这条链路压制了原 KJ 工作流里的动作、姿态、脸部和口型条件。
- 当前 `bg_image.png` 还不是纯背景，而是包含完整人物，因此进一步把人物锁成静态。

失败证据：

- job：`kj60-b2-bgmask-20260501-0100`。
- `body mean 1.2`、`mouth mean 0.705`，远低于 `KJ 2.0 同图锚定版`。
- 肉眼表现是嘴巴和身体几乎不动。

处理规则：

- 不再把 B2 当作“同背景小改造”。
- 不要在当前 2.0 默认路径里接 `bg_images` / `mask`。
- 如果未来重新做 B2，必须先有真正背景-only 图、正确人物 mask，并先通过 5s+5s 动作指标门禁。

## 2.1 视频级 Inpainting 候选

目标：把参考视频里的字幕、横幅、贴纸按时间连续修掉，保留自然运动。

### 2026-05-01 本地轻量规则验证结论

已实现本地预处理入口 `scripts/clean_reference_overlay_windows.py`，并扩展 `scripts/analyze_reference_overlay_risk.py` 输出 `cleanup_candidates` / `cleanup_plan`。当前轻量规则覆盖：

- 上方安全区 UI：连通域 mask、局部环采样填充、轻量 inpaint。
- 底部窄字幕：限制在文字候选 mask 内去饱和/压暗。
- 红点、定位 pin、彩色贴纸：小范围去饱和、模糊或填充。
- 靠近脸、手、身体、椅子的中段大字/气泡：标记 `needs_review_only`，默认不做粗暴覆盖。

本地验证结果为 `fail`，不能进入 Vast 推理：

- 原始参考视频：`素材资产/原视频/光伏60s.mp4`。
- 清理证据：`output/reference_cleaning/kj60-2p1-20260501/conservative_v9/cleaned_reference.mp4`。
- before/after：`output/reference_cleaning/kj60-2p1-20260501/conservative_v9/cleaning/before-after-contact-sheet.jpg`。
- risk-after：`output/reference_cleaning/kj60-2p1-20260501/conservative_v9/risk-after/overlay-risk-report.json`。
- 自动闸门：清理后仍为 `0.0s-59.8s` 高风险窗口，max score `8.065`。
- 人工复核：上方红对勾/部分横幅可清，但人物附近气泡和中段大字仍残留；部分近人物字幕被压暗后形成灰块，不能作为干净动作参考。

结论：2.1 的“轻量通用规则清理”只能作为预检和小 UI 候选清理工具，不能声明成功。要继续推进，优先转向 OCR/SAM/GroundingDINO 辅助精细 mask，或 ProPainter/E2FGVI/LaMa 这类真正的 inpainting；在清理拼图和 risk-after 同时通过前，不允许 stage / inference。

### 2026-05-01 2.1-next 本地样本验证结论

在 `conservative_v9` 失败后，继续只做本地小样本门禁，未进入 Vast：

- 样本窗口：`0-3s`、`29-33s`、`45-53s`，另取 `0s`、`30s`、`45s`、`50.5s` 单帧做模型级 inpainting。
- OCR：`rapidocr_onnxruntime` 能稳定识别中文大字、定位气泡和底部字幕。
- OCR glyph mask + OpenCV Telea/NS：不合格。文字笔画、描边、气泡框和底部字幕仍可见；加粗后容易留下白块、橙块或灰块。
- `simple-lama-inpainting` 单帧：不合格。文字/气泡可以被抹掉，但当 mask 覆盖人物腿、手、衣服或身体时，LaMa 会把人物区域补成光伏板纹理或错位半透明布料；`30s` / `50.5s` 气泡样本尤其明显。
- 依赖注意：`simple-lama-inpainting` 会拉取约 `196 MiB` 的 `big-lama.pt`，并要求旧版 `numpy` / `Pillow`；本地测试后已恢复全局 `numpy=2.4.4`、`Pillow=12.2.0`。后续若继续跑这类工具，应放在独立 venv 或专用环境，不要污染主 Python。

结论：当前 `光伏60s.mp4` 不是“简单文字覆盖背景”的问题，而是大量文字、气泡、字幕贴近或覆盖人物主体。自动本地清理无法同时满足“污染明显下降”和“脸/手/身体不被破坏”，因此 `2.1-next` 不跑全片 cleaned reference，不进入 `stage` / `inference`。下一步应转向：

- 提供无字幕/无贴纸参考视频。
- 人工逐帧或专业剪辑清理关键遮挡区域。
- 评估带时序和语义约束的视频级 object removal / inpainting，例如 ProPainter / E2FGVI / 更强的 commercial/object-removal 工具，并先做 1s 小窗口，不直接全片。

优先实现清单：

1. 扩展 `scripts/analyze_reference_overlay_risk.py` 的输出，让每个高风险窗口同时产出机器可读 mask 草案：
   - 红色对勾、定位 pin、彩色贴纸：HSV 颜色阈值 + 连通域。
   - 白色字幕、横幅文字：亮度/饱和度阈值 + 底部区域优先级。
   - 大块 UI 横幅：矩形候选框 + 时间连续合并。
2. 新增参考视频清理预处理入口，建议命名为 `scripts/clean_reference_overlay_windows.py`：
   - 输入原视频、risk report、处理策略、输出清理后视频。
   - 默认只处理高风险窗口，不全片重编码大范围修复。
   - 输出 `cleaning-report.json`，记录每个窗口的 mask、策略、帧范围和是否需要人工复核。
3. 先实现轻量级通用策略，再接重模型：
   - 小红点/定位 pin：局部去饱和、邻域模糊或小范围填充。
   - 底部字幕：限制在安全字幕带内做模糊/填充。
   - 远离人物的贴纸/横幅：局部模糊或背景邻域填充。
   - 触碰手、脸、身体、椅子接触区：标记为 `needs_inpainting_or_manual_review`，不要粗暴覆盖。
4. 质量闸门：
   - 清理前后都抽取同一批窗口 contact sheet。
   - 自动检查 mask 是否覆盖人物主体过多。
   - 清理后必须重新跑 `analyze_reference_overlay_risk.py`，确认风险下降。
   - `scripts/run_wan22_kj_30s_segmented_end_to_end.ps1` 已支持 `-ReferenceRiskPolicy Warn|FailOnHigh|Off`。默认 `Warn` 只输出报告；2.1/2.2 清理验证必须用 `FailOnHigh`，确保高风险参考视频在租机器和付费推理前被拦住。
5. 接入 KJ 分段前置流程：
   - 原视频先生成 risk report。
   - 如果存在高风险窗口，生成清理版参考视频。
   - 用清理版参考视频切 `30s` 分段。
   - 只在清理报告通过后进入 Vast 付费推理。

候选方向：

- ProPainter
- E2FGVI
- 其他 video inpainting / object removal 模型

优点：

- 时间连续性比逐帧修图更好。
- 适合清理横幅、贴纸、平台 UI、定位气泡等跨多帧遮挡。
- 清理后再送入 KJ，能从源头降低姿态/动作污染。

风险：

- 需要更准确的 mask，否则会把手、脸、衣服或椅子一起修坏。
- 对手部附近遮挡仍然敏感，修坏后 KJ 会继续放大错误。
- 可能增加依赖、模型下载和 Vast 冷启动时间。

进入条件：

- 2.0 反复复跑仍然出现同类污染。
- UI 大面积覆盖人物手部/身体，简单覆盖已经不够。
- 能先在本地或小样本上验证 mask 和时序稳定性。

## 2.2 图像级/局部修复候选

目标：用更轻量的逐帧或局部方式，替代粗暴 `drawbox`。

候选方向：

- LaMa / MAT 等图片级 inpainting。
- SAM / GroundingDINO / OCR 生成或辅助生成 mask。
- Crop & Stitch：只裁出污染区域修复，再贴回原帧。
- 对红色 UI 做颜色检测、去饱和、局部模糊或邻域填充。

优点：

- 比视频级方案更轻，接入和调试成本低。
- 对红点、对勾、定位 pin、小贴纸更实用。
- Crop & Stitch 可以把修复限制在很小区域，降低误伤人物主体。

风险：

- 逐帧修复容易闪烁。
- 不适合大面积遮住手和脸的情况。
- mask 质量仍然决定结果，自动检测不能完全替代人工验收。

进入条件：

- 需要把 2.0 里的手动小范围覆盖升级成半自动工具。
- 问题主要是小 UI 色块、红点、贴纸残留，而不是人体结构被严重遮挡。

## 暂不做

- 暂时不把 ProPainter / E2FGVI / LaMa 写进生产 Vast bootstrap。
- 暂时不新增 ComfyUI 清理插件到 KJ 主工作流。
- 暂时不把任何自动检测结果当作最终验收，成片仍必须人工看关键帧和问题窗口。

## 记录要求

每次发现新污染类型时，需要同步记录：

- 原参考视频时间段。
- 对应成片时间段。
- 污染源类型：字幕、横幅、红点、定位气泡、贴纸、水印等。
- 表现形式：多手、手漂移、红点、贴纸残留、肢体变形等。
- 处理方式：参考清理、成片局部修复、复跑分段、放弃该段。
