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

## KJ 2.0 同图锚定版

Friendly name: `KJ 2.0 同图锚定版`.

Internal trace name: `B1.1 same-frame anchor`.

For fixed-scene long videos, this is the current accepted 2.0 path.

This is a pragmatic validated path: keep the original KJ workflow structure, do not connect `bg_images` or `mask`, and reuse the same complete person+background anchor image as `ip_image.png` for every `30s` segment. It is not the final "pure IP plus separate generated background" semantics, but it preserves mouth/body motion and keeps the background stable.

Rules:

- Use one accepted complete anchor frame containing the same person and photovoltaic background, currently `output/wan22_kj_30s_segmented/_b2_anchors/bg_anchor_10s.png`.
- Stage that anchor as `ip_image.png` for every segment.
- Do not add or connect `WanVideoAnimateEmbeds.bg_images`.
- Do not add or connect `WanVideoAnimateEmbeds.mask`.
- Runtime node `171` (`WanVideoAnimateEmbeds`) stays on the original KJ inputs for image, pose, face, and audio/video conditioning.
- All `30s` segments reuse the same `ip_image.png`, prompt, negative prompt, and seed.

Validation result:

- short smoke: `kj60-b11-sameframe-5x2-20260501`
  - result: motion restored
  - metrics: `body mean 9.746`, `mouth mean 15.975`, `background mean 0.548`
- full 60s test: `kj60-b11-sameframe-30x2-20260501`
  - instance kept alive after validation: `35889784`
  - machine: `31054`
  - host: `93447`
  - GPU/location: `RTX 4090`, `Sweden, SE`
  - output: `59.648s`, `720x720`, `16fps`, with audio
  - prompt execution: segment 1 `2320.327s`, segment 2 `2992.393s`
  - metrics: `body mean 8.254`, `mouth mean 10.239`, `background mean 0.366`
  - visual acceptance: `pass` after keyframes, `26-30s`, `28-33s` seam, `48-52s`, and generated-artifact review
  - local result: `output/wan22_kj_30s_segmented/kj60-b11-sameframe-30x2-20260501/downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501.mp4`

Segmented example:

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_segmented_end_to_end.ps1 `
  -JobName <job_name> `
  -ImagePath .\output\wan22_kj_30s_segmented\_b2_anchors\bg_anchor_10s.png `
  -VideoPath .\素材资产\原视频\光伏60s.mp4 `
  -SegmentSeconds 30 `
  -MaxSegments 2
```

## KJ 2.0 背景/Mask失败版

Friendly name: `KJ 2.0 背景/Mask失败版`.

Internal trace name: `B2 bg_images/mask`.

B2 tried to keep the pure seated IP image as `ip_image.png`, load a separate `bg_image.png`, repeat it to `frame_load_cap`, and connect `bg_images` plus an IP-alpha-derived mask into `WanVideoAnimateEmbeds`.

Do not use this structure for the current KJ 2.0 branch.

Observed failure:

- job: `kj60-b2-bgmask-20260501-0100`
- initial quick review saw stable composition, but detailed review showed the mouth and body barely moved
- metrics: `body mean 1.2`, `mouth mean 0.705`, far below B1/A/B1.1
- root cause: `bg_images` + `mask` over-constrained node `171`; the `bg_image.png` also contained the complete person, so the model effectively locked to a static person/background reference
- action: revert to `KJ 2.0 同图锚定版` unless B2 is redesigned and first passes a short motion metric check

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

## Generated Video Polish

Use `scripts/polish_generated_artifacts.py` only after a merged KJ output exists locally.

This is the local "one-pass polish" path for isolated red dots, red pins, sticker specks, or small color artifacts in the final generated video. It is not pure FFmpeg: FFmpeg extracts frames, encodes the repaired frames, and preserves/copies audio; Python/OpenCV detects the red component mask and performs local `cv2.inpaint`.

Default command:

```powershell
D:\code\YuYan\python\python.exe .\scripts\polish_generated_artifacts.py `
  --video <merged_input.mp4> `
  --output-video <merged_input>-polished-auto.mp4 `
  --output-dir <job_dir>\frame_review\polished_auto `
  --ffmpeg D:\code\KuangJia\ffmpeg\ffmpeg.exe `
  --ffprobe D:\code\KuangJia\ffmpeg\ffprobe.exe
