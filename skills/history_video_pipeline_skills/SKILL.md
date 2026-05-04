---
name: history_video_pipeline_skills
description: Historical lessons for pausing, resuming, reviewing, switching, or debugging older AI talking-head video pipelines with lip sync, background replacement, segmented generation, Vast/RunningHub migration, MultiTalk/InfiniteTalk tests, LTX2.3 route planning, or text-heavy source footage that may reintroduce old quality failures.
---

# history_video_pipeline_skills

## Overview

This skill is the historical failure-mode archive for AI avatar and talking-head pipelines. Use it before changing workflow stacks, when reviewing results, or when a new platform appears to solve one problem but quietly reintroduces older ones.

## When to Use

Use this skill when:
- a new workflow "looks promising" but only one metric improved
- segmented clips need to be merged into a 30s to 120s deliverable
- lip sync, background replacement, and identity consistency all matter at once
- source videos contain many subtitles, overlays, or page text
- moving from RunComfy to self-hosted GPU, Vast, RunningHub, or similar API platforms

Do not use this skill for pure image generation or non-speaking video tasks.

## Core Rule

Never evaluate a workflow on one success criterion alone.

For cloud GPU selection in this project, do not rent mainland China hosts by default.

Reason:
- cold-start downloads are slower and less predictable
- Docker Hub / Hugging Face access may require extra network workarounds
- this breaks the assumption that a fresh machine can bootstrap by itself from public sources
- a host that is cheap on paper can become more expensive in time and retry waste

A pipeline is only production-usable if it survives all of:
- mouth sync
- background cleanliness
- identity consistency
- physical placement
- segment transitions
- duration control
- reproducible deployment

## 2026-05-04 Project Pause Archive

Use this section first when the project is resumed after a break.

Current decision:

- Pause the current Wan2.2/KJ/MultiTalk experiments instead of spending more Vast time immediately.
- The latest `MultiTalk / InfiniteTalk` 10s smoke is rejected. It produced a video, but the final seconds stopped speaking and lip sync failed.
- Wan2.2/KJ at `720x1280` is too expensive and slow for the current budget/iteration loop.
- `480x848` KJ is usable for fast tests, but too low-resolution to call final delivery.
- The next likely route is `LTX2.3`, but it must be a new isolated profile/skill, not a patch on top of the KJ profile.

Important archived outcomes:

- `Wan2.2 固定图口播主线`: stable old branch for fixed-image talking output, but not the new pure-IP/background-redraw segmented solution.
- `Wan2.2 10秒分段续接版 / segmented v3_single_instance`: technically can generate 30s/60s from 10s chunks, but long-video identity and continuity still need careful frame review.
- `KJ 2.0 同图锚定版`: best fixed-scene KJ archive; one complete person+background anchor reused across segments. It can produce acceptable fixed-scene 60s output after local v5 polish, but it does not solve general口型 or arbitrary scenes.
- `KJ 2.0 背景/Mask失败版`: rejected because `bg_images/mask` suppressed mouth and body motion.
- `KJ 2.1 通用清理版`: paused; current local overlay cleaning fails on text/stickers close to the body.
- `KJ 3.0 480p竖屏同图锚定版`: `480x848` 10s accepted; 60s `30s+30s` sample failed detailed user review due to localized multi-hand and flicker artifacts.
- `KJ clean-motion / 自己做动作`: body motion may be pleasant, but mouth sync is not reliable and motion can repeat from the short template.
- `MultiTalk / InfiniteTalk 10s smoke`: rejected despite successful ComfyUI execution because final seconds did not speak / mouth did not match audio. Do not confuse this with older `MultiTalk Single` clean-anchor experiments from `docs/workflow-combos.md`; those remain historical short-video records, but they do not validate this newer InfiniteTalk smoke as a current long-video/mainline solution.

MultiTalk / InfiniteTalk smoke details:

