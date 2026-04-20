# Workflow Combos

## 完美节点组合1

状态：当前最佳短片方案，已验证可用

目标：
- 背景不带原视频文字
- 人物不出现“突然变出来”的不自然感
- 口型和语速基本对得上

组合：
1. `SVI2` 先生成无字、连续的光伏场景人物底片
2. 从 `SVI2` 结果中抽取干净场景帧，作为新的 speaker image / clean anchor
3. `MultiTalk Single` 使用这个 clean anchor + 原音频，直接生成单段口播视频

当前最佳成片：
- 本地文件：`output/best-combo-current/best-combo-current.mp4`
- 公网地址：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/best-combo-current/20260419/1776565374212-1-asset-animatediff_00111-audio.mp4`

已验证结论：
- 换掉带字锚图后，文字不会被重新描绘出来
- `MultiTalk Single` 这条分支当前比粗融合方案更稳
- `SVI2` 继续保留为 continuity / clean anchor 生成模块

下一阶段：
1. 把这套从 `10s` 扩到 `30s`
2. 测试动作模板，而不是继承原主持人动作
3. 再扩到 `60s-120s` 的分镜流水线

## 完美节点组合1 Vast 46G 复现版

状态：已在 `Vast A40 46G` 上成功复现，用户确认合格

目标：
- 不依赖 `A100 80G`
- 用更低成本硬件复现 `clean-anchor-multitalk`
- 保持原有 clean anchor + MultiTalk 口播效果

环境：
- 金机：`35259906`（`RTX 3090 24G`，用于保留已配好的 ComfyUI 环境与模型）
- 复现机：`35278037`（`A40 46G`）
- 工作流：`output/vast-clean-anchor-multitalk-24g/workflow_api_24g_pruned.json`

成功记录：
- Prompt ID：`0cac2183-a996-49de-8b52-84d7dd1d88a4`
- ComfyUI 状态：`success`
- 输出文件：`/workspace/ComfyUI/output/vast_clean_anchor_multitalk_24g_00001-audio.mp4`
- 本地回收文件：`output/vast-clean-anchor-multitalk-24g-result/vast_clean_anchor_multitalk_24g_00001-audio.mp4`

成本：
- 纯成功跑片时长：`1247.135s`
- 纯成功跑片成本：约 `$0.1186`，约 `0.85 元`
- A40 实例整段实际开机成本：约 `$0.6220`，约 `4.48 元`
- 说明：前者只算最终成功任务本身；后者包含该实例在调试、拷模型、提交任务期间的整段计费

当前结论：
- `clean-anchor-multitalk` 不一定要 `80G`
- `46G` 已经能出用户认可的结果
- 后续优先沿这条硬件档位继续做复现和批量化

## 保留场景换人变体

状态：已跑通，但不是“真换背景”

说明：
- 这一支之前曾误记为 `完美节点组合2`
- 它实际做的是“保留原场景结构 + 换人 + 局部补丁”，不是用户要求的“彻底换新背景”

实现：
1. 使用 `output/combo-svi2-anchor/review/frame-002.png` 作为干净光伏场景参考
2. `scripts/build_combo2_anchor.py` 走“原场景保真覆盖”路径：
   - 保留参考场景主体结构
   - 用用户提供的人物图覆盖原主持人
   - 对右下角露出的旧残影做小范围地面补丁
3. 生成锚图：`output/combo2-anchor/combo2-anchor-v15-scripted.png`
4. 把该锚图送入 `MultiTalk Single` + 原音频，输出最终口播视频

产物：
- 本地文件：`output/best-combo2-current.mp4`
- 公网地址：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/best-combo2-current/20260419/1776576374290-1-asset-best-combo2-current.mp4`

## 完美节点组合2

状态：已跑通第一版真换背景成片，仍需继续优化人物与新场景的融合

目标：
- 不沿用原视频的场景结构
- 先生成或挑选一个新的无字光伏屋顶背景
- 再把人物送入 `MultiTalk Single` + 原音频

当前实现：
1. 新背景来源：`output/true-combo2-pexels/crop-c.jpg`
2. 人物锚图来源：`output/true-combo2-pexels/anchor-c-grabcut-frame002.png`
3. 工作流：新背景锚图 -> `MultiTalk Single` -> 带原音频口播成片
4. 提交目录：`output/true-combo2-pexels-multitalk`

当前产物：
- 本地文件：`output/best-combo2-true-bg-v1.mp4`
- 下载目录：`output/true-combo2-pexels-multitalk/downloads/AnimateDiff_00111-audio.mp4`
- 公网地址：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/best-combo2-true-bg-v1/20260419/1776581876628-1-asset-best-combo2-true-bg-v1.mp4`

二次取景优化版：
- 锚图：`output/true-combo2-pexels-reframed/anchor-reframed-c.png`
- 下载目录：`output/true-combo2-reframed-multitalk/downloads/AnimateDiff_00111-audio.mp4`
- 当前最佳本地文件：`output/best-combo2-true-bg-v2.mp4`
- 当前最佳公网地址：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/best-combo2-true-bg-v2/20260419/1776582990024-1-asset-best-combo2-true-bg-v2.mp4`

当前结论：
- 这条已经满足“背景真的换了”
- 但人物在新场景中的落点和比例还不够自然
- 下一轮优先修锚图构图，不先动口型分支

下一步：
1. 继续压人物边缘的轻微二次生成感
2. 在同一新背景上继续做 `MultiTalk` A/B 测试
3. 成片自然度过关后，再扩到多段 `30s -> 60s -> 120s`

## 完美节点组合2 手工锚图分支

状态：当前新的真换背景可用基线

说明：
- 这条不再让单个视频工作流同时负责“背景重建 + 人物一致性 + 口型”
- 改成拆分责任：先拿更像原场景的新背景，再本地合成人物锚图，最后只让 `MultiTalk Single` 负责口播

实现：
1. `DreamID Omni Fast` 先生成更接近原视频光伏屋顶结构的新场景视频：
   - 目录：`output/guangfu2-scene-dreamid-fast-v1`
   - 取样帧：`output/guangfu2-scene-dreamid-fast-v1/review/frame-002.png`
2. 使用 `scripts/composite_speaker_on_background.py` 把 `美女3.png` 精确合成到该新场景中：
   - 锚图目录：`output/combo2-manual-anchor-v4`
   - 当前锚图：`output/combo2-manual-anchor-v4/anchor-b.png`
3. 把该锚图送入 `MultiTalk Single` + 原音频：
   - 作业目录：`output/combo2-manual-anchor-v4-multitalk`

当前产物：
- 本地文件：`output/best-combo2-manual-current/best-combo2-manual-current.mp4`
- 下载目录：`output/combo2-manual-anchor-v4-multitalk/downloads/combo2-manual-anchor-v4-multitalk.mp4`
- 公网地址：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/best-combo2-manual-current/20260419/1776594068911-1-asset-best-combo2-manual-current.mp4`

当前结论：
- 背景已经是新场景，不再沿用原视频直接抠掉文字
- 亮度、光伏板结构和天空层次，比 `best-combo2-true-bg-v1/v2` 更接近用户想要的方向
- 这条目前还不是最终版，下一轮重点是继续压“人物坐在板面上”的违和感
