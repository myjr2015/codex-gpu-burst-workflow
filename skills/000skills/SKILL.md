---
name: 000skills
description: Use when reviewing, switching, or debugging AI talking-head video pipelines with lip sync, background replacement, segmented generation, Vast or RunningHub migration, or text-heavy source footage that may reintroduce old quality failures.
---

# 000skills

## Overview

This skill is a compact failure-mode checklist for AI avatar and talking-head pipelines. Use it before changing workflow stacks, when reviewing results, or when a new platform appears to solve one problem but quietly reintroduces older ones.

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

A pipeline is only production-usable if it survives all of:
- mouth sync
- background cleanliness
- identity consistency
- physical placement
- segment transitions
- duration control
- reproducible deployment

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
