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

## RTX 3090 Vast Selection

User cost preference from 2026-05-01:

- For KJ / Wan2.2 paid work on `RTX 3090 24GB`, default acceptable price is total `dph_total < $0.20/h`.
- Always judge price after applying the actual `--storage` value, because Vast total hourly cost is GPU plus disk/storage fees and may differ from the bare GPU listing.
- HF-only speed tests may use smaller storage to reach the speedtest stage quickly; real KJ cold-start or inference runs must recalculate with the disk size required by image plus models.
- Full KJ 30s / segmented workflow selection uses `DiskGb=240` and `--storage 240` by default. Do not use 40GB/80GB HF-only speedtest prices as the final production cost.
- Do not pick 3090 offers at or above `$0.20/h` unless the user explicitly asks or there is no usable machine below the threshold.
- Keep excluding `CN` and `TR`.
- Prefer drivers `580.*` or `590.*`; driver `570.*` and lower must be called out as CUDA / torch compatibility risk before spending money.

Current 3090 speed-test candidates requested by the user:

- `35423246`: California, `machine_id=54625`, `host_id=344939`, listed about `$0.1347/h`; with 180GB storage observed about `$0.1833/h`, still below `$0.20/h`.
- `35135923`: California, `machine_id=68407`, `host_id=344939`, listed about `$0.1356/h`; actual total must be checked with storage.
- `32302041`: California, `machine_id=42748`, `host_id=299337`, about `$0.1228/h`, driver `570.158.01`; inside preferred price band but driver is a CUDA / torch compatibility risk until proven reliable.

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
- image: `j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3`
- default registry: DockerHub. GHCR v3 exists from Actions but current local GitHub token lacks `read:packages`, so GHCR manifest checks return 401 and Vast can sit in pre-container pull. Do not use GHCR as the default until package visibility or token scope is fixed.
- When launching the DockerHub v3 image, pass `-PrivateRegistryLogin -RegistryHost docker.io -RegistryUsername j1c2k3`; the token is read from local DockerHub credentials and must not be printed.
- Vast template helper: `scripts/create_vast_wan22_kj_env_template.ps1`
- template hash env: `VAST_WAN22_KJ_TEMPLATE_HASH`
- failed v2 template hash: `3f38ca38792bcefce25bb1688f4ca2ca` (`template_id=400059`)
- details: `docs/KJ环境镜像和Vast模板.md`
- v2/v3 startup optimization:
  - `KJ_MODEL_DOWNLOAD_PARALLELISM` controls cold model download concurrency; default `3`, capped at `4`.
  - model downloads write `*.part.<pid>` first, use curl resume, and move into place only after curl succeeds; any failed model fails the whole bootstrap.
  - torch compatibility is judged by torch CUDA runtime and GPU availability first; missing `torchvision` / `torchaudio` are best-effort auxiliary no-deps installs from the current torch CUDA index. If the matching auxiliary wheel does not exist, bootstrap warns and continues instead of forcing a full torch stack reinstall.
  - the Docker env image records torch, torchvision, and torchaudio versions in `/opt/codex/kj-env-image.json`.
  - v3 installs `onnxruntime-gpu[cuda,cudnn]`, exposes Python NVIDIA CUDA12 libraries through `LD_LIBRARY_PATH` / `ldconfig`, and verifies ONNXRuntime `CUDAExecutionProvider` plus a tiny ONNX GPU session.

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
- for v3, do not accept `validate_nodes` alone; the required pass signal is `[onnx-cuda-smoke] tiny inference ok` or `onnxruntime CUDA validation passed`
- if ONNXRuntime CUDA validation fails, destroy the instance and fix the image before any full inference
- for template speed smoke, use `launch_wan22_kj_30s_vast_job.ps1 -RemoteStopAfter validate_nodes -PrivateRegistryLogin -RegistryHost docker.io -RegistryUsername j1c2k3` after staging; this stops before `/prompt` submission and avoids a full paid inference.

Current smoke-test stop points:

- `RemoteStopAfter=onnx_cuda`: fastest image/ONNX sanity check. It stops before model downloads and before `/prompt`.
- `RemoteStopAfter=validate_nodes`: validates ComfyUI API and node availability, but current bootstrap intentionally skips model downloads for this stop point. Treat it as environment-only smoke, not full cold-start timing.
- `RemoteStopAfter=bootstrap`: preferred no-inference cold-start timing test. It includes HF speed gate, v3 image startup, dependency/ONNX checks, and configured model downloads or model cache checks, then stops before ComfyUI restart and before `/prompt`.
- If the operator asks whether the image method improves "time before inference", report Docker/container startup, HF speedtest estimate, dependency/ONNX time, and real model download/cache-check time separately. Do not merge a skipped-model `validate_nodes` smoke with a full cold-start comparison.

Fast ONNX CUDA smoke:

