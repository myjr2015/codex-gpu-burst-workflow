---
name: wan22_kj_30s
description: Use when running the 2.0 KJ single-shot 30s Wan2.2 Animate workflow with one fixed transparent/pure-color IP image, one 30s reference action video, and prompt-redrawn background.
---

# wan22_kj_30s

## Scope

Use this skill only for the KJ 30s branch:

- workflow: `workflows/书墨-30s长视频-wan2-2AnimateKJ版_v2版-参考动作、表情.json`
- entry: `scripts/run_wan22_kj_30s_end_to_end.ps1`
- profile: `wan22_kj_30s`
- default IP image for the current seated photovoltaic reference videos: `素材资产/美女图无背景纯色/纯色坐着.png`
- default reference video: `素材资产/原视频/光伏30s.mp4`
- staged image name: `ip_image.png`
- staged video name: `reference_30s.mp4`

This is not the old `wan_2_2_animate` production branch and not the segmented v3/v4 branch.

For videos longer than 30s, use the experimental wrapper:

- entry: `scripts/run_wan22_kj_30s_segmented_end_to_end.ps1`
- profile: `wan22_kj_30s_segmented`
- default video: `素材资产/原视频/光伏60s.mp4`
- segment size: `30s`
- merge: local `ffmpeg concat` with transcode fallback

This wrapper does not add a ComfyUI merge plugin. It reuses the existing KJ 30s workflow per segment and merges downloaded MP4 files locally. The KJ workflow does not expose `continue_motion`, so cross-segment continuity is not guaranteed until visually verified.

## Current Status

Candidate validated run:

- job: `kj30s-2p0-20260430-0850`
- Vast instance: `35869672`
- machine: `54625`
- host: `344939`
- GPU: `RTX 3090`
- driver: `580.126.09`
- location: `California, US`
- dph_total: `$0.20/h`
- output: `29.8125s`, `720x720`, `16fps`, with audio
- local result: `output/wan22_kj_30s/kj30s-2p0-20260430-0850/downloads/wan22_kj_30s-kj30s-2p0-20260430-0850_00001-audio.mp4`
- public result: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan22_kj_30s/kj30s-2p0-20260430-0850/output/wan22_kj_30s-kj30s-2p0-20260430-0850_00001-audio.mp4`

Quick frame review passed for continuity:

- `output/wan22_kj_30s/kj30s-2p0-20260430-0850/frame_review/contact-2s.jpg`
- `output/wan22_kj_30s/kj30s-2p0-20260430-0850/frame_review/keyframes.jpg`

RTX 4090 comparison run:

- job: `kj30s-4090-greece-20260430-121150`
- Vast instance: `35877643`
- machine: `50910`
- host: `283684`
- GPU: `RTX 4090`
- driver: `580.126.09`
- location: `Greece, GR`
- dph_total: `$0.3155555555555556/h`
- HF speedtest: `89.04 MiB/s`, estimated cold model download `6.2 min`
- actual model downloads: `474s`
- prompt execution: `00:36:13`
- total until local download: `2995s`
- output: `29.8125s`, `720x720`, `16fps`, with audio
- local result: `output/wan22_kj_30s/kj30s-4090-greece-20260430-121150/downloads/wan22_kj_30s-kj30s-4090-greece-20260430-121150_00001-audio.mp4`
- public result: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan22_kj_30s/kj30s-4090-greece-20260430-121150/output/wan22_kj_30s-kj30s-4090-greece-20260430-121150_00001-audio.mp4`
- quick frame review: `output/wan22_kj_30s/kj30s-4090-greece-20260430-121150/frame_review/keyframes-3s.jpg`

60s segmented RTX 4090 run:

- job: `kj30s-seg60-4090-nl-20260430-133517`
- Vast instance: `35881500` (destroyed after accepted output was published)
- machine: `54495`
- host: `213498`
- GPU: `RTX 4090`
- driver: `590.48.01`
- location: `Netherlands`
- dph_total: `$0.37333333333333335/h`
- HF speedtest: `40.22 MiB/s`, estimated cold model download `13.8 min`
- actual model downloads: about `16m50s`
- first output attempt:
  - segment 1: `29.8125s`, `720x720`, `16fps`
  - segment 2: `29.8125s`, `720x720`, `16fps`
  - merged duration: `59.648s`
  - visual acceptance: failed, because the back half showed a large standing duplicate/background person