- job: `multitalk10-smoke-20260504-001`
- local output: `output/multitalk_smoke/multitalk10-smoke-20260504-001/downloads/multitalk_smoke_multitalk10-smoke-20260504-001_00001-audio.mp4`
- review sheet: `output/multitalk_smoke/multitalk10-smoke-20260504-001/downloads/contact-sheet.jpg`
- output shape: about `11.88s`, `480x848`, `25fps`, with audio
- setup time: DockerHub v3 to port about `4m17s`, model download about `6m19s`, dependency fix/restart about `1m`, inference about `8m12s`, full open-to-destroy about `28.1m`, cost about `$0.25`
- technical warning: the final MultiTalk window needed audio embeddings beyond the available audio frames and padded the tail, which likely explains the final口型 failure
- action: do not rerun this exact setup; only revisit with a dedicated profile after fixing audio segmentation, frame count, padding, and node dependency validation

Suggested LTX2.3 restart rules:

- Use the existing isolated workflow branch/profile/skill `ltx23_talking_head_smoke`; do not pollute `wan22_kj_30s` or old `wan_2_2_animate`.
- First smoke should be `10s`, `480p` or `540p`, one subject, one clean background, and one short audio/text case.
- Current self-hosted LTX2.3 candidate is `2040333916862685186`; the older `2043593704170070018` route produced pseudo subtitles/text and should not be used as a base.
- VBVR strength `0.60` with `Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors` is the current low-risk motion preset after `ltx23-vbvr-motion-s06-20260504-01`.
- Validate LTX2.3 on five axes before production promotion:口型, identity, background replacement, duration control, and API/Vast reproducibility.
- Do not assume stronger VBVR alone solves all body motion. If口型 passes but gestures still need choreography, add IC-LoRA / reference-motion control instead of only increasing VBVR strength.
- Keep source video responsibilities separated: extract script/audio/background intent first; do not feed subtitle/sticker-heavy reference footage directly as the main motion condition unless the overlays are removed.

## Failure Modes

### 1. Person suddenly "appears" at segment joins

Symptoms:
- the second segment looks like a person fades in from nowhere
- hard cut feels like teleportation
- first frames of a new segment reset pose or scale

Typical cause:
- each segment starts from an unrelated anchor frame
- no overlap region
- segment B ignores the ending state of segment A

Mitigation:
- generate with overlap of about `0.3s` to `0.8s`
- use the tail frame of segment A as the next anchor when the workflow supports it
- keep the same reference image, prompt, LoRA weights, fps, and resolution across all segments
- prefer short crossfade or choose a hard cut inside a low-motion overlap instead of cutting on the boundary

### 2. Mouth sync fails on fast Mandarin speech

Symptoms:
- lips lag behind audio
- mouth opens too late at segment start
- fast explanatory speech turns into mumbling mouth shapes

Typical cause:
- workflow optimizes for animation or motion transfer, not dense speech articulation
- audio is too long for the model's stable window
- segment starts at a plosive or high-energy consonant

Mitigation:
- split audio into shorter utterance-level segments, usually `5s` to `10s`
- prefer dedicated talking workflows over general motion-transfer workflows for narration
- cut at natural pauses, not arbitrary timestamps
- verify whether the workflow trims to audio, hard-caps frame count, or silently resamples fps

### 3. Source text gets redrawn as gibberish

Symptoms:
- Chinese text or UI text comes back as fake glyphs
- subtitles disappear but their texture remains on clothes, panels, or walls
- solar panels, desks, or backgrounds inherit nonsense writing

Typical cause:
- original video is used as a strong visual condition
- model treats text as scene structure, not removable noise
- "cleaning" only hides text locally instead of replacing the background logic

Mitigation:
- do not feed text-heavy source video directly into the final talking workflow
- first create a clean anchor or a new background plate
- separate responsibilities: background generation first, speech generation second
- reject any workflow that claims to "remove text" but still depends on the original text-heavy frame as the main reference

### 4. Background is not truly regenerated

Symptoms:
- result looks cleaner, but still clearly derives from the old text-heavy background
- same composition remains, just blurred or patched
- user asked for new background, but output is still old scene preservation

Typical cause:
- workflow is actually "scene-preserving swap" rather than "new background generation"
- masking and patching were mistaken for full background replacement

Mitigation:
- label branches honestly: `preserve-scene`, `clean-anchor`, `true-new-background`
- check whether the background input is:
  - original frame
  - cleaned original frame
  - newly generated scene
- if the deliverable requires a new environment, do not accept "preserve scene plus patch" as success

### 5. Physical placement looks fake

Symptoms:
- feet float
- seated pose does not align with the surface
- person scale drifts and body appears too large or too small

