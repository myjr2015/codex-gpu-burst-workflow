---
name: badskills
description: Use when the Wan2.2 talking-photo pipeline is failing on fresh Vast machines, when cold start keeps burning time or money, or when you need the known symptom-to-root-cause map before attempting another retry.
---

# badskills

## Overview

This skill records the failure path only.

Use it before retrying a broken cold start, so the next action is based on evidence instead of another blind rebuild.

Current production memory only supports the proven `1.0-cold` and `1.1-machine-registry` paths.
Do not reintroduce abandoned Docker / cache-image experiments into this Wan2.2 skill.

## Fixed Scope

These failures were observed on the same branch:
- source image directory: `素材资产/美女图带光伏/`
- staged ComfyUI image name: `美女带背景.png`
- video: `光伏2.mp4`
- workflow: `workflows/Animate+Wan2.2换风格对口型.json`
- runtime chain:
  - `scripts/prepare_wan22_root_canvas_prompt.mjs`
  - `scripts/bootstrap_wan22_root_canvas.sh`
  - `scripts/remote_submit_wan22_root_canvas.sh`

## Failure Ledger

- Symptom: instance says `running`, but API is dead or returns `502`
  - Root cause: Vast env injection was malformed, so expected variables were not really injected
  - Action: inspect `vastai show instance --raw`, especially `extra_env`; if dirty, recreate instead of debugging inside the machine

- Symptom: cold start spends forever reinstalling giant packages and then drifts into new import crashes
  - Root cause: old plugin requirements reintroduced heavy stacks like `accelerate`, `diffusers`, `peft`, `spandrel`
  - Action: keep filtered requirements logic in `bootstrap_wan22_root_canvas.sh`; do not restore removed heavy explicit installs

- Symptom: cold start appears "stuck", but logs only show pip and curl progress for a long time
  - Root cause: the machine is still doing legitimate bootstrap work:
    - torch / cu124 wheels from `download.pytorch.org`
    - multi-GB models from Hugging Face
  - Action: do not misclassify this as a crash unless progress stops completely for an abnormal amount of time; read the latest log phase before killing the run

- Symptom: torch install dies with `ReadTimeoutError`
  - Root cause: large wheel download from PyTorch mirror timed out mid-transfer
  - Action: use long pip timeout and retry settings; if mirror instability persists, restart from staged assets, not from an ad hoc machine state

- Symptom: Vast shows `loading`, logs say `No such container`
  - Root cause: image pull is still in progress and container does not exist yet
  - Action: wait until `actual_status=running`; do not misclassify as workflow failure too early

- Symptom: instance never becomes usable and status mentions host port bind failure
  - Root cause: host-level port conflict, often on `8188`
  - Action: destroy immediately and move hosts; this is not a workflow bug

- Symptom: the cheapest host looks attractive on paper, but cold start is slow or unstable because external registries and model sources are hard to reach
  - Root cause: host geolocation is mainland China or Turkey, while this branch depends on unattended pulls from Docker Hub, PyTorch, Hugging Face, and R2
  - Action: for `wan_2_2_animate`, exclude `CN` when searching Vast offers unless the user explicitly re-allows it; treat `TR` by actual speed and bootstrap logs

- Symptom: ComfyUI exits with `cudaGetDeviceCount Error 804`
  - Root cause: either the host driver and container CUDA stack are incompatible, or the container's CUDA compat library is shadowing the real host `libcuda.so`
  - Evidence seen on a failed host: `570.211.01`
  - Evidence seen on a rescued LTX2.3 host: `570.195.03` worked after putting `/usr/lib/x86_64-linux-gnu` before `/usr/local/cuda-12.9/compat` in `LD_LIBRARY_PATH`
  - Action: record `driver_version` for diagnostics; on LTX2.3 first restart ComfyUI with host driver libs preferred in `LD_LIBRARY_PATH`; destroy only if CUDA 804 persists after that. On old Wan/KJ paths without this known compat-shadow signal, stop and destroy.

- Symptom: LTX2.3 custom-node requirements fail with `THESE PACKAGES DO NOT MATCH THE HASHES` while installing `opencv-python`, `opencv-python-headless`, or `imageio-ffmpeg`
  - Root cause: a stale or partial pip cache on the rented instance can serve a corrupted wheel
  - Evidence from `ltx23-v3-10s-vlbg-nocn-us-20260506-01`: `ComfyUI-VideoHelperSuite` install failed on `opencv_python`; purging pip cache and retrying `pip install --no-cache-dir opencv-python imageio-ffmpeg` rescued the same instance
  - Action: purge pip cache and retry with `--no-cache-dir` before destroying; keep this retry in `scripts/bootstrap_ltx23_talking_head.sh`

- Symptom: LTX2.3 bootstrap succeeds but ComfyUI exits with `comfyui-frontend-package is not installed`
  - Root cause: the LTX bootstrap filtered `comfyui-frontend-package` as optional even though current ComfyUI expects the frontend package at startup
  - Action: do not filter `comfyui-frontend-package` from core ComfyUI requirements; install `comfyui-frontend-package==1.42.11` for the current LTX2.3 base

- Symptom: ComfyUI gets deeper into startup, then crashes with `ModuleNotFoundError: torchsde`
  - Root cause: bootstrap missed a core Comfy sampler dependency
  - Action: install `torchsde` in bootstrap, then re-stage before rerun