- `s02fix` attempt:
  - reused the same live instance and cached models
  - reran only segment 2 with a new seed and stronger single-seated-person prompt/negative prompt
  - merged `s01 + s02fix` with local `ffmpeg concat_copy`
  - output: `59.648s`, `720x720`, `16fps`, with audio
  - visual acceptance: failed, because segment 1 and segment 2 still did not keep a consistent chair state
  - local result: `output/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/downloads/wan22_kj_30s_segmented-kj30s-seg60-4090-nl-20260430-133517-s02fix.mp4`
  - public result: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/output/wan22_kj_30s_segmented-kj30s-seg60-4090-nl-20260430-133517-s02fix.mp4`
  - frame review:
    - `output/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/frame_review/s02fix-keyframes-5s.jpg`
    - `output/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/frame_review/s02fix-second-half-1s.jpg`
    - `output/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/frame_review/s02fix-45s.jpg`
    - `output/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/frame_review/s02fix-50s.jpg`
    - `output/wan22_kj_30s_segmented/kj30s-seg60-4090-nl-20260430-133517/frame_review/s02fix-55s.jpg`

60s fixed-prompt anchor run with seated IP:

- job: `kj60-bgprompt-anchor-4090-20260430-194236`
- GPU: `RTX 4090`
- output: `59.648s`, `720x720`, `16fps`, with audio
- setup:
  - IP image: `素材资产/美女图无背景纯色/纯色坐着.png`
  - two `30s` segments reused the same fixed photovoltaic background prompt
  - the background was generated from prompt per segment; no `美女带背景.png` background image was used
- quick review initially passed for duplicate body / double-head / background consistency
- detailed review found a hand-motion defect around final `49.5s-50.5s`
- diagnosis:
  - final generated frames did not keep the large sticker text from the reference
  - the corresponding reference-video window was segment 2 `19.5s-20.5s`, where large sticker/location text covered the lower body and hand area
  - this overlay likely polluted the pose/action condition and made the model invent hand motion / extra hand states
- local review evidence:
  - final frames: `output/wan22_kj_30s_segmented/kj60-bgprompt-anchor-4090-20260430-194236/frame_review/problem_49p5_50p5_0p1s/contact-sheet-49p5-50p5.jpg`
  - reference frames: `output/wan22_kj_30s_segmented/kj60-bgprompt-anchor-4090-20260430-194236/frame_review/reference_s02_19p5_20p5_0p1s/contact-sheet-ref-s02-19p5-20p5.jpg`
  - merged output: `output/wan22_kj_30s_segmented/kj60-bgprompt-anchor-4090-20260430-194236/downloads/wan22_kj_30s_segmented-kj60-bgprompt-anchor-4090-20260430-194236.mp4`

60s cleaned-reference rerun:

- job: `kj60-cleanref-v7-2seg-20260430-2145`
- GPU: `RTX 4090`
- setup:
  - reused accepted `s01` from `kj60-bgprompt-anchor-4090-20260430-194236`
  - cleaned only the high-risk hand-anchor window in the second 30s reference segment
  - reran `s02`, then merged old `s01` + new `s02`
- result:
  - hand / multi-hand issue around final `49.5s-50.5s` improved
  - later review found a short-lived red point around final `29.6s`, near the right leg/chair side
- diagnosis:
  - reference `26s-30s` contains red UI elements such as checkmarks and location bubbles
  - KJ conditioning can leak those non-human tokens as small artifacts even if it does not reproduce the full sticker
  - this behavior is probabilistic: the first 30s may pass even when the same class of overlay exists, while another run/segment leaks it

Important lesson:

- The 30s KJ workflow can hallucinate a second standing person when the fixed IP image is a full-body standing figure but the reference action video is seated.
- The first fix is to use a posture-matched IP image selected from the reference video / inferred prompt. For the current seated photovoltaic reference videos, use `纯色坐着.png`; for other source videos, do not hard-code seated props or chairs.
- Fixed seed only makes a run reproducible. It does not guarantee semantic continuity across independent 30s segments.
- For 60s/90s/120s segmented tests, keep the same IP image, same seed, same inferred prompt, and same negative prompt across all segments; concrete props and scene details should come from the video-to-prompt step, not from generic hard-coded rules.
- Large sticker text, subtitles, location banners, red checkmarks, location pins, and other overlays in the reference video can contaminate KJ pose/action conditioning even when the final image does not redraw the text. If overlays touch the body, hands, face, or key props, clean the reference video first, then split into 30s segments.
- This class of failure must be handled as a two-gate quality process:
  - preflight: run `scripts/analyze_reference_overlay_risk.py` and inspect high-risk overlay windows before paid inference
  - postflight: run `scripts/analyze_generated_artifact_risk.py` and inspect flagged windows after merge
  - if the final defect is only a small isolated red point or sticker speck, prefer local final-video repair
  - if hands, face, body shape, or chair/contact structure are wrong, clean the matching reference window and rerun only that 30s segment
- Do not destroy the Vast instance before local download, merge, frame review, and R2 publish are complete.

Cleanup roadmap:

- `2.0`: current path. Use rule-based overlay detection, small targeted local cleaning, and rerun only the affected 30s segment. Do not add new ComfyUI cleaning plugins to the production KJ workflow yet.
- `2.1`: evaluate video-level inpainting such as ProPainter / E2FGVI for subtitles, banners, stickers, and location bubbles that persist across frames.
- `2.2`: evaluate lighter local repair such as LaMa / MAT, Crop & Stitch, SAM / GroundingDINO / OCR masks, or color-token cleanup for red pins, checkmarks, and small sticker residue.
- Roadmap details live in `docs/KJ参考视频清理方案TODO.md`.

## Runtime Rules

Before any paid run, also read:

- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`

