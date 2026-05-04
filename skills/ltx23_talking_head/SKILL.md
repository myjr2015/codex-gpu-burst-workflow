---
name: ltx23_talking_head
description: Use when testing or running the isolated LTX2.3 single-image plus audio talking-head route on Vast/ComfyUI, before adding VBVR, IC-LoRA motion transfer, PromptRelay, or long-video segmentation.
---

# ltx23_talking_head

## Scope

This skill is for the new LTX2.3 route only.

Do not mix this branch into:

- `wan_2_2_animate`
- `wan_2_2_animate_segmented`
- `wan22_kj_30s`
- `wan22_kj_30s_segmented`

Current branch:

- profile: `ltx23_talking_head_smoke`
- current candidate workflow: `workflows/LTX2.3单图音频对口型-无字幕候选.json`
- current candidate RunningHub workflow id: `2040333916862685186`
- rejected baseline workflow: `workflows/LTX2.3单图音频对口型-smoke.json`
- rejected baseline RunningHub workflow id: `2043593704170070018`
- default entry: `scripts/run_ltx23_talking_head_smoke_end_to_end.ps1`
- default output: `512x896`, `24fps`, about `10s`
- default input image: `素材资产/美女图带光伏/美女带背景.png`
- default input audio: `output/ltx23_runninghub/_inputs/audio_30s.wav`

## Current Strategy

First prove the smallest useful self-hosted path:

1. One composed speaker image.
2. One short audio file.
3. LTX2.3 audio/video latent workflow.
4. No VBVR.
5. No IC-LoRA motion transfer.
6. No PromptRelay.
7. No 1080p or upscale-first production run.

Only add the next module after this base route passes lip-sync and tail behavior review.

## 2026-05-04 Smoke Results

Self-hosted LTX2.3 on Vast RTX 3090 is technically viable, but the first baseline is rejected:

- `ltx23-selfhost-smoke-20260504-01`: generated `512x896`, `24fps`, about `10.04s`; self-host chain ran end to end, but the video had large pseudo-Chinese subtitle/text artifacts.
- `ltx23-selfhost-nag-nosub-20260504-01`: the first auto submit failed because `LTX2_NAG` was missing in the remote ComfyUI node set; manual no-NAG resubmit succeeded in `136.39s`, but the result still had English pseudo text such as short fake labels/word fragments.
- `ltx23-nosub-nag-20260504-01`: switched to `2040333916862685186`, installed KJNodes, validated `LTX2_NAG`, generated `512x896`, `24fps`, `10.042s` video with `10.000s` audio; prompt execution `125.28s`, total until download `922s`, instance `36102434` destroyed. 1fps and tail contact sheets show no visible pseudo subtitles/text, and the final 2 seconds still show mouth motion; still requires user mouth-sync review before promotion.

Conclusion:

- Do not build VBVR / IC-LoRA / background prompt modules on top of `2043593704170070018`.
- The current baseline is `2040333916862685186` because it explicitly targets no-subtitle output and includes `LTX2_NAG`.
- The local prepare path folds RunningHub helper nodes, replaces `VHS_VideoCombine` with `CreateVideo + SaveVideo`, bypasses nonessential MelBand/KJ resize helpers, trims staged audio to the requested duration, and keeps `LTX2_NAG`.
- `LTX2_NAG` requires KJNodes on self-hosted ComfyUI; if object validation reports `LTX2_NAG` missing, fix custom node installation before spending a full inference.

## Model and Runtime Notes

The current candidate starts from a RunningHub no-subtitle workflow, but the runtime JSON is simplified for self-hosting.

Expected model files:

- `models/checkpoints/ltx-2.3-22b-dev-fp8.safetensors`
- `models/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors`
- `models/loras/ltx-2.3-22b-distilled-lora-384.safetensors`
- `models/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.0.safetensors`

The bootstrap uses PyTorch CUDA `cu128` because LTX2.3 FP8 expects a newer CUDA/PyTorch stack than the older Wan2.2 branch.

The bootstrap also installs `ComfyUI-KJNodes` for `LTX2_NAG`. Avoid adding VideoHelperSuite or MelBand nodes unless the simplified runtime fails quality review and the added dependency has a clear purpose.

## Vast Rules

For paid 3090 smoke runs:

- exclude `CN` and `TR`
- prefer driver `580.*` or newer
- default max total price: `$0.20/h`
- default storage: `180GB`
- destroy the instance after result download/publish unless deliberately keeping it for debugging

Do not use the KJ Docker template as the default for this branch. It was built for Wan/KJ custom nodes and ONNX preprocessing, not for LTX2.3 core nodes.

## Acceptance Checklist

Do not promote the branch until the downloaded MP4 is reviewed for:

- mouth keeps following the audio through the full clip
- final 2 seconds do not stop speaking early
- face identity remains close to the input image
- no bottom subtitles, pseudo-Chinese text, watermarks, or lower thirds
- background stays clean
- output can be reproduced through saved workflow/runtime JSON on Vast

## Next Modules

After the base route passes:

- Add PromptRelay / previous Wan2.2 background prompt generation as a prompt-only module.
- Add VBVR only if the base route has jitter, tail instability, or weak digital-human motion.
- Add IC-LoRA / reference-motion only if the body is too stiff, and test at low guide strength first.
- Add first/last-frame continuity only when moving beyond 10s smoke.

Do not combine all modules in one first run.