```

Rules:

- The script runs detection, targeted repair, audio/video re-encode, after-scan, JSON/Markdown report, and before/after contact sheet.
- v5 default mode repairs `red/yellow/green/magenta` candidates from the detection report and skips persistent color elements, face/lip area, bottom footwear area, and skin-like color regions to avoid changing hands or lips.
- `cyan` and `blue` are supported through `--repair-labels`, but they are not default in the photovoltaic scene because sky and solar panels create too much blue/cyan false-positive risk.
- v5 adds a local silver/white residual mask around confirmed color targets. This can reduce shiny edges, thin strings, and highlights left after the main color is removed.
- Default mode adds `--target-frame-padding 2`, which expands each detected target by two frames on both sides. This handles sub-second red dots that do not last a full second without expanding the whole repair window.
- `--repair-all-window-red` is experimental and must not be used as the default because it can over-repair hands, lips, shoes, and clothing.
- The after-scan score is only a candidate signal. It can still flag lips, hands, shoes, panel lines, and normal motion, so final acceptance requires looking at the before/after sheet and the problem window.
- If the problem is hand/body/face structure, multi-hand, double head, or chair/contact geometry, do not polish the final MP4. Clean the matching reference window or rerun that 30s segment.

Validated local tests on `kj60-b11-sameframe-30x2-20260501`:

- Full 60s polish v3: `279.4s`, output `downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v3.mp4`.
- v3 fixed `29.500s-29.688s`, but missed one edge frame around `29.750s`.
- Full 60s polish v4: `275.5s`, output `downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v4.mp4`.
- v4 result video: `59.625s`, `720x720`, `16fps`, AAC audio `59.603696s`.
- v4 repair scope: `5` touched frames, `5` repaired red components, `911` skipped components.
- Target review: `frame_review/polished_auto_v4/target_28p5_30p0_before_after.jpg` shows the red hanging ball near `29.500s-29.750s` removed while the hand-control frames at `28.562s` and `29.812s` are preserved.
- Full 60s polish v5: `424.8s`, output `downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v5.mp4`.
- v5 result video: `59.625s`, `720x720`, `16fps`, AAC audio `59.603696s`.
- v5 repair scope on this sample: `5` touched frames, `5` repaired color components, `911` skipped components. It remained conservative because non-red candidates were either persistent background/panel details or too close to skin/person regions.
- v5 target review: `frame_review/polished_auto_v5/target_28p5_30p0_before_after.jpg`.
- User acceptance: current v5 output is acceptable for now. Treat `downloads/wan22_kj_30s_segmented-kj60-b11-sameframe-30x2-20260501-polished-auto-v5.mp4` as the recommended polished output for this run.
- Default acceptance flow for similar KJ 2.0 same-frame anchor jobs: generate raw merged video, run v5 local polish, inspect before/after and key windows manually, then publish/archive the polished file.
- Do not set a large halo such as `--halo-padding 48` as the default. Local testing showed it removes more string/highlight residue but creates obvious blue-gray smearing on the leg edge and photovoltaic background.

Cleanup roadmap:

- `2.0`: current path. Use rule-based overlay detection, small targeted local cleaning, and rerun only the affected 30s segment. Do not add new ComfyUI cleaning plugins to the production KJ workflow yet.
- `KJ 2.0 同图锚定版` (`B1.1 same-frame anchor`): current fixed-scene accepted validation path. Use one complete anchor image as `ip_image.png` for all segments and do not connect `bg_images` / `mask`.
- `KJ 2.0 背景/Mask失败版` (`B2 bg_images/mask`): failed background/mask experiment. It suppressed mouth/body motion and must not be used as the default path.
- `2.1`: local rule-based preprocessor exists, but the 2026-05-01 `光伏60s.mp4` conservative_v9 validation failed. It can generate `cleanup_plan`, `cleaned_reference.mp4`, `cleaning-report.json`, and before/after sheets, but it must not be treated as a passed cleaner when near-body text/labels remain or turn into gray blocks. If risk-after is still high or the before/after sheet shows residual UI, stop before stage/inference.
- `2.1-next`: local samples also failed after OCR glyph masks + OpenCV Telea/NS variants and `simple-lama-inpainting` single-frame probes. OCR can detect the text, and LaMa can remove some text, but when subtitles or location bubbles touch the body, hands, legs, or clothing, the repaired frame gets text remnants, white/orange/gray blocks, photovoltaic-panel hallucination, or semi-transparent body/clothing distortion. Do not run full cleaned-reference generation or Vast inference from this source unless a new sample sheet is visibly clean and preserves face/hands/body.
- Next step after `2.1-next`: request a no-subtitle/no-sticker reference video, do manual/professional cleanup for the obstructed windows, or evaluate stronger semantic/video object-removal tools such as ProPainter / E2FGVI / commercial object removal on 1s windows before any full-video pass.
- `2.2`: evaluate lighter local repair such as LaMa / MAT, Crop & Stitch, SAM / GroundingDINO / OCR masks, or color-token cleanup for red pins, checkmarks, and small sticker residue.
- Roadmap details live in `docs/KJ参考视频清理方案TODO.md`.

## Runtime Rules

Before any paid run, also read:

- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`

