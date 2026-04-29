---
name: wan_2_2_animate_segmented
description: Use when running or modifying the Wan2.2 segmented talking-photo pipeline, especially the verified v3 single-instance 30s/60s flow with 10s segments and continue_motion tail frames.
---

# wan_2_2_animate_segmented

## 适用范围

用于 `wan_2_2_animate_segmented` 工作流分支。

当前默认候选入口：

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_segmented_v3_single_instance.ps1
```

当前实验入口：

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_segmented_v4_anchor_overlap.ps1
```

## 固定输入

- 源图目录：`素材资产/美女图带光伏/`
- 默认源图：`素材资产/美女图带光伏/美女带背景.png`
- 30s 源视频：`素材资产/原视频/光伏30s.mp4`
- 60s 源视频：`素材资产/原视频/光伏60s.mp4`
- workflow 源文件：`workflows/Animate+Wan2.2换风格对口型.json`
- profile：`wan_2_2_animate_segmented`

## v3 单实例方案

`segmented v3 single-instance` 的设计：

- 本地先把源视频切成多个 `10s` 片段，例如 30s 为 3 段，60s 为 6 段。
- 同一个 Vast 实例内依次提交 `workflow_segment_01.json`、`workflow_segment_02.json`、后续递增段。
- 第 1 段不带 `continue_motion`。
- 第 2 段及之后使用上一段输出最后 5 帧，写成：
  - `continue_motion_01.png`
  - `continue_motion_02.png`
  - `continue_motion_03.png`
  - `continue_motion_04.png`
  - `continue_motion_05.png`
- 每段完成后从 ComfyUI `/history` 读取真实输出名并下载。
- 本地用 ffmpeg concat 合并为一个 MP4。

## v4 原图锚定 + 重叠合并方案

`segmented v4 anchor-overlap` 仍复用 v3 的单实例 Vast 生命周期：

- `stage`
- `upload_stage`
- `select_offer`
- `launch`
- `port_mapping`
- `bootstrap`
- `inference`
- `download`
- `merge_segments`
- `fetch_logs`
- `summarize_timings`
- `publish`
- `destroy`
- `update_registry`

关键差异：

- 每个片段都使用原始 `美女带背景.png` 作为 reference image 起跑。
- 第 2 段及之后不再使用上一段输出尾帧，也不注入 `continue_motion`。
- `WanAnimateToVideo.continue_motion_max_frames` 仍必须保留，当前固定为 `5`；不要删除这个必填输入。
- 运行时 workflow 只保留 `save_output=true` 的 `VHS_VideoCombine`，删除非保存用 preview combine，避免 ComfyUI 只执行 temp 预览节点。
- 本地切段支持 `-OverlapSeconds`，默认 `1.0`。
- 第 2 段及之后从 `nominal_start - overlap` 开始切，因此片段头部包含与上一段的重叠区。
- 下载所有片段后，本地优先用 ffmpeg `xfade` 合并视频重叠区；如果每个片段都有音频，同时用 `acrossfade` 合并音频。
- 合并输出必须显式写成 `yuv420p`，避免 `xfade` 默认产出 `yuv444p` 后影响浏览器播放兼容性。
- v4 当前仍是实验入口：已有一次 30s 付费实跑成功，但这次包含手动 API 补救；不要替换 v3 默认入口，除非再完成一次干净全流程验证。

适合优先验证的问题：

- 身份稳定性是否优于 v3 的尾帧续接。
- 片段边界在 `1.0s` overlap 下是否可见。
- `xfade/acrossfade` 后总时长是否接近源视频目标时长。

30s v4 补救验证：

