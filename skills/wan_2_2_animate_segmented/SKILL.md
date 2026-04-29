---
name: wan_2_2_animate_segmented
description: Use when running or modifying the Wan2.2 segmented talking-photo pipeline, especially the verified v3 single-instance 30s flow with 10s segments and continue_motion tail frames.
---

# wan_2_2_animate_segmented

## 适用范围

用于 `wan_2_2_animate_segmented` 工作流分支。

当前默认候选入口：

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_segmented_v3_single_instance.ps1
```

## 固定输入

- 源图目录：`素材资产/美女图带光伏/`
- 默认源图：`素材资产/美女图带光伏/美女带背景.png`
- 30s 源视频：`素材资产/原视频/光伏30s.mp4`
- workflow 源文件：`workflows/Animate+Wan2.2换风格对口型.json`
- profile：`wan_2_2_animate_segmented`

## v3 单实例方案

`segmented v3 single-instance` 的设计：

- 本地先把 30s 视频切成 3 个 `10s` 片段。
- 同一个 Vast 实例内依次提交 `workflow_segment_01.json`、`workflow_segment_02.json`、`workflow_segment_03.json`。
- 第 1 段不带 `continue_motion`。
- 第 2/3 段使用上一段输出最后 5 帧，写成：
  - `continue_motion_01.png`
  - `continue_motion_02.png`
  - `continue_motion_03.png`
  - `continue_motion_04.png`
  - `continue_motion_05.png`
- 每段完成后从 ComfyUI `/history` 读取真实输出名并下载。
- 本地用 ffmpeg concat 合并为一个 MP4。

## 已验证运行

验证任务：

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

## 正常但容易误判的日志

V3 运行中可能出现：

```text
File '/opt/workspace-internal/ComfyUI/temp/..._00001.mp4' already exists. Exiting.
Error opening output file /opt/workspace-internal/ComfyUI/temp/..._00001.mp4.
```

这次验证中三段都出现过类似 temp 预览文件提示，但最终 `/history` 仍为 `execution_success`，真实 output 文件存在。

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
- `segment_03`：确认带 `continue_motion`

## 不要重复踩坑

- 不要并行 `stage` 和 `launch`。
- 不要用中国或土耳其机器，默认搜索必须包含 `geolocation notin [CN,TR]`。
- 不要把命中同一台机器当成缓存命中；必须看 `warm-start hit/miss`。
- 不要猜输出文件名；必须从 `/history` 读取。
- 不要在未重新 stage/upload 的情况下验证脚本修改。