- Symptom: after fixing one missing module, the next startup dies on another base module like `aiohttp`
  - Root cause: bootstrap installed custom-node extras only, but not filtered ComfyUI core requirements
  - Action: install filtered `$COMFY_APP_ROOT/requirements.txt` during bootstrap

- Symptom: bootstrap log says heavy requirements are skipped, but later the same run still installs `accelerate`, `diffusers`, or `peft`
  - Root cause: a second explicit install block reintroduced them
  - Action: remove those explicit package installs; otherwise cold start cost and failure surface both increase

- Symptom: prompt submission fails with `Invalid video file: 光伏2.mp4` or `Invalid image file: 美女带背景.png`
  - Root cause: `workflow_runtime.json` used Chinese names, but generated onstart script still downloaded files as `source.mp4` and `speaker.png`
  - Action: keep filenames consistent end to end

- Symptom: the current `wan_2_2_animate` result uses a pure-color speaker asset or an old `美女图.png`
  - Root cause: source image selection drifted back to an old branch that is not the proven Wan2.2 fixed flow
  - Action: only select source images from `素材资产/美女图带光伏/`; stage may still rename the selected file to `美女带背景.png` for ComfyUI

- Symptom: ComfyUI starts, then unused custom nodes die on import errors and pollute the logs
  - Root cause: staged bundle set included unused extras such as:
    - `ComfyUI-Easy-Use`
    - `ComfyUI-WanVideoWrapper`
    - `ComfyUI-segment-anything-2`
  - Action: keep only the four validated bundles in this branch

- Symptom: bootstrap reaches `[bootstrap] done`, but ComfyUI immediately exits with `ModuleNotFoundError: transformers`
  - Root cause: filtered core requirements no longer brought `transformers` back, but ComfyUI still imports it early
  - Action: explicitly install `transformers>=4.50.3`

- Symptom: local scripts were fixed, but remote machine still used stale files
  - Root cause: job package was not re-staged and re-uploaded after script edits
  - Action: always rerun `stage_wan_2_2_animate_job.ps1` after any change to bootstrap, runtime JSON generation, or onstart generation

- Symptom: `onstart_wan_2_2_animate.sh` dies during long R2 pulls with `curl: (35) Recv failure: Connection reset by peer`
  - Root cause: earlier fetch logic was too fragile for big staged downloads
  - Action: keep hardened curl flags in `generate_wan_2_2_animate_onstart.mjs`:
    - `--http1.1`
    - `--retry 10`
    - `--retry-all-errors`
    - `--connect-timeout 30`
    - `--max-time 1800`

- Symptom: pulling finished files back to local wastes time on Windows with `vastai copy`
  - Root cause: `vastai copy` may require local `rsync`, which is not guaranteed in this controller environment
  - Action: do not start output retrieval with `vastai copy`; first use ComfyUI history API to get the real output filename, then download through `/view`

- Symptom: old job directory exists, but output download fails with missing `8188/tcp` bind information
  - Root cause: earlier saved `vast-instance.json` snapshots did not always include the final mapped ports
  - Action: let the download path fall back to `vastai show instance <id> --raw` and refresh local instance metadata before failing

- Symptom: wrapper or runner fails with "Missing an argument for parameter 'StageArgs'"
  - Root cause: PowerShell treats an explicitly passed empty string-array parameter as a missing value
  - Action: only pass `-StageArgs`, `-LaunchArgs`, or `-PublishArgs` when the array actually contains values

- Symptom: segmented v3 logs show `File ... temp ... already exists` and `Error opening output file ... temp ...`
  - Root cause: non-output `VHS_VideoCombine` preview files can reuse the same prefix while the real output node still writes under `output`
  - Evidence from `segv3-fixed-30s-20260429-213538`:
    - all three segments showed this temp warning
    - all three segment histories still ended with `execution_success`
    - real `*_00001-audio.mp4` outputs were downloaded and merged
  - Action:
    - do not destroy solely because of this temp warning
    - check `/history/<prompt_id>` and the real output node first
    - if history fails, patch non-output preview nodes to avoid prefix collision or set `no_preview=true`

- Symptom: segmented v4 prompt finishes in seconds and history only contains node `299` with `type=temp`, while real node `341` output is missing
  - Root cause: `continue_motion_max_frames` was removed from `WanAnimateToVideo`; ComfyUI validation then excluded the true `save_output` path and only executed the temp preview branch
  - Evidence from `segv4-anchor-30s-20260430-010327`:
    - first prompt `7afac181-8552-40ba-85a8-7e98a2b30a9b` executed in about 11 seconds
    - history `outputs_to_execute` was only `["299"]`
    - output file was `type=temp`, not `type=output`
  - Action:
    - keep `continue_motion_max_frames=5` even when not using `continue_motion`
    - remove non-save `VHS_VideoCombine` preview outputs from v4 runtime workflow so only `save_output=true` node `341` remains
    - do a `PrepareOnly` check before the next paid v4 run: every segment should have no `continue_motion`, should keep `continue_motion_max_frames=5`, and should have exactly one `VHS_VideoCombine` output node

- Symptom: segmented v4 produces a real merged 30s file, but the back half is visually unusable after frame-by-frame review
  - Root cause: every 10s segment is independently re-anchored from the original image without carrying motion/pose state, so segment 2 and segment 3 re-generate different person scale, pose, chair/framing, coat shape, and gesture timing
  - Evidence from `segv4-anchor-30s-20260430-010327`:
    - `second-half-frames-240-end.jpg` shows obvious discontinuity after the first 10s
    - `s02-all-frames.jpg` and `s03-all-frames.jpg` show the raw generated segments are already different before merge
    - `xfade/acrossfade` only blends two different generated shots; it does not solve semantic continuity
  - Action:
    - do not promote v4 or use it for 60s production
    - do not spend another paid run just increasing overlap
    - return to v3 for continuity tests, or create a v5 design that carries motion/pose state while also reintroducing a stable identity reference