## KJ 1.2 环境镜像模板实验

Friendly name: `KJ 2.0 环境镜像模板版`.

Runtime strategy: `1.2-docker-env-template`.

Scope:

- only for `wan22_kj_30s` and `wan22_kj_30s_segmented`
- not for the old `wan_2_2_animate` production branch
- not a Vast volume strategy
- not a model-cache guarantee

Artifacts:

- Dockerfile: `docker/wan22-kj-comfy-env/Dockerfile`
- build workflow: `.github/workflows/build-wan22-kj-env-image.yml`
- image: `ghcr.io/myjr2015/codex-wan22-kj-comfy:cuda129-py312-kj-v2`
- default registry: GHCR. DockerHub remains optional, but the default path should not assume a DockerHub username exists.
- GHCR may remain private after Actions push. In that case, pass `-PrivateRegistryLogin -RegistryHost ghcr.io -RegistryUsername myjr2015` at instance launch; the token is read from local GitHub credentials and must not be printed.
- Vast template helper: `scripts/create_vast_wan22_kj_env_template.ps1`
- template hash env: `VAST_WAN22_KJ_TEMPLATE_HASH`
- current v2 template hash: `3f38ca38792bcefce25bb1688f4ca2ca` (`template_id=400059`)
- details: `docs/KJ环境镜像和Vast模板.md`
- v2 startup optimization:
  - `KJ_MODEL_DOWNLOAD_PARALLELISM` controls cold model download concurrency; default `3`, capped at `4`.
  - model downloads write `*.part.<pid>` first, use curl resume, and move into place only after curl succeeds; any failed model fails the whole bootstrap.
  - torch compatibility is judged by torch CUDA runtime and GPU availability first; missing `torchvision` / `torchaudio` are best-effort auxiliary no-deps installs from the current torch CUDA index. If the matching auxiliary wheel does not exist, bootstrap warns and continues instead of forcing a full torch stack reinstall.
  - the Docker env image records torch, torchvision, and torchaudio versions in `/opt/codex/kj-env-image.json`.

Expected benefit:

- reduce custom node clone and requirements install time
- reduce dependency drift
- keep HF speed gate, model download checks, R2 stage, ComfyUI `/history` download, and local merge/polish unchanged

Non-goals:

- does not include Wan/KJ model weights
- does not reduce KJ inference time
- does not remove the need for HF speed testing
- does not use paid Vast volume

Run examples:

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_end_to_end.ps1 `
  -JobName <job_name> `
  -RuntimeVersion 1.2-docker-env-template `
  -VastTemplateHash <template_hash_id>
```

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_segmented_end_to_end.ps1 `
  -JobName <job_name> `
  -RuntimeVersion 1.2-docker-env-template `
  -VastTemplateHash <template_hash_id>
```

Validation signal:

- bootstrap should print `preinstalled KJ custom nodes are ready`
- HF speedtest should still run
- model phase should still report existing/missing model files
- do not call it faster until a paid smoke run compares bootstrap timing against base image
- for template speed smoke, use `launch_wan22_kj_30s_vast_job.ps1 -RemoteStopAfter validate_nodes -PrivateRegistryLogin -RegistryHost ghcr.io -RegistryUsername myjr2015` after staging; this stops before `/prompt` submission and avoids a full paid inference.

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

Reference-overlay gate:

- The segmented runner runs `scripts/analyze_reference_overlay_risk.py` before staging/renting unless `-ReferenceRiskPolicy Off` is set.
- Default policy is `Warn`, which writes `output/reference_risk_preflight/<job_name>/overlay-risk-report.json` and continues.
- For 2.1/2.2 cleaning validation, use `-ReferenceRiskPolicy FailOnHigh`; high-risk overlay windows must stop the job before Vast selection, upload, or inference.
- Current gate smoke test: `_test-risk-gate-20260501` correctly blocked `素材资产/原视频/光伏60s.mp4` with 1 high-risk window and max score `11.374`.

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
- failed B2 background anchor patch for segmented jobs; do not enable for `KJ 2.0 同图锚定版`:
  - add `LoadImage` node `901` for `bg_image.png`
  - add `RepeatImageBatch` node `902` with `amount=frame_load_cap`
  - add `LoadImageMask` node `903` reading `ip_image.png` alpha
  - add `InvertMask` node `904`
  - add `GrowMask` node `905`, default `expand=12`
  - connect node `171.inputs.bg_images=[902,0]`
  - connect node `171.inputs.mask=[905,0]`

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