- job：`segv4-anchor-30s-20260430-010327`
- 运行策略：`1.1-machine-registry`
- instance：`35845084`
- host：`74292`
- machine：`56486`
- 地区：`Nevada, US`
- WarmStart：`true`
- 实际缓存：`custom_nodes` 未命中、`models` 未命中、`torch` 未命中
- 结果：3 段全部通过手动补交后的 `save_output` 节点 `341` 生成真实 `audio.mp4`
- 合并：`xfade/acrossfade`，`effective_overlap_seconds=1.0`
- 合并产物时长：`29.5s`
- 本地结果：`output/wan_2_2_animate_segmented/segv4-anchor-30s-20260430-010327/downloads/wan_2_2_animate_segmented-segv4-anchor-30s-20260430-010327.mp4`
- R2：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate_segmented/segv4-anchor-30s-20260430-010327/output/wan_2_2_animate_segmented-segv4-anchor-30s-20260430-010327.mp4`

这次不算干净全流程验证，因为最初上传的 v4 workflow 删掉了必填的 `continue_motion_max_frames`，导致 ComfyUI 只执行了 temp 预览节点 `299`。修复后的脚本已用 `PrepareOnly` 验证：

- job：`segv4-prepare-fixed-30s-20260430-0200`
- 每段 `WanAnimateToVideo`：`continue_motion` 不存在，`continue_motion_max_frames=5`
- 每段 `VHS_VideoCombine`：只剩 `save_output=true` 的节点 `341`

## 已验证运行

30s 验证任务：

- job：`segv3-fixed-30s-20260429-213538`
- 运行策略：`1.1-machine-registry`
- instance：`35832602`
- host：`135723`
- machine：`24191`
- 地区：`Czechia, CZ`
- WarmStart：`true`
- 实际缓存：`custom_nodes` 未命中、`models` 未命中、`torch` 未命中
- 结果：3 段全部 `execution_success`
- 合并产物时长：`29.461s`
- 本地结果：`output/wan_2_2_animate_segmented/segv3-fixed-30s-20260429-213538/downloads/wan_2_2_animate_segmented-segv3-fixed-30s-20260429-213538.mp4`
- R2：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate_segmented/segv3-fixed-30s-20260429-213538/output/wan_2_2_animate_segmented-segv3-fixed-30s-20260429-213538.mp4`

60s 验证任务：

- job：`segv3-60s-20260429-225542`
- 运行策略：`1.1-machine-registry`
- instance：`35837663`
- host：`203531`
- machine：`49903`
- 地区：`Bulgaria, BG`
- WarmStart：`true`
- 实际缓存：`custom_nodes` 未命中、`models` 未命中、`torch` 未命中
- 结果：6 段全部 `execution_success`
- 合并产物时长：`58.899s`
- bootstrap 耗时：`535.651s`
- inference 耗时：`4215.318s`
- 本地结果：`output/wan_2_2_animate_segmented/segv3-60s-20260429-225542/downloads/wan_2_2_animate_segmented-segv3-60s-20260429-225542.mp4`
- R2：`https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate_segmented/segv3-60s-20260429-225542/output/wan_2_2_animate_segmented-segv3-60s-20260429-225542.mp4`

## 正常但容易误判的日志

V3 运行中可能出现：

```text
File '/opt/workspace-internal/ComfyUI/temp/..._00001.mp4' already exists. Exiting.
Error opening output file /opt/workspace-internal/ComfyUI/temp/..._00001.mp4.
```

30s 与 60s 验证中都出现过类似 temp 预览文件提示，但最终 `/history` 仍为 `execution_success`，真实 output 文件存在。

处理规则：

- 不要只凭这条 temp 日志销毁实例。
- 以 ComfyUI `/history/<prompt_id>` 的 `status.status_str` 和 output 文件为准。
- 如果 history 失败，再检查多个 `VHS_VideoCombine` 是否共用 `filename_prefix` 且 `no_preview=false`。

## 必须汇报

付费运行时按项目级顺序汇报：

1. `stage`
2. `launch`
3. `port mapping`
4. `bootstrap`
5. `inference`
6. `download`
7. `merge_segments`
8. `fetch_logs`
9. `summarize_timings`
10. `publish`
11. `destroy`
12. `update registry`

推理阶段需要按段汇报：

- `segment_01`：`0/4` 到 `4/4`
- `segment_02`：确认带 `continue_motion`
- 后续段：确认带 `continue_motion`

v4 运行时，推理阶段按段汇报但不要说带 `continue_motion`：

- `segment_01`：原图锚定。
- `segment_02` 及之后：原图锚定，并说明本地输入片段带 overlap 头部。
- `merge_segments`：说明使用 `xfade/acrossfade` 还是退回 `concat`。

## 不要重复踩坑

- 不要并行 `stage` 和 `launch`。
- 不要用中国或土耳其机器，默认搜索必须包含 `geolocation notin [CN,TR]`。
- 不要把命中同一台机器当成缓存命中；必须看 `warm-start hit/miss`。
- 不要猜输出文件名；必须从 `/history` 读取。
- 不要在未重新 stage/upload 的情况下验证脚本修改。