- Symptom: adding a new workflow causes another copy-paste orchestration branch
  - Root cause: workflow-specific concerns were mixed into the orchestration layer
  - Action: save the source workflow under `workflows/`, register a new entry in `config/vast-workflow-profiles.json`, and keep the shared runner generic

- Symptom: `vastai create instance --raw` fails locally with a decode error like `'gbk' codec can't decode byte ...`
  - Root cause: the local controller process is decoding Vast CLI output with a non-UTF-8 code page
  - Action: force `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` around the `vastai` call

- Symptom: resumed job fails immediately in download with `Instance metadata missing 8188/tcp port binding`
  - Root cause: the instance is still in `loading`, so `ports` are not populated yet even though the instance id already exists
  - Action: when `-Wait` is enabled, do not fail early; keep retrying base URL resolution until `8188/tcp` appears

- Symptom: `actual_status` flips between `loading`, `running`, or even transient `offline` while `cur_state` is still `running`
  - Root cause: Vast host state and port publication can lag behind the local orchestration view
  - Action: read `ports`, `status_msg`, and elapsed time together before deciding the machine is broken

- Symptom: the operator cannot tell what phase the run is in because the orchestration was started as one long blocking command
  - Root cause: stage / launch / monitor were not separated in the reporting path
  - Action: report progress as numbered steps and use `scripts/watch_vast_workflow_job.ps1` to poll instance status plus relevant logs

- Symptom: `launch` fails with a missing `manifest.json` right after `stage` was started
  - Root cause: `stage` and `launch` were incorrectly run in parallel, so launch read the job directory before stage had finished writing and uploading the manifest
  - Action: never parallelize dependent lifecycle steps; enforce this sequence:
    1. `stage` complete
    2. `launch` complete
    3. `watch`
    4. `download`
    5. `fetch_logs`
    6. `summarize_timings`
    7. `publish`

- Symptom: stage fails before any Vast instance is created with `Missing node bundle directory: output\vast-wan22-root-strict-3090b\node-bundles`
  - Root cause: the legacy default bundle source directory was removed or cleaned, while historical job directories still contained valid bundled zips
  - Action: keep the stage fallback that scans recent `output\wan_2_2_animate\*\node-bundles` directories for the required zip set; do not misclassify this as a Vast machine failure

- Symptom: two independent `stage_wan_2_2_animate_job.ps1` runs fail with Git errors such as `Cannot fast-forward to multiple branches`
  - Root cause: both stage processes update the shared local custom-node cache under `.cache/wan_2_2_animate/custom_nodes` at the same time
  - Evidence from `v10-stability-b` initial stage attempt:
    - A and B were staged in parallel
    - A succeeded
    - B failed updating `.cache/wan_2_2_animate/custom_nodes/ComfyUI-GGUF`
  - Action:
    - stage jobs sequentially for this branch
    - only launch machines after all staging is complete
    - do not parallelize local cache mutation unless each job gets an isolated cache directory

- Symptom: `watch_vast_workflow_job.ps1` crashes with `Cannot bind argument to parameter 'Lines' because it is an empty string`
  - Root cause: a fresh instance can return no logs yet, and the watch helper treated the log list as mandatory non-empty input
  - Action: watch scripts must tolerate empty log output and print `<no relevant log lines yet>` instead of stopping the run

- Symptom: local download succeeds, but `publish` fails with `Cannot bind argument to parameter 'ScriptArgs' because it is an empty string`
  - Root cause: old controller configuration used `ASSET_S3_*` names while the wrapper defaulted to `CLOUDFLARE_*` / `R2_*`, so empty credential values were still appended into `PublishArgs`
  - Action: support `ASSET_S3_*` fallback in stage and publish scripts, and never append an arg pair when the value is blank

- Symptom: a helper command is missing a platform key even though the user already backed it up locally
  - Root cause: the key should exist in root `api.txt`, which is intentionally ignored by Git
  - Action:
    - read root `config.json` for non-secret runtime config
    - read root `api.txt` for platform credentials
    - do not read `.env`; it is no longer a project config source
    - never print key values; report only site names
    - keep `api.txt` in two-line repeated format: site name, then key

- Symptom: `git push` pops a GitHub login window or hangs at Git Credential Manager even though `api.txt` has a GitHub token
  - Root cause: Git's HTTPS credential flow does not automatically read this project's `api.txt`
  - Action:
    - do not print the token
    - stop the stuck Git process if needed
    - use `pwsh -File .\scripts\git_push_with_project_token.ps1`
    - the helper loads `config.json` / `api.txt`, passes the token through a temporary `GIT_ASKPASS`, then cleans it up

- Symptom: standalone Vast helper commands such as `watch_vast_workflow_job.ps1` fail with `403: This action requires login`
  - Root cause: the helper was run outside the main wrapper process, so `VAST_API_KEY` from `api.txt` was not loaded into that process
  - Action:
    - each standalone Vast PowerShell helper should import `scripts/r2_env_helpers.ps1`
    - call `Import-ProjectLocalConfig` before invoking `vastai`
    - never paste the Vast key into command arguments