Typical cause:
- anchor composition ignores ground plane and horizon
- full-body figure is pasted without scene-aware placement
- workflow regenerates lower body inconsistently

Mitigation:
- decide placement before animation: standing, seated, or waist-up
- use a composed anchor with correct scale and contact point
- add a simple grounding shadow in the anchor if using manual compositing
- if the workflow cannot maintain lower-body realism, crop to waist-up instead of forcing full-body

### 6. Identity drifts between clips

Symptoms:
- segment 3 face looks slightly different from segment 1
- head size changes over time
- clothing and hair vary between segments

Typical cause:
- different seeds, prompts, or LoRA stacks across segments
- using regenerated frames as anchors without guardrails
- background workflow and talking workflow disagree on appearance

Mitigation:
- pin prompt wording and weights
- keep one canonical speaker image per character
- only promote a generated frame into a new anchor if it already matches identity and scale
- archive the exact reference asset used for any accepted output

### 7. Duration does not match expected seconds

Symptoms:
- "10s" job outputs 8.7s or 10.4s
- 5-second workflows refuse longer audio
- final export is longer or shorter than narration

Typical cause:
- model is frame-count driven, not seconds-driven
- workflow fixes `num_frames`, `fps`, or `frame_load_cap`
- export node does not trim to audio
- audio duration node and sampler window disagree

Mitigation:
- inspect and record:
  - `num_frames`
  - `fps`
  - audio trim behavior
  - export node settings
- convert requested seconds into frames explicitly
- assume many "short video" workflows are capped by design until proven otherwise

### 8. A workflow solves one problem by breaking another

Common traps:
- better background, worse mouth sync
- better mouth sync, no real background replacement
- cleaner scene, but obvious identity drift
- smoother motion, but person becomes oversized

Mitigation:
- evaluate each candidate on a fixed scorecard
- never switch mainline after checking only one metric
- keep named reference outputs for comparison, not memory-based judgments

## Platform Pitfalls

### 9. Platform migration breaks reproducibility

Symptoms:
- RunComfy output looks good but self-hosted output fails or changes behavior
- API call works on the site but not via script
- same workflow JSON fails on a smaller GPU

Typical cause:
- custom nodes or model files missing
- attention mode incompatible with target GPU
- hosted platform hides preinstalled dependencies
- workflow was never successfully run once on the target platform

Mitigation:
- record exact workflow JSON, deployment ID, and model list for every accepted branch
- verify custom nodes and model paths before renting GPU time
- prefer runtime patching for incompatible settings such as attention mode
- on platforms like RunningHub, ensure the workflow has been manually run successfully before API use
- when searching Vast offers for this branch, exclude `CN` geolocation unless the workflow is explicitly prepared for China-network constraints

### 10. Cloud storage and result retrieval break automation

Symptoms:
- upload succeeds but result write-back fails
- public links open in browser but API jobs cannot read them
- output disappears with the instance

Typical cause:
- wrong bucket permission or public URL strategy
- platform requires its own upload step rather than external URL only
- no durable storage plan for accepted anchors and outputs

Mitigation:
- keep inputs, accepted anchors, and final outputs in a durable store such as R2
- store the exact URLs used by successful jobs
- separate:
  - source assets
  - generated anchors
  - final deliverables

## Recommended Evaluation Order

When comparing a new workflow, check in this order:

1. Does it actually remove or replace the text-heavy background?
2. Does it keep the same person identity and scale?
3. Does the mouth match fast speech?
4. Can it survive segment joins?
5. Can it be reproduced by API or self-hosted deployment?

If it fails earlier items, do not spend time polishing later items.

## Minimum Acceptance Checklist

Before promoting a workflow to mainline, confirm:
- background text is gone, not just blurred
- person does not pop in at transitions
- mouth sync survives fast narration
- body scale is stable
- accepted output can be reproduced with saved parameters
- source assets and outputs are archived with the exact workflow used

## Naming Guidance

Use explicit branch names. Avoid vague labels like `final` or `new`.

Prefer names that encode behavior:
- `clean-anchor-multitalk`
- `true-bg-dreamid-multitalk`
- `preserve-scene-swap`
- `wan22-animate-test`

This prevents accidental promotion of the wrong branch.
