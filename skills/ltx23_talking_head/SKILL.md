---
name: ltx23_talking_head
description: Use when testing or running the isolated LTX2.3 single-image plus audio talking-head route on Vast/ComfyUI, including the current V3 reference-action plus audio lip-sync candidate, before adding PromptRelay or long-video segmentation.
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
- current action-mimic workflow: `workflows/LTX2.3动作模仿+音频对口型-V3候选.json`
- current action-mimic RunningHub workflow id: `2044017351640748034`
- rejected baseline workflow: `workflows/LTX2.3单图音频对口型-smoke.json`
- rejected baseline RunningHub workflow id: `2043593704170070018`
- default entry: `scripts/run_ltx23_talking_head_smoke_end_to_end.ps1`
- default output: `512x896`, `24fps`, about `10s`
- default input image: `素材资产/美女图带光伏/美女带背景.png`
- default input audio: `output/ltx23_runninghub/_inputs/audio_30s.wav`

## Current Strategy

The current low-risk stack for plain talking-head checks is:

1. One composed speaker image.
2. One short audio file.
3. LTX2.3 no-subtitle audio/video latent workflow.
4. VBVR motion LoRA at strength `0.60`.
5. Prompt-only background module.
6. No PromptRelay / Qwen / Gemini workflow nodes in the self-host runtime.
7. No 1080p or upscale-first production run.

The current user-target stack for action mimic is:

1. One composed RGB speaker/background anchor image.
2. One short audio file.
3. One short reference video for body/hand rhythm.
4. V3 action-mimic workflow `2044017351640748034`.
5. `DWPreprocessor -> LTXAddVideoICLoRAGuide` for reference action.
6. `LTXVAudioVAEEncode -> LTXVConcatAVLatent -> LTXVReferenceAudio` for lip-sync/identity audio conditioning.
7. Union Control IC-LoRA at guide strength `0.55`, action LoRA strength `0.75`, ID LoRA strength `0.75`, identity guidance `2.5`.

Only move to 30s/60s after the 10s V3 action-mimic sample passes playback review.

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

## 2026-05-04 VBVR Motion Smoke

The first motion add-on should stay on the same no-subtitle LTX2.3 base:

- motion LoRA: `Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors`
- source: `LiconStudio/Ltx2.3-VBVR-lora-I2V`
- runtime chain: distilled LoRA -> VBVR motion LoRA -> `LTX2_NAG` -> sampler

Test results:

- `ltx23-vbvr-motion-20260504-01`, strength `0.35`: generated successfully, no visible pseudo subtitles, mouth still moved near the tail, but hand/body motion remained too weak.
- `ltx23-vbvr-motion-s06-20260504-01`, strength `0.60`: generated successfully after the `kornia_rs` fix below; output is `512x896`, `24fps`, `241` frames, video `10.041667s`, audio `10.000000s`; contact sheets show a real mid-clip right-hand gesture and no visible bottom subtitle/text artifacts. Prompt execution was `297.23s`.

Current recommendation:

- Use VBVR strength `0.60` as the current low-risk talking-head motion preset.
- Do not jump to VBVR `1.0` just to force bigger gestures; RunningHub notes and the local result both suggest higher strength can destabilize the person.
- If the user wants richer choreographed hand/pose motion after accepting lip sync, move to IC-LoRA / reference-motion control instead of only increasing VBVR.

Motion metric note:

- Compared with the base and `0.35`, the `0.60` run raised the hands/sleeves frame-diff mean from about `1.50` to `2.42`, while mouth/face motion stayed in the same band.

## 2026-05-05 Background Prompt Module

The background prompt path is now implemented as a prompt-only module:

- `scripts/prepare_ltx23_talking_head_prompt.mjs` composes the positive prompt from `speaker_prompt`, `background_prompt`, `camera_prompt`, and `prompt_guardrails`.
- `scripts/stage_ltx23_talking_head_job.ps1` and `scripts/run_ltx23_talking_head_smoke_end_to_end.ps1` expose `-BackgroundPrompt`, `-SpeakerPrompt`, `-CameraPrompt`, and `-PromptGuardrails`.
- `-PositivePrompt` still exists as a full override. If it is provided, the composed module is bypassed and metadata records `positive_prompt_source=full_override`.
- The default `background_prompt` is a clean photovoltaic technology scene with no readable signs or background text.
- The staged metadata and manifest record the final positive prompt plus the separate background prompt fields.

