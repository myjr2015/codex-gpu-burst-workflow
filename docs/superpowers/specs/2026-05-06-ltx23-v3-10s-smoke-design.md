# LTX2.3 V3 自托管 10s 快速探测设计

日期：2026-05-06

## 背景

当前项目已有 `1124` 个本地 RunningHub LTX2.3 workflow 导出和分析结果，覆盖口型底座、VBVR、IC-LoRA 动作迁移、首尾帧/多帧、PromptRelay 等类型。目标不是把多个完整 workflow 串成一个巨型工作流，而是从这些 workflow 中抽取可控模块，先用低成本 `10s` 付费窗口验证最小组合。

用户已确认第一轮方向为：

- 使用 `2044017351640748034 / LTX2.3_自定义音频+人物动作迁移V3（单采IDLoRA）` 的自托管 V3 action-mimic 链。
- 本地没有 GPU，完整推理需要租 Vast 机器。
- 第一轮从 `20s` 改为 `10s` 快速探测。
- 背景直接使用 `VL 反推` 得到的背景描述，不用泛化默认背景。
- 口型、动作、画面稳定三项都是硬闸门。

## 目标

跑通一个可复查的 `10s` LTX2.3 V3 自托管样片，用于判断该链路是否值得继续扩展到 `20s` 或后续分段长视频。

通过标准：

- 口型：正常播放中全片嘴部跟随音频，尾部 `8s-10s` 不停嘴。
- 动作：至少有可见手势、上半身、头肩运动之一，不能像静态照片。
- 稳定：无伪字幕/伪文字、无人像分裂、无明显多手、无背景文字污染、无腿脚/椅子结构崩坏。

非目标：

- 第一轮不做 `20s`、`30s` 或 `60s`。
- 第一轮不启用 V4 三采 IDLoRA。
- 第一轮不接 PromptRelay、Qwen3-VL、Gemini 等节点到 LTX runtime。
- 第一轮不直接上 `720x1280`、`1080p` 或高清放大链。
- 不把 1000 多个 workflow 串成单个巨型 workflow。

## 输入资产

本轮输入固定为三类：

- 人物/背景 anchor：优先复用已验证的干净 RGB 坐姿光伏 anchor，例如 v6 grounded clean anchor；不直接输入透明 RGBA 人物图让 LTX 生成整套背景。
- 音频：真实 `10s` 中文音频，推理和验收都以该音频为准。
- 参考动作：使用已清理的 `10s` reference 动作视频，不使用带字幕、贴纸、定位气泡或横幅的原始视频作为强视觉条件。

背景提示词使用用户指定路线：

- 先由 VL 从参考帧/原视频反推光伏场景、机位、环境和画面风格描述。
- 将反推文本作为 `-BackgroundPrompt` 拼进 LTX 正向 prompt。
- VL 只在推理前生成背景描述；本轮 LTX runtime 不加载 VL / Qwen / Gemini / PromptRelay 节点。

## 运行参数

基础参数：

- workflow：`workflows/LTX2.3动作模仿+音频对口型-V3候选.json`
- RunningHub 源 id：`2044017351640748034`
- profile：`ltx23_talking_head_smoke`
- mode：`-ActionMimic`
- resolution：`512x896`
- fps：`24`
- duration：`10s`
- frame count：约 `241` 帧

V3 动作/身份参数先使用已跑干净样本附近的保守区间：

- `ActionGuideStrength=0.45`
- `ActionLoraStrength=0.65`
- `IdentityLoraStrength=0.75`
- `IdentityGuidanceScale=2.5`

如果口型不足，第一优先不是让 LTX 重画整段，而是把生成结果接 RunningHub `2046494511848755201 / 精准视频口型同步` 做 mouth-only 后处理。

## Vast 租机策略

本轮为自托管付费探测，本地不跑模型。

默认租机：

- GPU：`RTX 3090 24GB`
- storage：`180GB`
- region：默认排除 `CN`
- 价格判断：使用带 `--storage 180` 后的 `dph_total`，不是裸 GPU 价。

价格闸门：

- 优先：`dph_total <= $0.15/h`
- 回退：`<= $0.16/h`
- 临时拉高：`<= $0.18/h`
- 超过 `$0.18/h`：先说明原因并等待用户确认

`TR` 只作为测速风险信号，不作为硬排除。`driver_version` 只记录用于诊断，不单独作为硬过滤条件；真实兼容性以 CUDA / torch / bootstrap 日志为准。

止损规则：

- `8188` 长时间不映射或外部 HTTP/SSH 不稳定，销毁换机。
- CUDA / torch 明确不兼容，销毁换机。
- PyPI / NVIDIA wheel 长时间低于约 `500KB/s` 且无进展，销毁换机。
- 大模型下载有稳定 MB/s 或已经进入正常 inference，不随意销毁。
- Vast 返回余额不足时立刻停止，不继续换机。

付费运行必须按项目阶段汇报：`stage`、`launch`、`port mapping`、`bootstrap`、`inference`、`download`、`fetch_logs`、`summarize_timings`、`publish`、`destroy`、`update registry`。

## 复查流程

下载后自动生成以下复查产物：

- `1fps` 全片拼图。
- `8s-10s` 尾段拼图。
- 伪文字、色块、多手、结构异常等风险检测结果。
- R2 发布链接，便于正常播放验片。

自动复查只做筛查。口型是否逐字跟随、手部是否自然，最终仍以正常播放为准。

## 失败分流

口型失败：

- 先接 `204649` 做 mouth-only 后处理。
- 若后处理仍失败，再回看 `204071 facehand-04 + 204649` 的稳定口型链。

动作失败：

- 如果太静，微调 V3 guide / LoRA 权重。
- 如果动作乱，降低 body 控制或参考 `203136` 的动作节点策略。
- 不直接换回带字幕原始参考视频。

画面污染失败：

- 优先检查 anchor、reference、VL 反推背景描述是否引入文字或背景污染。
- 不对大面积伪字幕做后期遮罩硬修。
- 必要时换更干净参考动作或重做背景描述。

## 后续扩展条件

只有当 `10s` 探测同时通过口型、动作和稳定三项闸门，才进入下一步：

1. 用同一链路测 `20s` 单段上限。
2. 如果 `20s` 通过，再设计 `30s/60s` 分段长视频。
3. 首尾帧/多帧 workflow 只在进入分段设计时引入，用于段间衔接，不进入第一轮 `10s` 快速探测。

## 自审

- 无未完成空章节。
- 设计范围聚焦在 `10s` 自托管 V3 探测，没有混入 `20s/60s` 实现。
- VL 背景反推被限定为推理前 prompt 输入，没有和 runtime 节点依赖混用。
- Vast 租机、止损、验收和失败分流均有明确标准。