- Symptom: KJ launch creates the instance, then fails while reading `vastai show instances --raw` with `403: This action requires login` or JSON parse errors beginning with `Failed with error 403`
  - Root cause: the child create-instance helper loaded `VAST_API_KEY`, but the parent launch script did not import local credentials before its follow-up `vastai show instances` polling
  - Action: import `scripts/r2_env_helpers.ps1` and call `Import-ProjectLocalConfig` in every script that calls `vastai`, including launch wrappers after instance creation

- Symptom: a manual pre-check says machine-registry `miss`, but the actual launched run immediately selects a previously successful machine
  - Root cause: Vast offer availability changed between the manual check and the real launch; the earlier result became stale
  - Action:
    - treat the selection output printed by the actual `run_wan_2_2_animate_end_to_end.ps1` launch as authoritative
    - do not present a final `1.0` / `1.1` judgment to the operator based only on an earlier standalone selector run
    - if the real launch flips from pre-check `miss` to launch-time `hit`, correct the operator immediately and switch reasoning to the launch-time result

- Symptom: cleanup step fails immediately with `A parameter cannot be found that matches parameter name 'JobName'`
  - Root cause: `scripts/destroy_vast_instance.ps1` accepts only `-InstanceId`, but the operator guessed it behaved like the job wrappers
  - Action: call it only as `pwsh -File .\scripts\destroy_vast_instance.ps1 -InstanceId <id>`; resolve the id from `vast-instance.json` before cleanup

- Symptom: KJ 30s workflow fails on RTX 3090 with `type fp8e4nv not supported in this architecture` from TorchInductor/Triton
  - Root cause: the source KJ workflow included `WanVideoTorchCompileSettings` node `137`, and `WanVideoModelLoader` still referenced `compile_args`; fp8 + inductor compile is not safe on this RTX 3090 path
  - Action:
    - remove node `137` in `scripts/prepare_wan22_kj_30s_prompt.mjs`
    - delete `node 140.inputs.compile_args`
    - keep `base_precision="fp16"` and `attention_mode="sdpa"`
    - do not retry by reinstalling torch nightly unless this branch is deliberately redesigned

- Symptom: KJ 30s paid run succeeds, but final run report says failed at `summarize_timings`
  - Root cause: `vastai logs` on Windows can hit local GBK encoding errors when remote logs contain non-GBK characters, leaving no real stage markers for the timing parser
  - Action:
    - force `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` around `vastai logs`
    - let timing summary fall back to `history.api.json` for prompt execution time
    - check `manifest.json.result`, `history.api.json`, and the downloaded file before calling the generation failed

- Symptom: `MultiTalk / InfiniteTalk` 10s smoke technically outputs an MP4, but the last seconds stop talking or the mouth no longer follows the audio
  - Evidence from `multitalk10-smoke-20260504-001`:
    - output: `output/multitalk_smoke/multitalk10-smoke-20260504-001/downloads/multitalk_smoke_multitalk10-smoke-20260504-001_00001-audio.mp4`
    - contact sheet: `output/multitalk_smoke/multitalk10-smoke-20260504-001/downloads/contact-sheet.jpg`
    - generated `480x848`, `25fps`, about `11.88s`, with audio
    - user rejected it because the final seconds do not speak and lip sync is wrong
  - Likely root cause:
    - `WanVideoImageToVideoMultiTalk` generated in multiple windows and the last window needed more audio embedding than available
    - remote log showed audio padding behavior similar to: audio embedding length `241`, need `297`, padding
  - Action:
    - do not promote this smoke as a usable route
    - do not continue this branch just because ComfyUI execution succeeded
    - only revisit after redesigning audio segmentation / padding / frame-count handling or switching to a different dedicated lip-sync workflow

- Symptom: `MultiTalk / InfiniteTalk` nodes fail to import on the KJ DockerHub v3 image
  - Root cause: the current KJ v3 image was built for KJ Wan2.2 Animate, not for MultiTalk; it can miss auxiliary packages such as `torchaudio`
  - Evidence: `ComfyUI-WanVideoWrapper` import recovered only after installing `torchaudio==2.11.0+cu130` on the live machine
  - Action:
    - treat MultiTalk as a separate experiment image/profile, not an extension of the KJ v3 production template
    - if revisiting, build a dedicated environment smoke that validates `MultiTalkModelLoader`, `MultiTalkWav2VecEmbeds`, `WanVideoImageToVideoMultiTalk`, and audio-length behavior before downloading all models or running a paid prompt

- Symptom: LTX2.3 ComfyUI startup exits with `Fatal Python error: Illegal instruction`, stack points to `kornia_rs/__init__.py`
  - Root cause: `kornia 0.8.x` pulls `kornia_rs`, whose wheel can require CPU instructions missing on old but otherwise usable 3090 hosts such as `Core i7-3770`
  - Evidence from `ltx23-vbvr-motion-s06-20260504-01`: host `96250`, machine `36223`, driver `590.48.01`, ComfyUI crashed before API; pinning `kornia==0.7.1` and uninstalling `kornia_rs` let the same staged workflow finish
  - Action:
    - do not classify this as a workflow, LTX2.3, or VBVR LoRA failure
    - keep LTX2.3 bootstrap pinned to `kornia==0.7.1`
    - skip floating `kornia>=0.7.1` from ComfyUI requirements
    - after the fix, restart ComfyUI and submit the same staged workflow before destroying the instance

