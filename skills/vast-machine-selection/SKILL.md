---
name: vast-machine-selection
description: Use when selecting, renting, switching, or evaluating Vast.ai machines for paid ComfyUI video jobs, especially RTX 3090/4090 LTX2.3, Wan2.2, or KJ runs. Covers price gates using storage-inclusive dph_total, region exclusion, download speed preflights, machine-registry priority, warm-start interpretation, stop-loss decisions, and reporting requirements.
---

# Vast Machine Selection

## Core Rule

Treat machine choice as a cost-and-speed decision, not as a memory preference.

Use the real `dph_total` after `--storage`, not the bare GPU price. A known successful machine is only a tie-breaker after the current price and speed gates pass.

## Price Gates

For `RTX 3090 24GB` paid runs:

- Preferred target: storage-inclusive `dph_total <= $0.15/h`.
- Acceptable fallback: `<= $0.16/h` if the `<= $0.15/h` candidates are unavailable or fail speed checks.
- Temporary stretch: `<= $0.18/h` only after reporting why cheaper candidates failed.
- Above `$0.18/h`: ask or explicitly justify before launch, except when the user has already approved a higher ceiling for that specific run.
- Never let machine-registry preference choose a more expensive old machine when a cheaper candidate passes price and speed checks.

For KJ 30s / segmented jobs that need larger storage, search with the real storage size, usually `--storage 240`. For LTX2.3 smoke, use its real storage setting, commonly `--storage 180`. Do not compare a 40GB/80GB test price with a real 180GB/240GB run price.

For `RTX 4090` jobs, use the same logic but state the chosen ceiling before launch because the user may accept higher cost for speed.

## Region Rules

Do not rent `CN` for paid generation jobs by default.

This rule was updated from the user request on 2026-05-05 after a CN LTX2.3 cold start spent too long in PyTorch/NVIDIA wheel downloads. Keep `CN` out of default paid generation searches unless the user explicitly re-allows it later.

Default region handling:

- Exclude `CN` in the candidate list for paid generation.
- If a user explicitly asks to test `CN` later, run only a short speed preflight first and destroy quickly if dependency or model sources crawl.
- Keep `TR` as a speed-risk signal because previous cold starts depended on sources that were often slow there, but do not treat it as a hard exclusion unless the current run explicitly says to exclude risky regions.
- Prefer non-`CN` candidates even when they are modestly more expensive, as long as the cost is still within the stated ceiling.

## Candidate Search

List enough offers before renting:

```powershell
vastai search offers "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN]" --storage 180 -o "dph_total"
```

For KJ 30s / segmented:

```powershell
vastai search offers "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 disk_space>240 direct_port_count>=4 rented=False geolocation notin [CN]" --storage 240 -o "dph_total"
```

Selection order:

1. Filter by required GPU, storage, direct ports, and `CN` exclusion.
2. Sort by storage-inclusive `dph_total`.
3. Keep the cheapest 10-20 realistic candidates after excluding `CN` by default.
4. Do not hard-reject a machine only because `driver_version` is below `580.*`; record the driver and judge compatibility from real CUDA/torch/bootstrap logs.
5. Use machine registry only after price and speed are acceptable.

## Speed Preflight

Before a full cold start on a new or questionable host, run a short paid preflight and destroy quickly if it fails.

Measure the actual sources the workflow needs:

- Docker/image startup readiness.
- R2 input download.
- PyTorch CUDA wheel source if the bootstrap installs torch.
- PyPI/NVIDIA wheels that have been slow before, especially `onnxruntime_gpu`.
- Hugging Face / model source for the workflow's large files.

Do not trust only Vast panel `inet_down`, `inet_up`, or `dlperf`. Those are useful hints, but the real decision comes from bootstrap logs showing actual MB/s for the required sources.

Good signals:

- Hugging Face/model downloads sustain roughly `20-50 MB/s` or better.
- PyTorch large wheels sustain multiple MB/s.
- Small dependency wheels are not stuck for minutes.
- R2 input fetches complete quickly.

Bad signals:

- Large PyPI/NVIDIA wheels such as `onnxruntime_gpu` crawl below about `500 KB/s`.
- No new bootstrap stage marker appears for too long while only one dependency is downloading.
- SSH/API/port mapping is unstable even after the instance says `running`.

## Stop-Loss

Destroy and switch machine when:

- Host never maps `8188` or port/API access is unstable.
- Startup logs do not appear after a reasonable window.
- CUDA/driver mismatch appears.
- A required source is clearly crawling and the remaining cold start would cost more than trying another cheap candidate.

Do not destroy immediately when:

- A large download is progressing with visible MB/s.
- A known-slow but finite wheel is near completion.
- The job is already in inference unless the queue is dead or the user asks to stop.

When switching, report:

- Old `instance_id`.
- Reason for switch.
- New candidate price, region, host, and machine id.
- Which stage restarts: `stage`, `launch`, `bootstrap`, `inference`, or `download`.

## Machine Registry

The registry is evidence, not authority:

- A registry hit means the machine succeeded before.
- It does not prove the current container, custom nodes, models, torch stack, or pip cache are still present.
- Same machine does not equal cache hit.
- Warm start is only valid after logs show actual hit lines for models, nodes, or dependencies.

Use registry preference only when:

- Its `dph_total` is within the current price gate.
- It does not block cheaper candidates that passed speed preflight.
- The current run benefits from likely cache reuse.

## Reporting

Before launch, state:

- Search storage size.
- Price ceiling.
- Confirm `CN` is excluded, unless the user explicitly re-allowed it for that run.
- Whether the selected machine is cheap-first, speed-tested, or registry-preferred.

During paid runs, keep the normal stage sequence visible:

1. `stage`
2. `launch`
3. `port mapping`
4. `bootstrap`
5. `inference`
6. `download`
7. `fetch_logs`
8. `summarize_timings`
9. `publish`
10. `destroy`
11. `update registry`

When discussing speed, quote actual log evidence such as `MB/s`, dependency names, model names, and stage durations. Do not only say "network is good" based on Vast offer metrics.

## CN Answer

If asked whether `CN` is fast, answer:

`CN` is currently not used for paid generation in this project. It may be cheap, but the 2026-05-05 LTX2.3 run showed PyTorch/NVIDIA dependency downloads were too slow for this workflow. Only test `CN` again if the user explicitly re-allows it, and then use a short preflight before full inference.