This module deliberately does not load PromptRelay, Qwen3-VL, Gemini, or RunningHub wrapper nodes into the self-hosted runtime. Downloaded RunningHub workflows with `AILab_QwenVL_Advanced`, `TextGenerateLTX2Prompt`, Gemini, or PromptRelay are reference material only unless a later branch explicitly validates their dependencies.

Local prepare-only validation:

- job: `_test-ltx23-bgprompt-prepare`
- validated_at: `2026-05-05T00:47:17+08:00`
- output: `512x896`, `24fps`, `241` frames, expected video `10.0417s`
- motion LoRA: `Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors`, strength `0.60`
- no paid Vast machine was launched for this validation.

## 2026-05-05 Transparent Image Background Smoke

Do not promote the direct-transparent-image background route.

Paid smoke:

- job: `ltx23-vlbg-transparent-vbvr-20260505-03`
- input image: `素材资产/美女图无背景纯色/纯色站着.png`
- background prompt source: sampled `素材资产/原视频/光伏10s.mp4` frames and manually distilled the photovoltaic rooftop scene
- motion LoRA: `Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors`
- motion LoRA strength: `0.60`
- output: `512x896`, `24fps`, `241` frames, video `10.041667s`, audio `10.000000s`
- prompt execution: `263.44s`
- total until download: about `24m`
- instance: `36131696`, Spain RTX 3090, host `96250`, machine `51970`, driver `580.95.05`, `dph_total=0.19333333333333333`
- local result: `output/ltx23_talking_head_smoke/ltx23-vlbg-transparent-vbvr-20260505-03/downloads/ltx23_talking_head_smoke-ltx23-vlbg-transparent-vbvr-20260505-03_00001_.mp4`
- R2 result: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-vlbg-transparent-vbvr-20260505-03/output/ltx23_talking_head_smoke-ltx23-vlbg-transparent-vbvr-20260505-03_00001_.mp4`
- instance destroyed and `vastai show instances --raw` returned `[]`

Review result:

- Background generation worked: clean rooftop photovoltaic scene, blue panels, utility building, sky, and distant ridge.
- Mouth still appears active in the tail contact sheet.
- The output is rejected because pseudo English subtitle fragments reappeared across the lower frame and over the subject.
- The output is also rejected for motion: VBVR `0.60` did not produce useful hand gestures in this configuration, so the body reads too static for the user's target.

Conclusion:

- Do not feed the transparent RGBA character image directly into this LTX2.3 route and rely on the prompt to synthesize the full background.
- The next background route should first build a clean RGB anchor image: transparent character composited onto a no-text photovoltaic background plate. Then feed that composed image into LTX2.3 with the existing no-subtitle workflow and VBVR `0.60`.
- Keep the background prompt module, but treat it as anchor/background generation guidance, not as permission for LTX2.3 to hallucinate a full scene around raw alpha.
- Do not claim the current VBVR-only route solves gesture/action. After the clean RGB anchor passes the no-subtitle and full-body checks, add IC-LoRA / reference-motion control for real hand/body action.

## 2026-05-05 Action-Mimic V3 Smoke

This is the first self-hosted route that should be called action mimic.

Workflow:

- RunningHub id: `2044017351640748034`
- source file: `workflows/LTX2.3动作模仿+音频对口型-V3候选.json`
- prepare script: `scripts/prepare_ltx23_action_mimic_prompt.mjs`
- local entry: `scripts/run_ltx23_talking_head_smoke_end_to_end.ps1 -ActionMimic`

Core chain:

- reference action: `VHS_LoadVideo -> DWPreprocessor -> ResizeImageMaskNode -> LTXAddVideoICLoRAGuide`
- action LoRA: `LTXICLoRALoaderModelOnly` with `ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors`
- lip-sync audio: `LoadAudio -> LTXVAudioVAEEncode -> SetLatentNoiseMask -> LTXVConcatAVLatent`
- identity/audio guidance: `LTXVReferenceAudio` plus `ltx-2.3-id-lora-talkvid-3k.safetensors`

Paid smoke:

- job: `ltx23-action-mimic-v3-20260505-01`
- final instance: `36137864`, Czechia RTX 3090, host `151822`, machine `81287`, driver `590.48.01`, `dph_total=0.212`
- output: `512x896`, `24fps`, `241` frames, video `10.041667s`, audio `10.000000s`
- prompt execution: `284.11s`
- remote lifecycle: `708s`; remote bootstrap `401s`; wait history `291s`
- required node validation passed, including `DWPreprocessor`, `LTXAddVideoICLoRAGuide`, `LTXICLoRALoaderModelOnly`, `LTXVReferenceAudio`, `LTXVAudioVAEEncode`, and `LTXVConcatAVLatent`
- DWPose logs detected `1 people` on the reference frames and sampling reached `8/8`
- local result: `output/ltx23_talking_head_smoke/ltx23-action-mimic-v3-20260505-01/downloads/ltx23_talking_head_smoke-ltx23-action-mimic-v3-20260505-01_00001_.mp4`
- R2 result: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-action-mimic-v3-20260505-01/output/ltx23_talking_head_smoke-ltx23-action-mimic-v3-20260505-01_00001_.mp4`
- review sheets:
  - `output/ltx23_talking_head_smoke/ltx23-action-mimic-v3-20260505-01/frame_review/output_contact_1fps.jpg`
  - `output/ltx23_talking_head_smoke/ltx23-action-mimic-v3-20260505-01/frame_review/output_tail_8s_10s.jpg`
  - `output/ltx23_talking_head_smoke/ltx23-action-mimic-v3-20260505-01/frame_review/reference_vs_output_1fps.jpg`