- Symptom: a KJ "clean motion / 自己做动作" test has cleaner body motion but mouth does not match speech
  - Root cause: the KJ branch is primarily reference-motion / image-to-video conditioning; the final audio is muxed into the MP4, but it is not a reliable dense Mandarin lip-sync driver
  - Action:
    - do not use KJ alone as the final口型方案
    - if narration mouth accuracy is required, separate the problem into a dedicated口型/数字人 module plus optional background/B-roll generation
    - do not accept a result only because the body motion looks natural

- Symptom: KJ 30s keeps choosing an expensive previously successful machine with no useful cache
  - Root cause: machine registry preference can overrule cost unless the selector has an explicit price gate and blacklist
  - Action:
    - keep `MaxDphTotal=0.215` for `wan22_kj_30s`
    - do not use `MinDriverMajor` as a hard selection gate; record driver version and act on real CUDA / torch log failures
    - blacklist `machine_id=47075` and `host_id=74292`
    - remember that `warm_start=True` is only a machine-selection mode; it does not prove custom nodes, models, or torch cache hit

- Symptom: KJ 2.0 vertical 10s tests flicker or the background changes, while the previously accepted `720x1280` 30s 4090 sample is stable
  - Root cause: the failing 10s speed-test workflows used `context_frames=41` / `context_overlap=8`, which is not equivalent to the production vertical setting. That short context can destabilize background consistency, especially in prompt-guided same-frame anchor tests.
  - Evidence from 2026-05-03:
    - accepted 4090 30s sample `kj60-vert-4090-v3-dhub-20260502-151759` used `context_frames=121`, `context_overlap=16`, and had top-background flicker metric about `1.024`
    - failed/visibly unstable `cf41` 10s samples measured about `5.767` to `10.943`
    - rerun `kj10-4090-repro-20260503-121023` on RTX 4090 with `720x1280`, `frame_load_cap=161`, `context_frames=121`, `context_overlap=16`, `offload_img_emb=true`, `offload_txt_emb=true` measured `1.085`, matching the stable sample
  - Action:
    - do not use `cf41` workflows for visual quality, flicker, or production acceptance
    - use `scripts/prepare_wan22_kj_30s_prompt.mjs` defaults for vertical quality tests, or explicitly set `context_frames=121` and `context_overlap=16`
    - if a speed smoke must use `cf41`, label it as timing-only and do not compare its visual output to production runs

- Symptom: a cheap 4090 still wastes a cold start because HuggingFace is slow from that host
  - Root cause: Vast offer price and GPU name do not measure real throughput to HuggingFace
  - Action:
    - first list `10-20` candidate offers
    - short-rent only the best `1-3` offers per batch for HF speed preflight
    - if a rented speedtest instance does not reach `[hf-speedtest]` logs within `5 min`, treat startup as too slow and destroy it
    - estimate the KJ model download from the configured `32.55 GiB` remaining model size
    - if no tested offer passes, destroy those instances and continue with the next candidate batch
    - do not run full bootstrap or inference before the HF gate passes

- Symptom: a Vast template or Docker environment image exists, but cold start still spends time downloading Wan/KJ model files
  - Root cause: the `1.2-docker-env-template` experiment only preinstalls KJ custom nodes and Python dependencies; it deliberately does not include model weights
  - Action:
    - keep HF speed preflight enabled
    - keep model existence checks in bootstrap
    - do not call template launch a model-cache hit unless logs show the model files already exist
    - do not use Vast volume as the default cache strategy because it keeps charging and is tied to one physical machine
    - do not write this KJ environment-image experiment back into the old `wan_2_2_animate` production memory

- Symptom: KJ 30s segmented output has hand drift, extra hands, unexpected hand gestures, a short-lived red dot, sticker residue, or local limb/body distortion around a time where the reference video has large sticker text, subtitles, red checkmarks, location pins, banners, or other overlay UI
  - Root cause: the overlay may not be redrawn into the final video, but it still contaminates the reference motion / pose / expression conditioning; the model then guesses the occluded hand/body motion or leaks small visual tokens from the reference
  - Important: this failure is probabilistic. The same reference overlay may pass in one segment/run and leak in another; fixed seed improves repeatability of one run, but it does not prove the source is safe for future long-video segmentation.
  - Evidence from `kj60-bgprompt-anchor-4090-20260430-194236`:
    - final `49.5s-50.5s` frames did not reproduce the large text banner
    - corresponding `reference_segment_02.mp4` `19.5s-20.5s` frames contained large sticker/location text over the lower body and hand area
    - generated output showed hand-motion drift in the same interval even though the prompt and background were stable
  - Evidence from `kj60-cleanref-v7-2seg-20260430-2145`:
    - after cleaning the hand-risk banner window, the hand/multi-hand issue was improved
    - final `26s-30s` review still found a short-lived red point near the leg/chair area around `29.6s`
    - corresponding reference frames contain red UI elements such as a checkmark and location bubble, which can leak as tiny artifacts even when body motion is acceptable
  - Evidence from the 2026-05-02 RTX 4090 / RTX 3090 v3 DockerHub comparison:
    - both runs used the same seed `387956277078883`, same prompt / negative prompt, same `ip_image.png`, and same `reference_segment_02.mp4`
    - the 4090 output was reported to have multi-hand / hand abnormality around final `48s-51s`, while the 3090 output did not visibly amplify it the same way
    - the matching reference window contains subtitles, location pin / red marker, and large white banner text, so classify the issue as reference-overlay contamination plus generation nondeterminism, not as a pure GPU-brand failure
  - Action:
    - treat this as reference-video preprocessing debt, not a prompt, merge, or Vast machine issue
    - before paid reruns, run `scripts/analyze_reference_overlay_risk.py` on the source/reference video and inspect its contact sheet
    - do not treat `scripts/clean_reference_overlay_windows.py` output as passed just because it produced `cleaned_reference.mp4`; the 2026-05-01 `光伏60s.mp4` conservative_v9 run still failed because near-body text remained or became gray blocks and risk-after stayed high
    - clean high-risk reference regions that touch the body, hands, face, key props, or contain bright red/yellow UI tokens; use masking, cropping, blurring, or inpainting depending on how close the overlay is to the body
    - if the before/after sheet still shows readable banners/subtitles, large gray patches, or any face/hand/body damage, stop before Vast stage/inference and escalate to OCR/SAM/GroundingDINO masks or real inpainting
    - after generation, run `scripts/analyze_generated_artifact_risk.py` and inspect the flagged windows; if the defect is only a small isolated red dot, prefer final-video local repair; if the defect changes hands/face/body structure, clean the reference window and rerun only the affected 30s segment
    - after cleaning, re-split into 30s segments and rerun with the same IP image, seed, and fixed background prompt
    - inspect the cleaned reference around each original problem window before renting another full inference pass