```powershell
pwsh -File .\scripts\launch_wan22_kj_30s_vast_job.ps1 `
  -JobName <job_name> `
  -OfferId <offer_id> `
  -TemplateHash <template_hash_id> `
  -PrivateRegistryLogin `
  -RegistryHost docker.io `
  -RegistryUsername j1c2k3 `
  -RemoteStopAfter onnx_cuda
```

This stops before model downloads and before `/prompt`.

Latest v2 smoke:

- job: `kj30s-template-v2-smoke-fix-20260501-164926`
- instance: `35950726`
- machine / host: `17049 / 96607`
- GPU / location: `RTX 4090`, `California, US`
- template: `3f38ca38792bcefce25bb1688f4ca2ca`
- HF speed gate: `100.29 MiB/s`, estimated `5.5 min` for remaining `32.55 GiB`
- result: `validate_nodes` passed and stopped before `/prompt`
- observed behavior:
  - preinstalled KJ custom nodes were reused
  - torch stack was reused; no full torch reinstall
  - model downloads ran with `KJ_MODEL_DOWNLOAD_PARALLELISM=3`
  - large curl downloads had transient reset/broken-pipe messages but retries/resume completed
- cleanup: final `vastai show instances --raw` returned `[]`; destroy helper returned 404 for `35950726` because it was already absent by the cleanup call.
- earlier failed smoke note: first v2 smoke found that `torch=2.11.0+cu130` could get stuck when auxiliary `torchaudio` was looked up on fixed cu124 index. Fixed in `V6.5.17` by deriving the auxiliary PyTorch wheel index from current `torch.version.cuda` and treating auxiliary install as best-effort when torch core is already compatible.
- v2 failure update: a later KJ run showed `libonnxruntime_providers_cuda.so` could not load because `libcublasLt.so.12` was missing; `Detecting bboxes` and `Extracting keypoints` fell back to CPU. Do not use v2 for further paid KJ tests.

Latest v3 smoke:

- job: `kj30s-v3-dhub-4090-onnxfix-20260502-0020`
- instance: `35969529` (destroyed after smoke)
- machine / host: `17049 / 96607`
- GPU / location: `RTX 4090`, `California, US`
- image: `j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3`
- template created for future use: `eb3ff9185d9de9a9482c2cffbdfd8f9f` (`template_id=400607`)
- HF speed gate: `67.41 MiB/s`, estimated `8.2 min` for remaining `32.55 GiB`
- result: `RemoteStopAfter=onnx_cuda` passed and stopped before model download and `/prompt`
- observed behavior:
  - DockerHub v3 pulled and started; GHCR v3 had previously stayed in pre-container pull with local token returning GHCR manifest `401`
  - preinstalled KJ custom nodes were reused
  - torch stack was reused; only missing `torchaudio==2.11.0+cu130` was installed without reinstalling torch
  - ONNXRuntime `CUDAExecutionProvider` loaded `libcublasLt.so.12`, `libcublas.so.12`, `libcudart.so.12`, and `libcudnn.so.9`
  - tiny ONNX Identity session ran on `CUDAExecutionProvider`
  - local bug fixed before the passing smoke: both staged ONNX smoke Python blocks now set `output_path = sys.argv[1]`

KJ v3 pending fixes / skill memory:

- `download_wan22_kj_30s_segmented_result.ps1` must keep a deterministic fallback for segmented jobs: if ComfyUI restarts and early segment `/history` is gone, verify the predicted `output_prefix_00001-audio.mp4` through `/view` after logs show `remote.segment_XX end`.
- `summarize_vast_job_timing.ps1 -FetchLog` must force UTF-8 around `vastai logs`; Windows GBK can fail when remote logs contain non-GBK characters and should not block timing reports.
- HF 256MiB speedtest can be optimistic. Record the speedtest value and the actual large-file model download stage separately whenever `RemoteStopAfter=bootstrap` or a real run downloads models.
- The v3 Docker image is not a model cache. It can save custom-node clone and Python dependency drift, but model downloads still dominate on a fresh host unless the machine already has the files.
- GHCR is not the default until package visibility/token scope is fixed. Use DockerHub v3 with private registry login and never print the token.

No-inference bootstrap comparison from 2026-05-02:

- Test target: `RemoteStopAfter=bootstrap`, DockerHub v3 image, Vast template `eb3ff9185d9de9a9482c2cffbdfd8f9f`, no `/prompt` submission and no inference.
- Successful RTX 4090 Estonia sample `kj-v3boot-r1-4090-20260502-0815`:
  - HF speedtest `98.14 MiB/s`, estimated model download `5.7 min`
  - Python dependency / ONNX phase about `41s`
  - real model download stage `319s`
  - remote bootstrap `360s`, onstart lifecycle `368s`
- Successful RTX 4090 Hungary sample `kj-v3boot-backup-4090-hu-20260502-0834`:
  - HF speedtest `62.80 MiB/s`, estimated model download `8.8 min`
  - Python dependency / ONNX phase about `40s`
  - real model download stage `235s`
  - remote bootstrap `275s`, onstart lifecycle `287s`
- Successful RTX 3090 Bulgaria sample `kj-v3boot-r2b-3090-20260502-0822`:
  - HF speedtest `123.45 MiB/s`, estimated model download `4.5 min`
  - Python dependency / ONNX phase about `37s`
  - real model download stage `153s`
  - remote bootstrap `190s`, onstart lifecycle `197s`
- Operational result:
  - v3 image does reduce the dependency/custom-node part once the container starts; successful runs reused preinstalled custom nodes and avoided full torch reinstall.
  - v3 image does not guarantee faster total pre-inference time because Docker/container startup varies heavily by host.
  - Many sampled hosts never reached useful onstart logs: examples included `No such container: C.<id>`, `docker login failed`, create-instance label lookup failure, and a Chile host with DNS failure resolving Ubuntu mirrors.
  - Treat "image pull/container startup success rate" as a first-class metric. If no onstart/HF speedtest appears within about `5 min`, destroy and move hosts.
  - Do not select based only on GPU class. In this comparison, one 3090 with excellent HF throughput beat several 4090s on pre-inference cold start, while several 3090s failed before onstart.

Same-machine v3 vs base environment-only comparison from 2026-05-02:

- Test target: `RemoteStopAfter=validate_nodes`, same physical machine, no `/prompt`, no inference, and model downloads intentionally skipped by the stop point.
- Machine: `RTX 4090`, Michigan US, `machine_id=56169`, `host_id=65203`, offer `31931540`, `dph_total=$0.3067/h`, driver `590.48.01`, `DiskGb=240`.
- Network control: all completed samples measured almost identical HF speed, about `103 MiB/s`, so the comparison mainly reflects image/container and dependency preparation, not HF variance.
- Base sample `kj-ab-base-r1-20260502-1013`:
  - instance `35991178`
  - image `vastai/comfy:v0.19.3-cuda-12.9-py312`
  - result: destroyed as an invalid sample after it reached `running` but stalled after the first R2 onstart fetch and never reached `[hf-speedtest]` or `[bootstrap]`
  - lesson: base image cold container/onstart path can fail before useful workflow evidence; do not keep it alive indefinitely
- v3 sample `kj-ab-v3-r1-20260502-1024`:
  - instance `35991581`
  - image `j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3`
  - HF speed `103.27 MiB/s`
  - onstart lifecycle `40s`
  - `bootstrap.custom_nodes=0s`, because preinstalled KJ custom nodes were seeded from `/opt/codex/kj-custom_nodes`
  - `bootstrap.python_dependencies=23s`, torch stack reused as `torch=2.11.0+cu130`, only auxiliary packages were checked/filled
  - `remote.bootstrap=23s`, `remote.wait_api=11s`, `validate_nodes` passed
- Base sample `kj-ab-base-r2-20260502-1034`:
  - instance `35991826`
  - image `vastai/comfy:v0.19.3-cuda-12.9-py312`
  - HF speed `103.33 MiB/s`
  - onstart lifecycle `228s`
  - `bootstrap.custom_nodes=20s`
  - `bootstrap.python_dependencies=190s`, including full torch/cu124 reinstall and ComfyUI/custom-node requirements
  - `remote.bootstrap=210s`, `remote.wait_api=10s`, `validate_nodes` passed
- v3 sample `kj-ab-v3-r2-20260502-1041`:
  - instance `35992151`
  - image `j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3`
  - HF speed `103.56 MiB/s`
  - onstart lifecycle `46s`
  - `bootstrap.custom_nodes=0s`
  - `bootstrap.python_dependencies=23s`
  - `remote.bootstrap=23s`, `remote.wait_api=10s`, `validate_nodes` passed
- Conclusion:
  - Do not use the second same-machine v3 run as proof that v3 is faster. Any image can look fast after its layers are cached.
  - The fair useful signal from this run is narrower: v3 reduces the environment phase after onstart. Successful base bootstrap was `210s`, while v3 bootstrap was `23s`.
  - First-use total time must still include DockerHub v3 image pull. In this sample, the first successful v3 run reached onstart about `3m32s` after instance start, then needed `40s` onstart lifecycle; the successful base run reached onstart about `49s` after instance start, then needed `228s` onstart lifecycle.
  - So the first-use total to `validate_nodes` was only slightly better for v3 on this machine, about `4m12s` versus base about `4m37s`; this is not a large enough margin to claim v3 always wins.
  - v3's defensible value is dependency determinism and less post-onstart installation work: it avoids custom-node extraction and avoids a full torch reinstall; it also makes ONNX/CUDA availability deterministic.
  - v3 does not include model weights, so it does not reduce the 32.55 GiB HF model cold download.
  - For "does v3 improve time before inference" reports, separate these lines: Docker/container startup, HF speedtest, dependency/ONNX, model download/cache check, and inference. Do not merge them into one vague cold-start number, and do not count cached second runs as cold-start evidence.

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