Review result:

- No pseudo English/Chinese subtitles were visible in the 1fps and tail contact sheets.
- No duplicate person or first-frame two-person issue was visible in the contact sheets.
- Tail frames still show mouth motion.
- Hand/body action is clearly stronger than VBVR-only: pointing and two-hand open gestures line up with the reference-video rhythm in the side-by-side sheet.
- Final lip-sync acceptance still requires normal playback with audio; contact sheets only prove mouth activity, not phoneme-level sync.

Startup notes:

- `36136873` was destroyed before inference because Vast startup stopped before `8188` port mapping and no onstart logs appeared.
- `36137290` was destroyed before inference because ports were mapped but HTTP/SSH timed out externally.
- These were host/startup failures, not LTX workflow failures.

## 2026-05-05 Sitting RGB Anchor V3 Tests

The user rejected the first V3 sample because the source anchor was not a seated full-body transparent-subject composition:

- the run used the old `素材资产/美女图带光伏/美女带背景.png` style anchor
- the output did stronger hand/action mimic, but the pose did not stay as the seated original-video setup
- extra-hand risk likely came from a mismatch between the old anchor pose/clothing outline and the seated reference video

New route tested:

- source transparent subject: `素材资产/美女图无背景纯色/纯色坐着.png`
- composed RGB anchors under `output/ltx23_talking_head_smoke/_anchors/`
- reference action video: `素材资产/原视频/光伏10s.mp4`
- V3 action settings: `ActionGuideStrength=0.45`, `ActionLoraStrength=0.65`, `IdentityLoraStrength=0.75`, `IdentityGuidanceScale=2.5`

Paid tests:

- `ltx23-action-mimic-v3-sitting-anchor-20260505-01`
  - anchor: `ltx23_sitting_rgb_anchor_512x896_bgplate_v4.png`
  - output passed the seated/full-body and obvious multi-hand checks, but generated pseudo Chinese subtitles in the lower frame
  - cause estimate: the synthetic gray floor/lower strip plus subtitle-heavy reference video encouraged a subtitle/lower-third region
- `ltx23-action-mimic-v3-sitting-anchor-v5-20260505-01`
  - anchor: `ltx23_sitting_rgb_anchor_512x896_bgplate_v5_nobar.png`
  - output still generated pseudo Chinese subtitles even after removing the gray lower strip
  - seated/full-body composition stayed acceptable and obvious multi-hand artifacts were not visible in contact sheets
  - final status: rejected because subtitle artifacts remain

Speed notes from `ltx23-action-mimic-v3-sitting-anchor-v5-20260505-01` on Bulgaria RTX 3090 `instance=36173025`, `machine=49903`, `driver=580.95.05`, `dph_total=0.18333333333333335`:

- Vast reported good general network (`inet_down=730.9 Mbps`, `dlperf=44.37`), but PyPI wheel sources were slow.
- `onnxruntime_gpu-1.25.1` downloaded `271.3 MB` at only about `127.6 kB/s`; this dominated the slow custom-node bootstrap.
- `bootstrap.custom_nodes` took `2262s`; `bootstrap.python_dependencies` took `890s`.
- LTX model downloads were healthy: the `23.2GB` transformer downloaded in `477s`, about `49 MB/s`; all model downloads took `732s`.
- Prompt execution was `348.45s`; total until download was `4370s`; instance was destroyed and `vastai show instances --raw` returned `[]`.