- Symptom: KJ 2.0 背景/Mask失败版 output has stable background, but the mouth and body barely move
  - Root cause: connecting `WanVideoAnimateEmbeds.bg_images` plus `mask` over-constrained the original KJ conditioning path; in `kj60-b2-bgmask-20260501-0100`, the `bg_image.png` also contained the complete person instead of a true background-only image, so the model locked onto a nearly static person/background reference
  - Evidence:
    - B2 `body mean 1.2`
    - B2 `mouth mean 0.705`
    - KJ 2.0 同图锚定版 `body mean 8.254`
    - KJ 2.0 同图锚定版 `mouth mean 10.239`
  - Action:
    - do not reuse the B2 `bg_images` / `mask` patch for the current KJ 2.0 path
    - use `KJ 2.0 同图锚定版` instead: stage the same complete anchor image as `ip_image.png` for every `30s` segment and leave node `171` without `bg_images` / `mask`
    - if B2 is redesigned later, first run a 5s+5s smoke test and reject it unless body/mouth motion metrics are close to B1/A

## Fast Triage Order

1. `vastai show instance --raw`
2. Check:
   - `actual_status`
   - `status_msg`
   - `driver_version`
3. If port bind failure:
   - destroy immediately
4. If CUDA Error 804:
   - destroy immediately
5. If container not created yet:
   - wait
6. If ComfyUI import crash:
   - patch bootstrap
   - re-stage
   - retry on a clean machine

## Stop-Loss Rules

Destroy and change host when:
- host port bind fails
- driver / CUDA mismatch triggers Error 804
- the host is clearly incompatible

Do not destroy immediately when:
- image is still pulling
- container is not created yet
- model download is still in progress

## Verified Lessons

- a fresh host can succeed; mother-machine dependence was not the real root cause
- the successful branch is smaller than earlier versions
- unused custom nodes were one of the main sources of wasted time and false debugging trails
- consistent Chinese filenames are part of the working contract, not cosmetic detail
- R2 staging must be regenerated after every runtime script change
- Vast local volumes are not a general cross-machine solution; they are tied to one physical machine
- if you want faster retries across the same machine, volumes help
- if you want faster recovery across different machines, volumes alone do not solve it
- for this branch, `CN` hosts are not used by default, and `TR` hosts need real speed/bootstrap evidence before they are treated as cheap in practice

## Log Patterns That Are Slow But Healthy

These log patterns are slow, but they are not failures by themselves:

- `Downloading trampoline-0.1.2-py3-none-any.whl`
- `Installing collected packages: trampoline, torchsde`
- `Successfully installed torchsde-0.2.6 trampoline-0.1.2`
- `[bootstrap] python module exists: color_matcher`
- `[bootstrap] creating model directories`
- `[bootstrap] downloading: Wan2.2-Animate-14B-Q4_K_S.gguf`
- `[bootstrap] downloading: umt5_xxl_fp8_e4m3fn_scaled.safetensors`

Interpret them like this:
- pip output means dependency phase
- `creating model directories` means dependency phase is ending
- large curl percentage output means model phase is active
- changing ETA during curl output is normal and should not be treated as a hard hang

## Known Good Signals

When a run is probably healthy, you should see:
- `torch 2.6.0+cu124`
- GPU detected correctly
- ComfyUI API responds on `8188`
- queue enters `running`
- history ends with `execution_success`
- `run-report.json` records completed local steps with durations
- `timing-summary.json` records remote lifecycle timing

## Output Retrieval Anti-Pattern

Do not use this sequence as the default on Windows:
- try `vastai copy`
- then try SSH
- then inspect remote directories

Use this sequence instead:
1. `GET /history` or `GET /history/{prompt_id}`
2. read `outputs -> filename/type/subfolder`
3. `GET /view?...` to download the file

Why:
- history gives the authoritative filename
- `/view` avoids controller-side `rsync` dependency
- this removes needless trial-and-error during the last step

## Visibility Rule

Do not claim a run is "still going" without showing evidence.

When the operator asks for visibility:
1. show current numbered step
2. show current instance state
3. show whether `8188` is mapped
4. show the latest relevant log lines