Default command:

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_end_to_end.ps1 `
  -JobName <job_name> `
  -RuntimeVersion 1.1-machine-registry `
  -CancelUnavail
```

Use `PrepareOnly` before paid changes:

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_end_to_end.ps1 `
  -JobName prepareonly-kj30s-<date>-<n> `
  -PrepareOnly
```

Experimental 60s segmented command:

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_segmented_end_to_end.ps1 `
  -JobName <job_name> `
  -VideoPath .\素材资产\原视频\光伏60s.mp4 `
  -SegmentSeconds 30 `
  -CancelUnavail
```

## Machine Selection

Required defaults:

- exclude `CN` and `TR`
- `MaxDphTotal=0.215`
- `MinDriverMajor=580`
- `DiskGb=240`
- run HuggingFace speed preflight before bootstrap
- default HF gate:
  - minimum speed: `15 MiB/s`
  - maximum estimated model download time: `30 min`
  - sample size: `256 MiB`
- only enable `WarmStart` when the selector chooses a known successful machine

Blacklisted:

- `machine_id=47075`
- `host_id=74292`

Reason: repeated KJ 30s paid failures, no useful warm cache, and higher effective price.

## HuggingFace Download Gate

The KJ 30s branch downloads 11 configured HuggingFace model files on a cold machine:

- total size: `34.95 GB` / `32.55 GiB`
- main diffusion model: `16.13 GiB`
- text encoder: `6.27 GiB`
- CLIP vision + VAE + detection models: about `2.62 GiB`
- LoRA files: about `7.54 GiB`

Before `bootstrap`, `remote_submit_wan22_kj_30s.sh` now:

1. checks which configured model files already exist under `/workspace/ComfyUI/models`
2. measures real download speed from HuggingFace with a ranged sample of the main model
3. estimates remaining model download time from `remaining_model_bytes / measured_speed`
4. writes `/workspace/wan22-kj-30s-run/hf_speedtest.json`
5. exits before model download if the host is too slow

Important log lines:

```text
[hf-speedtest] decision=pass speed=<x> MiB/s estimated_model_download=<y> min
[hf-speedtest] decision=reject ...
```

If rejected, the local download step detects the log line and fails quickly, so `-DestroyInstance` can stop billing.

For RTX 4090 comparison runs, do not test every visible offer. Use the candidate selector:

```powershell
pwsh -File .\scripts\select_wan22_kj_30s_offer_by_hf_speed.ps1 `
  -CandidateCount 20 `
  -BatchSize 3 `
  -MaxTests 9
```

Selection rule:

- list `10-20` candidate offers first
- filter out `CN/TR`, blacklisted hosts, low driver versions, and high price
- short-rent only `1-3` best-looking offers per batch
- if an instance does not print `[hf-speedtest]` within `5 min`, treat it as startup too slow and destroy it
- if none pass the HF gate, destroy them and continue with the next candidate batch
- rank passing machines by estimated HF download cost, then hourly price, then speed

Rough cold-download estimates for this branch:

| HF speed | Estimated model download |
|---:|---:|
| `10 MiB/s` | `55.6 min` |
| `15 MiB/s` | `37.0 min` |
| `20 MiB/s` | `27.8 min` |
| `30 MiB/s` | `18.5 min` |
| `50 MiB/s` | `11.1 min` |

## Critical Runtime Patches

The KJ workflow must be converted before running on Vast.

Required runtime changes:

- remove node `137` (`WanVideoTorchCompileSettings`)
- remove `WanVideoModelLoader.inputs.compile_args`
- set node `140`:
  - `base_precision="fp16"`
  - `attention_mode="sdpa"`
- keep only output node `156` with `save_output=true`
- remove helper/preview nodes: `143,148,157,158,159,165,166,170,174,180,183`
- patch `WanVideoSampler` node `168` explicitly:
  - `steps=6`
  - `cfg=1`
  - `shift=3`
  - `force_offload=true`
  - `scheduler="dpm++_sde"`
  - `batched_cfg=false`
  - `rope_function="comfy"`

Do not restore torch compile for RTX 3090. It caused fp8/TorchInductor errors.

## Cost Profile

Validated cold start on `machine_id=54625`:

- total until local download: `8493s`
- prompt execution from ComfyUI history: `5215.264s`
- approximate paid instance time: about `2h21m`
- approximate instance cost at `$0.20/h`: `$0.47`

Validated RTX 4090 cold start on `machine_id=50910`:

- total until local download: `2995s`
- prompt execution from ComfyUI history: `00:36:13`
- actual model download stage: `474s`
- approximate paid instance time: about `50 min`
- approximate instance cost at `$0.3155555555555556/h`: `$0.263`

The 4090 run was faster than the 3090 baseline mainly in both model download and prompt execution, but it is still a high-cost quality candidate rather than a cost-optimized production path.