Conclusion:

- Using a seated full-body RGB anchor fixes the main pose/full-body direction and reduces obvious multi-hand risk.
- It does not solve subtitle artifacts while the action reference video itself contains large subtitles, banners, and stickers.
- Do not continue paid V3 action-mimic tests with raw `光伏10s.mp4` as the reference if the acceptance criterion includes no text.
- Next action is to create or obtain a no-subtitle/no-overlay seated reference-action video, or preprocess the reference so DWPose/action conditioning is not contaminated by text overlays, then rerun V3 with the seated RGB anchor.

## 2026-05-05 V6 Grounded Anchor + Clean Reference Test

Paid run:

- job: `ltx23-v6-grounded-cleanref-fullbody-20260505-01`
- instance: `36179630`, RTX 3090, host `436128`, machine `57621`, driver `590.48.01`, `dph_total=0.213333333333333`
- anchor: `output/ltx23_talking_head_smoke/_anchors/ltx23_sitting_rgb_anchor_512x896_bgplate_v6_grounded_synthetic_clean.png`
- reference action: `output/ltx23_talking_head_smoke/_references/光伏10s_clean_reference_v6_skip1.mp4`
- action settings: `ActionGuideStrength=0.40`, `ActionLoraStrength=0.62`, `IdentityLoraStrength=0.75`, `IdentityGuidanceScale=2.5`
- output: `512x896`, `24fps`, `241` frames, video about `10.041667s`
- prompt execution: `263.22s`
- total until download: `1286s`
- local result: `output/ltx23_talking_head_smoke/ltx23-v6-grounded-cleanref-fullbody-20260505-01/downloads/ltx23_talking_head_smoke-ltx23-v6-grounded-cleanref-fullbody-20260505-01_00001_.mp4`
- R2 result: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-v6-grounded-cleanref-fullbody-20260505-01/output/ltx23_talking_head_smoke-ltx23-v6-grounded-cleanref-fullbody-20260505-01_00001_.mp4`
- frame review:
  - `output/ltx23_talking_head_smoke/ltx23-v6-grounded-cleanref-fullbody-20260505-01/frame_review/first_frame.jpg`
  - `output/ltx23_talking_head_smoke/ltx23-v6-grounded-cleanref-fullbody-20260505-01/frame_review/output_contact_1fps.jpg`
  - `output/ltx23_talking_head_smoke/ltx23-v6-grounded-cleanref-fullbody-20260505-01/frame_review/output_tail_8s_10s.jpg`
- instance destroyed and `vastai show instances --raw` returned `[]`

Review result:

- The grounded synthetic anchor fixed the obvious floating-chair issue: stool feet and shadows read as floor contact in contact sheets.
- No visible subtitle, pseudo-Chinese text, lower-third caption, watermark, or UI text appears in the 1fps/tail contact sheets.
- The clip remains single-person and full seated body.
- Motion is intentionally conservative because the reference was cleaned and the guide was reduced to `0.40`; expect less gesture amplitude than raw-reference V3.
- This is the best current visual baseline for "seated full-body + no subtitles + lip-sync/action-mimic candidate"; final acceptance still needs user playback review for mouth sync and motion strength.

Next action:

- If user accepts visual cleanliness but wants stronger hand/body action, do not return to raw `光伏10s.mp4`.
- Create a cleaner full-body action reference that preserves hands and pose without overlay UI, then raise `ActionGuideStrength` back toward `0.45` and `ActionLoraStrength` toward `0.65`.
- Keep the v6 grounded anchor style as the default for seated tests until a better real-photo grounded anchor is prepared.

## Kornia CPU Compatibility Trap

Some cheap 3090 hosts have old CPUs even when the GPU and driver are fine. Example:

- instance `36106501`
- host `96250`
- machine `36223`
- CPU `Core i7-3770`
- driver `590.48.01`

Symptom:

- ComfyUI exits during startup with `Fatal Python error: Illegal instruction`
- stack points to `/usr/local/lib/python3.12/dist-packages/kornia_rs/__init__.py`
- import path comes through ComfyUI builtin `comfy_extras/nodes_canny.py`

Action:

- Do not treat this as an LTX workflow or VBVR LoRA failure.
- Pin `kornia==0.7.1` and uninstall `kornia-rs` / `kornia_rs`; this allows ComfyUI to load `nodes_canny.py` on old CPUs.
- Keep this fix in `scripts/bootstrap_ltx23_talking_head.sh`, because ComfyUI requirements currently allow floating `kornia>=0.7.1`, which can install `kornia 0.8.x` plus incompatible `kornia_rs`.

## Model and Runtime Notes

The current candidate starts from a RunningHub no-subtitle workflow, but the runtime JSON is simplified for self-hosting.

Expected model files:

- `models/checkpoints/ltx-2.3-22b-dev-fp8.safetensors`
- `models/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors`
- `models/loras/ltx-2.3-22b-distilled-lora-384.safetensors`
- `models/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.0.safetensors`

The bootstrap uses PyTorch CUDA `cu128` because LTX2.3 FP8 expects a newer CUDA/PyTorch stack than the older Wan2.2 branch.

The bootstrap also installs `ComfyUI-KJNodes` for `LTX2_NAG`. Avoid adding VideoHelperSuite or MelBand nodes unless the simplified runtime fails quality review and the added dependency has a clear purpose.

Prompt generation model note:

- The current self-host branch does not download a separate prompt-generation LLM.
- If using cloud LLM/API prompt generation later, the local file size is effectively zero, but it depends on the API key and provider billing.
- If copying RunningHub Qwen3-VL prompt workflows locally, expect a multi-GB model dependency such as Qwen3-VL 4B FP8 plus custom nodes; keep that as a separate experiment, not the default LTX smoke path.

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

- Background prompt generation is now connected as a prompt-only module.
- VBVR strength `0.60` is now the current motion preset.
- The first IC-LoRA / reference-motion route is now V3 action mimic `2044017351640748034`; keep it as a separate `-ActionMimic` mode, not as the default talking-head mode.
- Add first/last-frame continuity only when moving beyond 10s smoke.
- Add PromptRelay timeline only when a multi-shot timeline is needed; do not add it just for fixed-scene talking-head output.

Do not combine PromptRelay, VL prompt generation, transparent raw alpha, and 30s/60s segmentation into the same next run.

## 2026-05-05 Action-Mimic Todo

Current user target is not only lip sync. The desired final route is:

1. Extract/use the original video speech content for lip-sync talking-head output.
2. Mimic the original video's body motion / hand gestures / camera movement.
3. Use a transparent female subject image plus regenerated photovoltaic background prompt.

Important distinction:

- The current self-host route uses `2040333916862685186` as the no-subtitle audio/lip-sync base, with VBVR `0.60` for light natural motion.
- VBVR is not strict original-video action mimic. It can add natural body/hand motion, but it does not read and reproduce the user's source-video gestures.
- The V3 route `2044017351640748034` has now connected IC-LoRA / reference-motion / Union Control and passed a 10s visual smoke, so it can be called the current action-mimic candidate.

Downloaded RunningHub analysis to reuse:

- Directory: `workflows/temp/runninghub_ltx23_exact/`
- Search keywords: `ltx2.3`, `ltx 2.3`
- Unique workflows downloaded/exported: `1124`
- Key candidate table: `workflows/temp/runninghub_ltx23_exact/重点候选_workflows.csv`
- Report: `workflows/temp/runninghub_ltx23_exact/LTX2.3工作流下载与组合方案报告.md`
- Counts from analysis: `1108` workflows have LTX audio nodes, `112` have audio + VBVR, about `194` have explicit action/reference/control signals by title or model keywords.

For the next action/reference experiment, inspect these P1 candidates first instead of downloading everything again:

- `2044017351640748034`: `LTX2.3_自定义音频+人物动作迁移V3（单采IDLoRA）`
- `2044022005221036033`: `LTX2.3_自定义音频+人物动作迁移V4（三采IDLoRA）`
- `2047612025181835265`: `LTX-2.3_ICLoRA_Union_Control_Distilled_controlnet`
- `2046118754756595713`: `LTX2.3 图生视频｜+参考视频运镜（仅参考运镜） IC LoRA`
- `2048694979278671873`: `LTX-2.3_动作参考并保持脸部一致性`

Recommended sequence:

1. Ask for playback review of `ltx23-action-mimic-v3-20260505-01`; contact sheets passed text/person/action checks, but phoneme-level lip sync still needs audio playback.
2. If accepted, run a longer V3 action-mimic clip before designing segmentation.
3. If background needs the transparent-character route, create a clean RGB photovoltaic anchor first; do not feed raw transparent RGBA into LTX2.3.
4. Keep audio/lip sync as the acceptance gate. Reject action-mimic variants if they suppress mouth movement, change identity, or create extra hands.