In this chat environment, continuous byte-for-byte log streaming is not guaranteed.
Use repeated polling output instead of pretending true live streaming exists.

Do not start a paid Vast run and then wait silently for 20 minutes.
This has already caused operator confusion.

Required live-run reporting cadence:
1. after `stage`, report duration and staged job path
2. after `launch`, report instance id, host id, machine id, mapped `8188` port, and whether `WARM_START=1`
3. during `bootstrap`, report whether it is in custom node setup, Python dependency setup, or model download
4. during inference, report the latest progress marker such as `0/4`, `1/4`, `2/4`, `3/4`, or `4/4`
5. after output appears, report download path, publish URL, and destroy status

Avoid one long monolithic `run_wan_2_2_animate_end_to_end.ps1` call when the human is actively watching.
Use short polling with `watch_vast_workflow_job.ps1` so progress is visible.

## Structural Rule For Future Workflows

When the workflow itself changes, do not assume the proven `wan_2_2_animate` output-matching logic still applies.

You must re-prove at least these workflow-specific pieces:
- source workflow JSON under `workflows/`
- which stage script prepares its inputs
- which output prefix or filename pattern identifies the right result
- whether publish rules still map to the same R2 prefix

The orchestration layer can stay shared.
The workflow contract cannot be guessed.

## Same-Machine Trap

Do not confuse these two ideas:
- same-machine preference
- real cache reuse

What was proven:
- renting the same physical machine again can reduce startup wait
- it can save a few minutes before bootstrap or before instance readiness

What was not proven:
- `custom_nodes` will already be reusable
- models will already be reusable
- torch will already be reusable

Concrete example from the validated `56268` machine:
- total runtime improved versus the first cold run
- but logs still showed:
  - `warm-start miss: custom_nodes`
  - `warm-start miss: models`
  - torch reinstall or non-hit behavior

So the correct rule is:
- treat same-machine preference as a probabilistic speedup
- do not treat it as a guaranteed cache hit

## Registry Update Trap

When the same machine has multiple successful runs, never let an older success overwrite a newer one.

Registry write logic must preserve the newest `last_success_at` record for a machine.
Otherwise selection can drift back to stale timing data and stale offer assumptions.

## Reminder

The job is not to keep a broken machine alive.

The job is to identify whether the failure is:
- host problem
- bootstrap problem
- staged asset problem
- workflow problem

Then take the cheapest next action.

## KJ 2.1-next Reference Cleaning Trap

Do not keep iterating local OCR glyph masks or OpenCV inpaint variants for the 2026-05-01 `光伏60s.mp4` source.

Failed approaches:
- OCR glyph mask + OpenCV Telea/NS inpaint
- thicker glyph masks and local mask variants
- temporal/median-style local fill attempts
- `simple-lama-inpainting` single-frame probes on `0s`, `30s`, `45s`, and `50.5s`

Why they failed:
- OCR can detect the Chinese text, but glyph masks leave outlines, shadows, white/orange/gray blocks, or visible bubble frames.
- Full-box or bubble masks overlap the body, hands, legs, or clothing.
- LaMa removes the UI but hallucinates photovoltaic panels or semi-transparent fabric/body regions where the person should remain.

Rule:
- If the before/after sheet does not clearly remove text/bubbles while preserving face, hands, body, legs, and clothing, stop before `stage` / `inference`.
- For 2.1/2.2 validation, run the segmented entry with `-ReferenceRiskPolicy FailOnHigh`; do not bypass a high-risk preflight report just because the previous B2 output passed once.
- For this source, prefer a clean reference video, manual/professional cleanup, or stronger semantic/video object-removal tools tested on 1s windows first.

## HeyGem + IndexTTS2 Smoke Traps

- Symptom: RTX 5060 Ti 16GB 上 HeyGem 服务或 torch 推理报 `CUDA error: no kernel image is available for execution on the device`
  - Root cause: `guiji2025/heygem.ai:latest` 内置 `torch 2.2.2+cu118` 不支持 RTX 50 系 compute capability `12.0`。
  - Evidence from 2026-05-25 instance `37735878`：不是显存不足，而是 CUDA kernel 架构不兼容。
  - Action: 这个镜像当前不要继续租 5060 Ti 跑完整 HeyGem；如果 Vast 没有已验证支持 RTX 50 系的新 HeyGem 镜像/torch 栈，回退 `RTX 3090 24GB`。

- Symptom: `IndexTTS2Run` 使用 `deepspeed=false` 仍报 `No module named 'deepspeed'`
  - Root cause: 当前 `ComfyUI_IndexTTS/indexttsnode.py` 在初始化 `IndexTTS2` 时硬编码调用 `post_init_gpt2_config(use_deepspeed=True, ...)`，`deepspeed=false` 反而走到未捕获导入错误。
  - Action: 运行 prompt 里把 `IndexTTS2Run.deepspeed=true`，让节点进入已有 fallback：`DeepSpeed加载失败，回退到标准推理`。不要先花时间安装 deepspeed。

- Symptom: 原 workflow 节点 `RH_HeyGemNode` 在远端 ComfyUI 不存在
  - Root cause: 当前安装的 HeyGem custom node 暴露类名是 `HeyGemRun`。
  - Action: 运行 prompt 里映射到 `HeyGemRun`，并确认输入类型。`HeyGemRun` 要吃 `IMAGE` 帧序列，不是新版 `VIDEO` 对象。

- Symptom: HeyGem 父容器服务能访问，但 ComfyUI 节点提交后找不到输入文件或服务没有处理任务
  - Root cause: 父容器方案里 HeyGem 服务读取 `/code/data/temp/...`，ComfyUI 节点默认临时目录可能不是这个路径。
  - Action: 在远端 `Comfyui_HeyGem/heygem_node.py` 设置 `TEMP_DIR='/code/data'`，并确保音频和中间视频都写到 `/code/data/temp`。

- Symptom: HeyGem 已生成 `/code/data/temp/<taskcode>-r.mp4`，但 ComfyUI `SaveVideo` 迟迟不落盘或先出现 48 字节占位 MP4
  - Root cause: HeyGem 节点轮询和 ComfyUI 二次封装可能存在延迟；不能因为输出目录短暂出现小文件就判断成功或失败。
  - Evidence from 2026-05-25：直接 HeyGem 产物 `ffb04721-9bb7-4a79-b536-1d0aabd3ecb0-r.mp4` 已生成后，ComfyUI 正式输出稍后才变为完整 `7.75MB` 文件并写入 history。
  - Action: 先保底下载 `/code/data/temp/<taskcode>-r.mp4`；再等 `/history/<prompt_id>` 的 `execution_success` 和真实输出名，通过 `/view` 下载正式文件。不要猜文件名。

- Symptom: `vastai show instances --raw` 返回 `403: This action requires login`
  - Root cause: 当前 shell 没有加载项目 `api.txt` 里的 `VAST_API_KEY`。
  - Action: 先执行 `. .\scripts\r2_env_helpers.ps1; Import-ProjectLocalConfig | Out-Null`，再跑 `vastai show instances --raw`。不要把 Vast key 打到命令行或聊天。

- Symptom: 3090 机器 driver `535.*` 上 ComfyUI torch 改成 `cu124` 后无法稳定作为默认选择
  - Root cause: `535.309.01` 驱动对当前 ComfyUI / PyTorch 组合更适合 `cu118` 路线；不要照搬另一台 3090 的 `cu124` 结论。
  - Evidence from 2026-05-26 instance `37763730`：最终栈为 `torch 2.6.0+cu118`、`cuda 11.8`、CUDA 可用，并成功跑出移动视频。
  - Action: HeyGem 父容器方案遇到 `driver 535.*` 时优先使用 `torch 2.6.0+cu118`；只有新驱动机器再考虑 `cu124`。

- Symptom: `vastai destroy instance` 或 `vastai show instances --raw` 在本地长时间卡住，但远端 SSH/ComfyUI 仍在线
  - Root cause: 本地 Vast CLI 调用可能卡在网络/API 等待，不代表实例已销毁。
  - Evidence from 2026-05-26 instance `37763730`：`destroy_vast_instance.ps1` 超时后，SSH 仍返回 `alive`，ComfyUI `/system_stats` 仍是 `200`。
  - Action: 不要假设销毁成功；先停止本轮超时残留的本地 `vastai` 进程，再加载 `VAST_API_KEY`，直接调用 Vast API `DELETE https://console.vast.ai/api/v0/instances/<id>/`。销毁后必须复查：实例详情为 `instances:null`，活动实例列表无匹配，SSH 拒绝连接或端口不可用。

- Symptom: 74s 视频 / 143s TTS 音频用 ComfyUI `LoadVideo -> GetVideoComponents -> HeyGemRun` 跑 720p 时实例 OOM。
  - Root cause: 这条 ComfyUI 路线会把长视频展开为 `IMAGE` tensor 序列；`720x1280`、`143s`、`30fps` 会吃掉大量内存，当前父容器 cgroup 内存上限约 `119GB`，会触发 `oom_kill`。
  - Evidence from 2026-05-26 instance `37835034`：720p ComfyUI prompt `0d01c705-463d-4e33-97ba-f919a57924e7` 和 direct-audio prompt `93e0ffe6-11f1-4bb4-af4f-fa2d31981c85` 都失败；随后绕开 ComfyUI、直接调用 HeyGem 父服务 `/easy/submit` 成功生成 720p 和 1080p。
  - Action: HeyGem 长视频不要走 ComfyUI 展帧节点。先用 `ffmpeg` 把视频补到音频时长，再提交文件级 `audio_url` + `video_url` 到父服务 `/easy/submit`。

- Symptom: HeyGem 父服务长视频任务卡在约 `20%` 或日志出现 `libgomp: Thread creation failed`。
  - Root cause: HeyGem 父服务和底层数值库默认线程过多，长视频并发阶段容易触发线程创建失败。
  - Evidence from 2026-05-26 instance `37835034`：限制线程后重启 `/code/app_local.py`，同一实例完成 `143.336s` 的 720p 和 1080p。
  - Action: 重启 HeyGem 父服务时固定限制线程：`OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 OMP_THREAD_LIMIT=1`。

- Symptom: `scp` 下载 1080p HeyGem 输出长时间超时，本地只留下 `0` 字节文件。
  - Root cause: Windows 本地 `scp` 默认 SFTP 通道可能卡住，不代表远端文件损坏。
  - Evidence from 2026-05-26 `heygem74_1080p_file_20260526_01-r.mp4`：第一次 `scp` 超时后本地为 `0` 字节，远端文件完整约 `229MB`；清理远端 `sftp-server` 后用 `scp -O` legacy scp 模式成功下载。
  - Action: 先用 `ls -lh` 确认远端文件大小；如本地是 0 字节占位，杀掉残留 `sftp-server`，改用 `scp -O` 重新下载。
