import fs from "node:fs/promises";
import path from "node:path";
import { uploadAssets } from "./assets.js";
import { loadAppConfig, loadWorkflowRegistry } from "./config.js";
import { rewriteTranscript, transcribeAudio } from "./llm.js";
import {
  buildJobsFromPlan,
  createDeployment,
  getDeployment,
  getRequestResult,
  getRequestStatus,
  listDeployments,
  submitJob,
  updateDeployment
} from "./runcomfy.js";
import {
  extractBackgroundPlate,
  extractMonoWav,
  prepareDrivingVideo,
  prepareSpeakerImage,
  probeVideo
} from "./video.js";
import { ensureDir, formatDuration, parseArgs, readJson, slugify, writeJson } from "./utils.js";

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const { options, positionals } = parseArgs(rest);
  const config = loadAppConfig();

  switch (command) {
    case "inspect":
      await handleInspect(options);
      break;
    case "transcribe":
      await handleTranscribe(config, options);
      break;
    case "rewrite":
      await handleRewrite(config, options);
      break;
    case "prepare-driving-video":
      await handlePrepareDrivingVideo(options);
      break;
    case "prepare-background":
      await handlePrepareBackground(config, options);
      break;
    case "build-jobs":
      await handleBuildJobs(config, options);
      break;
    case "submit":
      await handleSubmit(config, options);
      break;
    case "poll":
      await handlePoll(config, options);
      break;
    case "watch":
      await handleWatch(config, options);
      break;
    case "estimate":
      handleEstimate(options);
      break;
    case "create-deployment":
      await handleCreateDeployment(config, options);
      break;
    case "fetch-deployment":
      await handleFetchDeployment(config, options);
      break;
    case "list-deployments":
      await handleListDeployments(config, options);
      break;
    case "update-deployment":
      await handleUpdateDeployment(config, options);
      break;
    case "pipeline":
      await handlePipeline(config, options);
      break;
    case "upload-assets":
      await handleUploadAssets(config, options, positionals);
      break;
    default:
      printHelp();
      process.exitCode = command ? 1 : 0;
  }
}

async function handleInspect(options) {
  const input = requireOption(options.input, "--input");
  const meta = await probeVideo(input);
  console.log(JSON.stringify(meta, null, 2));
}

async function handleTranscribe(config, options) {
  const input = requireOption(options.input, "--input");
  const outputDir = await prepareOutputDir(options.outputDir, input);
  const audioPath = path.join(outputDir, "audio.wav");
  const transcriptJsonPath = path.join(outputDir, "transcript.json");
  const transcriptTxtPath = path.join(outputDir, "transcript.txt");

  await extractMonoWav(input, audioPath);
  const transcript = await transcribeAudio({
    config,
    audioPath,
    language: options.language || "zh"
  });

  await writeJson(transcriptJsonPath, transcript);
  await fs.writeFile(transcriptTxtPath, `${transcript.text}\n`, "utf8");

  console.log(`转写完成: ${transcriptJsonPath}`);
}

async function handleRewrite(config, options) {
  const transcriptText = await loadTranscriptText(options);
  const transcriptSegments = await loadTranscriptSegments(options);
  const videoMeta = options.input ? await probeVideo(options.input) : { durationSec: Number(options.duration || 120) };
  const plan = await rewriteTranscript({
    config,
    transcriptText,
    transcriptSegments,
    videoMeta,
    styleHint: options.style || config.defaultRewriteStyle,
    minuteTarget: Number(options.minutes || 2)
  });

  const outputDir = await prepareOutputDir(options.outputDir, options.input || "rewrite");
  const planPath = path.join(outputDir, "rewrite-plan.json");
  await writeJson(planPath, plan);
  console.log(`重写计划已生成: ${planPath}`);
}

async function handlePrepareDrivingVideo(options) {
  const input = requireOption(options.input, "--input");
  const cropBottomPx = Number(options.cropBottomPx || 0);
  const blurBottomPx = Number(options.blurBottomPx || 0);
  const blurBoxes = parseBoxSpecs(options.blurBoxes || "");
  const outputDir = await prepareOutputDir(options.outputDir, `${path.parse(input).name}-prepared`);
  const outputPath = path.join(outputDir, options.outputName || "driving-video-clean.mp4");

  const preparedPath = await prepareDrivingVideo({
    inputPath: input,
    outputPath,
    cropBottomPx,
    blurBottomPx,
    blurBoxes
  });

  const meta = await probeVideo(preparedPath);
  await writeJson(path.join(outputDir, "video-meta.json"), meta);
  console.log(
    [
      `驱动视频已生成: ${preparedPath}`,
      "建议把这个文件上传到公网后，再作为 --source-video-url 提交给 RunComfy。",
      `视频尺寸: ${meta.video?.width || "?"}x${meta.video?.height || "?"}`,
      `视频时长: ${formatDuration(meta.durationSec)}`
    ].join("\n")
  );
}

async function handlePrepareBackground(config, options) {
  const input = requireOption(options.input, "--input");
  const outputDir = await prepareOutputDir(options.outputDir, `${path.parse(input).name}-background`);
  const outputPath = path.join(outputDir, options.outputName || "background-plate.png");
  const sampleCount = Number(options.sampleCount || 12);

  const result = await extractBackgroundPlate({
    inputPath: input,
    outputPath,
    pythonPath: config.fasterWhisperPython,
    sampleCount
  });

  await writeJson(path.join(outputDir, "background-meta.json"), {
    input: path.resolve(process.cwd(), input),
    backgroundPlatePath: result.backgroundPlatePath,
    sampleFrames: result.sampleFrames,
    sampleCount
  });

  console.log(
    [
      `背景板已生成: ${result.backgroundPlatePath}`,
      `采样帧数: ${result.sampleFrames.length}`,
      `元数据: ${path.join(outputDir, "background-meta.json")}`
    ].join("\n")
  );
}

async function handleBuildJobs(config, options) {
  const workflowRegistry = await loadWorkflowRegistry(config);
  const planPath = requireOption(options.plan, "--plan");
  const plan = await readJson(path.resolve(process.cwd(), planPath));
  const jobs = buildJobsFromPlan({
    plan,
    workflowRegistry,
    globals: buildGlobals(options)
  });

  const outputDir = await prepareOutputDir(options.outputDir, planPath);
  const jobsPath = path.join(outputDir, "runcomfy-jobs.json");
  await writeJson(jobsPath, jobs);
  console.log(`RunComfy job 模板已生成: ${jobsPath}`);
}

async function handleSubmit(config, options) {
  assertRunComfyKey(config);
  const jobsPath = requireOption(options.jobs, "--jobs");
  const resolvedJobsPath = path.resolve(process.cwd(), jobsPath);
  const jobs = await readJson(path.resolve(process.cwd(), jobsPath));
  const submitted = [];

  for (const job of jobs) {
    if (!job.deploymentId || job.error) {
      submitted.push({
        ...job,
        submissionError: job.error || "deploymentId 缺失"
      });
      continue;
    }

    try {
      const response = await submitJob({
        config,
        deploymentId: job.deploymentId,
        requestBody: job.request
      });

      submitted.push({
        ...job,
        response
      });
    } catch (error) {
      submitted.push({
        ...job,
        submissionError: error.message || String(error)
      });
    }
  }

  const outputPath = path.join(
    path.dirname(resolvedJobsPath),
    `${path.parse(resolvedJobsPath).name}.submitted.json`
  );
  await writeJson(outputPath, submitted);
  console.log(`提交结果已写入: ${outputPath}`);
}

async function handlePoll(config, options) {
  assertRunComfyKey(config);
  const jobsPath = requireOption(options.jobs, "--jobs");
  const resolvedJobsPath = path.resolve(process.cwd(), jobsPath);
  const jobs = await readJson(resolvedJobsPath);
  const withResults = [];

  for (const job of jobs) {
    const requestId = job.response?.request_id;
    if (!job.deploymentId || !requestId) {
      withResults.push(job);
      continue;
    }

    try {
      const status = await getRequestStatus({
        config,
        deploymentId: job.deploymentId,
        requestId
      });

      let result = null;
      if (status.status === "completed" || status.status === "succeeded") {
        result = await getRequestResult({
          config,
          deploymentId: job.deploymentId,
          requestId
        });
      }

      withResults.push({
        ...job,
        status,
        result
      });
    } catch (error) {
      withResults.push({
        ...job,
        pollError: error.message || String(error)
      });
    }
  }

  const outputPath = path.join(
    path.dirname(resolvedJobsPath),
    `${path.parse(resolvedJobsPath).name}.status.json`
  );
  await writeJson(outputPath, withResults);
  console.log(`状态结果已写入: ${outputPath}`);
}

async function handleWatch(config, options) {
  const jobsArg = requireOption(options.jobs, "--jobs");
  const jobsPaths = String(jobsArg)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const intervalSec = Math.max(5, Number(options.intervalSec || 30));
  const maxRounds = Math.max(1, Number(options.maxRounds || 120));

  for (let round = 1; round <= maxRounds; round += 1) {
    const summaries = [];

    for (const jobsPath of jobsPaths) {
      await handlePoll(config, { jobs: jobsPath });
      const resolvedJobsPath = path.resolve(process.cwd(), jobsPath);
      const statusPath = path.join(
        path.dirname(resolvedJobsPath),
        `${path.parse(resolvedJobsPath).name}.status.json`
      );
      const items = await readJson(statusPath);
      for (const item of items) {
        summaries.push(`${item.workflowKey}:${item.status?.status || "unknown"}`);
      }
    }

    const line = `第 ${round} 轮: ${summaries.join(", ")}`;
    console.log(line);
    const hasPending = summaries.some((item) =>
      /:(in_queue|starting|running|processing|pending|in_progress)$/i.test(item)
    );
    if (!hasPending) {
      return;
    }

    await new Promise((resolve) => setTimeout(resolve, intervalSec * 1000));
  }
}

function handleEstimate(options) {
  const gpu = (options.gpu || "24gb").toLowerCase();
  const runtimeMinutes = Number(options.runtime || 20);
  const outputMinutes = Number(options.minutes || 2);
  const priceMap = {
    "16gb": 0.99,
    "24gb": 1.75,
    "a100": 4.99,
    "h100": 7.49
  };

  const hourlyPrice = priceMap[gpu];
  if (!hourlyPrice) {
    throw new Error(`未知显卡档位: ${gpu}`);
  }

  const totalUsd = hourlyPrice * (runtimeMinutes / 60);
  const perMinuteUsd = totalUsd / outputMinutes;
  console.log(
    JSON.stringify(
      {
        gpu,
        runtimeMinutes,
        outputMinutes,
        totalUsd: Number(totalUsd.toFixed(4)),
        perMinuteUsd: Number(perMinuteUsd.toFixed(4))
      },
      null,
      2
    )
  );
}

async function handlePipeline(config, options) {
  const mode = normalizePipelineMode(options.mode);
  if (mode === "fixed_bg") {
    await handleFixedBgPipeline(config, options);
    return;
  }

  const input = requireOption(options.input, "--input");
  const outputDir = await prepareOutputDir(options.outputDir, input);
  const videoMeta = await probeVideo(input);
  await writeJson(path.join(outputDir, "video-meta.json"), videoMeta);

  let transcriptText;
  let transcriptPayload;
  if (options.transcriptFile) {
    transcriptText = await fs.readFile(path.resolve(process.cwd(), options.transcriptFile), "utf8");
    transcriptPayload = { text: transcriptText, source: "external_file" };
  } else if (canTranscribe(config)) {
    const audioPath = path.join(outputDir, "audio.wav");
    await extractMonoWav(input, audioPath);
    transcriptPayload = await transcribeAudio({
      config,
      audioPath,
      language: options.language || "zh"
    });
    transcriptText = transcriptPayload.text;
  } else {
    transcriptText =
      "未配置可用转写 provider。当前使用 fallback 规划器，请在 output 目录里手工替换 transcript.txt 后重跑 rewrite/build-jobs。";
    transcriptPayload = { text: transcriptText, source: "fallback_notice" };
  }

  await writeJson(path.join(outputDir, "transcript.json"), transcriptPayload);
  await fs.writeFile(path.join(outputDir, "transcript.txt"), `${transcriptText}\n`, "utf8");

  const plan = await rewriteTranscript({
    config,
    transcriptText,
    transcriptSegments: transcriptPayload.segments || [],
    videoMeta,
    styleHint: options.style || config.defaultRewriteStyle,
    minuteTarget: Number(options.minutes || 2)
  });
  await writeJson(path.join(outputDir, "rewrite-plan.json"), plan);

  const workflowRegistry = await loadWorkflowRegistry(config);
  const jobs = buildJobsFromPlan({
    plan,
    workflowRegistry,
    globals: buildGlobals(options)
  });
  await writeJson(path.join(outputDir, "runcomfy-jobs.json"), jobs);

  console.log(
    [
      `输出目录: ${outputDir}`,
      `视频时长: ${formatDuration(videoMeta.durationSec)}`,
      `分镜数: ${plan.segments.length}`,
      "已生成: video-meta.json / transcript.json / rewrite-plan.json / runcomfy-jobs.json"
    ].join("\n")
  );
}

async function handleFixedBgPipeline(config, options) {
  const input = requireOption(options.input, "--input");
  const outputDir = await prepareOutputDir(options.outputDir, `${path.parse(input).name}-fixed-bg`);
  const videoMeta = await probeVideo(input);
  await writeJson(path.join(outputDir, "video-meta.json"), videoMeta);

  const audioPath = path.join(outputDir, "audio.wav");
  await extractMonoWav(input, audioPath);

  let transcriptText;
  let transcriptPayload;
  if (options.transcriptFile) {
    transcriptText = await loadTranscriptText(options);
    transcriptPayload = {
      text: transcriptText,
      segments: await loadTranscriptSegments(options),
      source: "external_file"
    };
  } else if (canTranscribe(config)) {
    transcriptPayload = await transcribeAudio({
      config,
      audioPath,
      language: options.language || "zh"
    });
    transcriptText = transcriptPayload.text;
  } else {
    transcriptText = "未配置可用转写 provider。fixed_bg 模式仍然保留音频和背景板，但 transcript 需要后补。";
    transcriptPayload = { text: transcriptText, segments: [], source: "fallback_notice" };
  }

  await writeJson(path.join(outputDir, "transcript.json"), transcriptPayload);
  await fs.writeFile(path.join(outputDir, "transcript.txt"), `${transcriptText}\n`, "utf8");

  const backgroundPlatePath = options.backgroundPlatePath
    ? path.resolve(process.cwd(), options.backgroundPlatePath)
    : path.join(outputDir, "background-plate.png");

  let backgroundMeta;
  if (options.backgroundPlatePath) {
    backgroundMeta = {
      input: path.resolve(process.cwd(), input),
      backgroundPlatePath,
      sampleFrames: [],
      sampleCount: 0,
      source: "external_file"
    };
  } else {
    const background = await extractBackgroundPlate({
      inputPath: input,
      outputPath: backgroundPlatePath,
      pythonPath: config.fasterWhisperPython,
      sampleCount: Number(options.sampleCount || 12)
    });
    backgroundMeta = {
      input: path.resolve(process.cwd(), input),
      backgroundPlatePath: background.backgroundPlatePath,
      sampleFrames: background.sampleFrames,
      sampleCount: background.sampleFrames.length,
      source: "local_median_sampler"
    };
  }
  await writeJson(path.join(outputDir, "background-meta.json"), backgroundMeta);

  const workflowRegistry = await loadWorkflowRegistry(config);
  const avatarWorkflowKey = options.avatarWorkflow || "liveportrait_img2vid";
  const avatarWorkflow = workflowRegistry[avatarWorkflowKey];
  const avatarBindingSources = new Set(
    (avatarWorkflow?.inputBindings || []).map((binding) => binding.from)
  );
  const speakerImageEntries = await collectSpeakerImageEntries(options, outputDir);
  const backgroundWorkflowKeys = String(
    options.backgroundWorkflows || "matanyone,diffueraser_bgfill"
  )
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const avatarSegment = {
    index: 1,
    durationSec: Math.max(6, Math.ceil(videoMeta.durationSec || 6)),
    segmentType: "main_talking_head",
    voiceover: transcriptText,
    visualPrompt: buildAvatarPrompt({
      avatarWorkflowKey,
      transcriptText,
      overridePrompt: options.avatarPrompt
    }),
    runcomfyWorkflow: avatarWorkflowKey,
    notes: "fixed_bg 模式：人物视频后续需要与 background-plate 重新合成"
  };

  let avatarJobs = [];
  if (speakerImageEntries.length === 0) {
    avatarJobs = [
      {
        segmentIndex: 1,
        workflowKey: avatarWorkflowKey,
        error: "缺少 --speaker-image-url 或 --speaker-image-urls，无法生成 avatar job。",
        segment: avatarSegment
      }
    ];
  } else if (avatarBindingSources.has("globals.sourceAudioUrl") && !options.sourceAudioUrl) {
    avatarJobs = [
      {
        segmentIndex: 1,
        workflowKey: avatarWorkflowKey,
        error: "缺少 --source-audio-url。请先上传 output 目录里的 audio.wav。",
        segment: avatarSegment
      }
    ];
  } else if (avatarBindingSources.has("globals.sourceVideoUrl") && !options.sourceVideoUrl) {
    avatarJobs = [
      {
        segmentIndex: 1,
        workflowKey: avatarWorkflowKey,
        error: "缺少 --source-video-url。当前 avatar workflow 需要原视频作为驱动视频。",
        segment: avatarSegment
      }
    ];
  } else {
    const fps = Math.max(1, Math.round(videoMeta.video?.fps || 30));

    for (const [candidateIndex, entry] of speakerImageEntries.entries()) {
      const jobsForCandidate = buildJobsFromPlan({
        plan: {
          title: "fixed_bg avatar render",
          hook: "",
          summary: "",
          script: transcriptText,
          segments: [
            {
              ...avatarSegment,
              index: candidateIndex + 1,
              notes: `${avatarSegment.notes} | candidate=${entry.label}`
            }
          ]
        },
        workflowRegistry,
        globals: {
          ...buildGlobals(options),
          speakerImageUrl: entry.url
        }
      });

      avatarJobs.push(
        ...jobsForCandidate.map((job) => {
          const nextJob = {
            ...job,
            candidateIndex: candidateIndex + 1,
            candidateLabel: entry.label,
            candidateImageUrl: entry.url
          };

          if (avatarWorkflowKey === "liveportrait_img2vid") {
            nextJob.request = {
              ...nextJob.request,
              overrides: {
                ...nextJob.request.overrides,
                "168": {
                  inputs: {
                    ...(nextJob.request.overrides?.["168"]?.inputs || {}),
                    frame_rate: fps
                  }
                }
              }
            };
          }

          return nextJob;
        })
      );
    }
  }
  await writeJson(path.join(outputDir, "avatar-jobs.json"), avatarJobs);

  let backgroundJobs = [];
  if (!options.sourceVideoUrl) {
    backgroundJobs = [
      {
        segmentIndex: 1,
        workflowKey: backgroundWorkflowKeys.join(","),
        error: "缺少 --source-video-url，无法生成 background job。",
        segment: {
          index: 1,
          durationSec: Math.max(6, Math.ceil(videoMeta.durationSec || 6)),
          segmentType: "background_cleanup",
          notes: "fixed_bg 模式：背景分离/重建"
        }
      }
    ];
  } else {
    const backgroundPlan = {
      title: "fixed_bg background cleanup",
      hook: "",
      summary: "",
      script: transcriptText,
      segments: backgroundWorkflowKeys.map((workflowKey, index) => ({
        index: index + 1,
        durationSec: Math.max(6, Math.ceil(videoMeta.durationSec || 6)),
        segmentType: workflowKey === "matanyone" ? "background_matting" : "background_fill",
        voiceover: transcriptText,
        visualPrompt:
          workflowKey === "matanyone"
            ? "分离前景人物与背景，保留时序稳定的人物 alpha/matte"
            : "清除原视频里的大块文字和主播残留，尽量重建干净背景板",
        runcomfyWorkflow: workflowKey,
        notes: "fixed_bg 模式：背景处理"
      }))
    };
    backgroundJobs = buildJobsFromPlan({
      plan: backgroundPlan,
      workflowRegistry,
      globals: buildGlobals(options)
    });
  }
  await writeJson(path.join(outputDir, "background-jobs.json"), backgroundJobs);

  const composePlan = {
    mode: "fixed_bg",
    inputVideo: path.resolve(process.cwd(), input),
    sourceVideoUrl: options.sourceVideoUrl || "",
    backgroundPlatePath,
    backgroundPlateQuality: "rough_local_preview",
    recommendedBackgroundWorkflows: ["matanyone", "diffueraser_bgfill"],
    sourceAudioPath: audioPath,
    sourceAudioUrl: options.sourceAudioUrl || "",
    transcriptPath: path.join(outputDir, "transcript.json"),
    speakerImageUrl: speakerImageEntries[0]?.url || options.speakerImageUrl || "",
    speakerImageCandidates: speakerImageEntries,
    avatarSelectionMode: speakerImageEntries.length > 1 ? "multi_candidate_batch" : "single_candidate",
    avatarWorkflowKey,
    avatarJobsPath: path.join(outputDir, "avatar-jobs.json"),
    backgroundWorkflowKeys,
    backgroundJobsPath: path.join(outputDir, "background-jobs.json"),
    nextStep:
      speakerImageEntries.length > 0 &&
      options.sourceVideoUrl &&
      (!avatarBindingSources.has("globals.sourceAudioUrl") || options.sourceAudioUrl)
        ? "提交 avatar-jobs.json 和 background-jobs.json 给 RunComfy，先比较多张人物候选结果，再决定最终合成。"
        : "先补齐当前 workflow 需要的公网素材 URL，再提交 avatar-jobs.json 和 background-jobs.json。"
  };
  await writeJson(path.join(outputDir, "compose-plan.json"), composePlan);

  console.log(
    [
      `输出目录: ${outputDir}`,
      `模式: fixed_bg`,
      `视频时长: ${formatDuration(videoMeta.durationSec)}`,
      `背景板: ${backgroundPlatePath}`,
      "已生成: video-meta.json / audio.wav / transcript.json / background-meta.json / avatar-jobs.json / background-jobs.json / compose-plan.json"
    ].join("\n")
  );
}

async function handleUploadAssets(config, options, positionals) {
  const assets = collectAssets(options, positionals);
  if (assets.length === 0) {
    throw new Error("upload-assets 至少需要 --video、--image 或位置参数文件路径。");
  }

  const outputDir = path.resolve(process.cwd(), options.outputDir || path.join("output", "uploads"));
  await ensureDir(outputDir);
  const uploaded = await uploadAssets({
    config,
    assets,
    prefix: options.prefix || ""
  });

  const outputPath = path.join(outputDir, "uploaded-assets.json");
  await writeJson(outputPath, uploaded);

  const lines = [
    `上传结果已写入: ${outputPath}`,
    ...uploaded.items.map((item) => `${item.role || "asset"}: ${item.url}`)
  ];

  if (uploaded.sourceVideoUrl || uploaded.speakerImageUrl || uploaded.sourceAudioUrl) {
    const nextArgs = [];
    if (options.video) {
      nextArgs.push(`--input "${options.video}"`);
    }
    if (uploaded.speakerImageUrl) {
      nextArgs.push(`--speaker-image-url "${uploaded.speakerImageUrl}"`);
    }
    if (uploaded.sourceVideoUrl) {
      nextArgs.push(`--source-video-url "${uploaded.sourceVideoUrl}"`);
    }
    if (uploaded.sourceAudioUrl) {
      nextArgs.push(`--source-audio-url "${uploaded.sourceAudioUrl}"`);
    }
    if (nextArgs.length > 0) {
      lines.push(`下一步可执行: npm run pipeline -- ${nextArgs.join(" ")}`);
    }
  }

  console.log(lines.join("\n"));
}

async function handleFetchDeployment(config, options) {
  assertRunComfyKey(config);
  const deploymentId = requireOption(options.deploymentId || options.id, "--deployment-id");
  const deployment = await getDeployment({
    config,
    deploymentId,
    includePayload: true
  });

  const outputDir = await prepareOutputDir(options.outputDir, deploymentId);
  await writeJson(path.join(outputDir, "deployment.json"), deployment);

  const workflowApiJson = deployment.payload?.workflow_api_json;
  if (workflowApiJson) {
    await writeJson(path.join(outputDir, "workflow_api.json"), workflowApiJson);
  }

  console.log(
    [
      `deployment 已保存: ${path.join(outputDir, "deployment.json")}`,
      workflowApiJson
        ? `workflow_api 已保存: ${path.join(outputDir, "workflow_api.json")}`
        : "deployment 返回里没有 workflow_api_json，请检查 token 权限或 deployment 配置。"
    ].join("\n")
  );
}

async function handleCreateDeployment(config, options) {
  assertRunComfyKey(config);
  const body = {
    name: requireOption(options.name, "--name"),
    workflow_id: requireOption(options.workflowId, "--workflow-id"),
    workflow_version: requireOption(options.workflowVersion, "--workflow-version"),
    hardware: [options.hardware || "AMPERE_24"],
    min_instances: Number(options.minInstances || 0),
    max_instances: Number(options.maxInstances || 1),
    queue_size: Number(options.queueSize || 1),
    keep_warm_duration_in_seconds: Number(options.keepWarm || 60)
  };

  const deployment = await createDeployment({ config, body });
  const outputDir = await prepareOutputDir(options.outputDir, deployment.id);
  await writeJson(path.join(outputDir, "deployment.json"), deployment);
  console.log(JSON.stringify(deployment, null, 2));
}

async function handleListDeployments(config, options) {
  assertRunComfyKey(config);
  const deployments = await listDeployments({
    config,
    includePayload: Boolean(options.includePayload)
  });

  const slim = Array.isArray(deployments)
    ? deployments.map((item) => ({
        id: item.id,
        name: item.name,
        workflow_id: item.workflow_id,
        workflow_version: item.workflow_version,
        hardware: item.hardware,
        status: item.status,
        is_enabled: item.is_enabled,
        updated_at: item.updated_at
      }))
    : deployments;

  const outputDir = await prepareOutputDir(options.outputDir, "deployments");
  await writeJson(path.join(outputDir, "deployments.json"), deployments);
  console.log(JSON.stringify(slim, null, 2));
}

async function handleUpdateDeployment(config, options) {
  assertRunComfyKey(config);
  const deploymentId = requireOption(options.deploymentId || options.id, "--deployment-id");
  const body = {};

  if (options.name) {
    body.name = options.name;
  }
  if (options.workflowVersion) {
    body.workflow_version = options.workflowVersion;
  }
  if (options.hardware) {
    body.hardware = [options.hardware];
  }
  if (options.minInstances !== undefined) {
    body.min_instances = Number(options.minInstances);
  }
  if (options.maxInstances !== undefined) {
    body.max_instances = Number(options.maxInstances);
  }
  if (options.queueSize !== undefined) {
    body.queue_size = Number(options.queueSize);
  }
  if (options.keepWarm !== undefined) {
    body.keep_warm_duration_in_seconds = Number(options.keepWarm);
  }
  if (options.enabled !== undefined) {
    body.is_enabled = `${options.enabled}` === "true";
  }

  if (Object.keys(body).length === 0) {
    throw new Error("update-deployment 至少需要一个可更新字段。");
  }

  if (!body.name) {
    const current = await getDeployment({
      config,
      deploymentId,
      includePayload: false
    });
    body.name = current.name;
  }

  const deployment = await updateDeployment({
    config,
    deploymentId,
    body
  });

  const outputDir = await prepareOutputDir(options.outputDir, deploymentId);
  await writeJson(path.join(outputDir, "deployment.json"), deployment);
  console.log(JSON.stringify(deployment, null, 2));
}

async function loadTranscriptText(options) {
  if (options.transcriptFile) {
    const transcriptPath = path.resolve(process.cwd(), options.transcriptFile);
    if (transcriptPath.toLowerCase().endsWith(".json")) {
      const transcript = await readJson(transcriptPath);
      if (typeof transcript?.text === "string") {
        return transcript.text;
      }
    }
    return fs.readFile(transcriptPath, "utf8");
  }
  if (options.transcriptText) {
    return options.transcriptText;
  }
  throw new Error("需要 --transcript-file 或 --transcript-text。");
}

async function loadTranscriptSegments(options) {
  if (!options.transcriptFile) {
    return [];
  }

  const transcriptPath = path.resolve(process.cwd(), options.transcriptFile);
  if (!transcriptPath.toLowerCase().endsWith(".json")) {
    return [];
  }

  const transcript = await readJson(transcriptPath);
  return Array.isArray(transcript?.segments) ? transcript.segments : [];
}

function parseBoxSpecs(value) {
  return String(value || "")
    .split(/[;|]/)
    .map((item) => item.trim())
    .filter(Boolean)
    .map((item) => {
      const [x, y, width, height] = item.split(":").map(Number);
      if (![x, y, width, height].every(Number.isFinite)) {
        throw new Error(`非法 blur box: ${item}，格式应为 x:y:w:h`);
      }
      return { x, y, width, height };
    });
}

async function prepareOutputDir(outputDir, input) {
  const baseName = slugify(path.parse(input).name || input);
  const dir = path.resolve(process.cwd(), outputDir || path.join("output", baseName));
  await ensureDir(dir);
  return dir;
}

function buildGlobals(options) {
  return {
    sourceVideoUrl: options.sourceVideoUrl || "",
    sourceAudioUrl: options.sourceAudioUrl || "",
    speakerImageUrl: options.speakerImageUrl || "",
    generatedVideoUrl: options.generatedVideoUrl || "",
    defaultAudioUrl: options.audioUrl || ""
  };
}

function buildAvatarPrompt({ avatarWorkflowKey, transcriptText, overridePrompt }) {
  if (overridePrompt) {
    return overridePrompt;
  }

  if (avatarWorkflowKey === "dreamid_omni" || avatarWorkflowKey === "dreamid_omni_fast") {
    const speech = String(transcriptText || "")
      .replace(/\s+/g, " ")
      .replace(/[<>]/g, "")
      .trim();

    return [
      "<img1>: A young Chinese woman identified as <sub1>.",
      "**Overall Environment/Scene**: Vertical talking-head shot, clean neutral backdrop for later compositing, fixed camera, centered chest-up framing.",
      "**Main Characters/Subjects Appearance**: <sub1> keeps the same identity, hairstyle, face shape, makeup, and clothing style as the reference image.",
      "**Main Characters/Subjects Actions**: <sub1> looks straight at the camera, keeps the head stable, only slight natural blinking and subtle mouth motion while speaking, no exaggerated nodding, no body sway, no on-screen text.",
      `<sub1> looks at the camera and says, <S>${speech || "请介绍本期内容。"}<E>`
    ].join("\n");
  }

  return "固定机位中文口播，单人讲解，上半身为主，眼神稳定，自然手势，背景由后期单独合成，不要生成大段屏幕文字。";
}

async function collectSpeakerImageEntries(options, outputDir) {
  const candidates = [];

  if (options.speakerImageUrl) {
    candidates.push({
      url: String(options.speakerImageUrl).trim()
    });
  }

  for (const value of splitListOption(options.speakerImageUrls || "")) {
    candidates.push({ url: value });
  }

  if (options.speakerImagesFile) {
    const filePath = path.resolve(process.cwd(), options.speakerImagesFile);
    const raw = await fs.readFile(filePath, "utf8");
    if (filePath.toLowerCase().endsWith(".json")) {
      const payload = JSON.parse(raw);
      const items = Array.isArray(payload) ? payload : payload.items || [];
      for (const item of items) {
        if (typeof item === "string") {
          candidates.push({ url: item.trim() });
        } else if (item && typeof item === "object" && item.url) {
          candidates.push({
            url: String(item.url).trim(),
            label: item.label ? String(item.label).trim() : ""
          });
        }
      }
    } else {
      for (const value of splitListOption(raw)) {
        candidates.push({ url: value });
      }
    }
  }

  for (const localPath of splitListOption(options.speakerImageFiles || "")) {
    const resolvedPath = path.resolve(process.cwd(), localPath);
    let preparedPath = resolvedPath;
    const sheetMode = `${options.speakerSheetMode || "none"}`.trim().toLowerCase();
    if (sheetMode !== "none") {
      const preparedDir = path.join(outputDir, "prepared-speakers");
      const preparedName = `${slugify(path.parse(localPath).name)}-${sheetMode}.png`;
      preparedPath = await prepareSpeakerImage({
        inputPath: resolvedPath,
        outputPath: path.join(preparedDir, preparedName),
        sheetMode
      });
    }

    candidates.push({
      url: await localImageFileToDataUri(preparedPath),
      label: createSpeakerImageLabel(localPath, candidates.length),
      sourcePath: resolvedPath,
      preparedPath
    });
  }

  const seen = new Set();
  return candidates
    .map((item, index) => ({
      url: item.url,
      label: item.label || createSpeakerImageLabel(item.url, index),
      sourcePath: item.sourcePath || "",
      preparedPath: item.preparedPath || ""
    }))
    .filter((item) => {
      if (!item.url) {
        return false;
      }
      const key = item.url.trim();
      if (!key || seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    });
}

function splitListOption(value) {
  return String(value || "")
    .split(/[\r\n,]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

async function localImageFileToDataUri(filePath) {
  const absolutePath = path.resolve(process.cwd(), filePath);
  const buffer = await fs.readFile(absolutePath);
  const ext = path.extname(absolutePath).toLowerCase();
  const mimeType =
    ext === ".png"
      ? "image/png"
      : ext === ".jpg" || ext === ".jpeg"
        ? "image/jpeg"
        : ext === ".webp"
          ? "image/webp"
          : "application/octet-stream";
  return `data:${mimeType};base64,${buffer.toString("base64")}`;
}

function createSpeakerImageLabel(value, index) {
  try {
    const parsed = new URL(value);
    const base = decodeURIComponent(path.basename(parsed.pathname)).replace(/\.[^.]+$/u, "");
    return slugify(base || `speaker-${index + 1}`);
  } catch {
    const base = String(value).split(/[\\/]/).pop() || `speaker-${index + 1}`;
    return slugify(base.replace(/\.[^.]+$/u, "")) || `speaker-${index + 1}`;
  }
}

function collectAssets(options, positionals) {
  const assets = [];

  if (options.video) {
    assets.push({
      role: "sourceVideoUrl",
      localPath: options.video
    });
  }

  if (options.image) {
    assets.push({
      role: "speakerImageUrl",
      localPath: options.image
    });
  }

  if (options.audio) {
    assets.push({
      role: "sourceAudioUrl",
      localPath: options.audio
    });
  }

  for (const localPath of positionals) {
    assets.push({
      role: "asset",
      localPath
    });
  }

  return assets;
}

function requireOption(value, flag) {
  if (!value) {
    throw new Error(`缺少参数 ${flag}`);
  }
  return value;
}

function assertRunComfyKey(config) {
  if (!config.runComfyApiKey) {
    throw new Error("RUNCOMFY_API_KEY 未配置。");
  }
}

function canTranscribe(config) {
  const provider = (config.transcribeProvider || "").toLowerCase();
  if (provider === "openai") {
    return Boolean(config.openAiApiKey);
  }
  if (provider === "faster-whisper") {
    return Boolean(config.fasterWhisperPython);
  }
  return false;
}

function normalizePipelineMode(mode) {
  return `${mode || "direct_swap"}`.trim().toLowerCase();
}

function printHelp() {
  console.log(`用法:
  npm run inspect -- --input .\\光伏.mp4
  node src/cli.js prepare-driving-video --input .\\光伏.mp4 --crop-bottom-px 180
  node src/cli.js prepare-background --input .\\光伏.mp4 --sample-count 12
  node src/cli.js prepare-driving-video --input .\\光伏.mp4 --blur-boxes "90:70:540:220;70:610:580:180;0:1060:720:160"
  npm run upload-assets -- --video .\\光伏.mp4 --image .\\美女图.png --audio output\\guangfu\\audio.wav
  npm run pipeline -- --mode direct_swap --input .\\光伏.mp4 --speaker-image-url https://... --source-video-url https://...
  npm run pipeline -- --mode fixed_bg --input .\\光伏.mp4 --speaker-image-url https://... --source-audio-url https://...
  npm run pipeline -- --mode fixed_bg --input .\\光伏.mp4 --speaker-image-urls https://.../美女1.png,https://.../美女2.png --source-video-url https://...
  npm run pipeline -- --mode fixed_bg --input .\\光伏.mp4 --speaker-image-files .\\美女1.png,.\\美女2.png --speaker-sheet-mode triptych_center --source-video-url https://...
  npm run rewrite -- --input .\\光伏.mp4 --transcript-file output\\guangfu\\transcript.txt
  npm run build-jobs -- --plan output\\guangfu\\rewrite-plan.json --speaker-image-url https://... --source-video-url https://...
  npm run submit -- --jobs output\\guangfu\\runcomfy-jobs.json
  npm run poll -- --jobs output\\guangfu\\submitted-jobs.json
  node src/cli.js watch --jobs output\\guangfu\\avatar-jobs.submitted.json,output\\guangfu\\background-jobs.submitted.json --interval-sec 30
  node src/cli.js create-deployment --name wan-22-animate-api --workflow-id <uuid> --workflow-version v1 --hardware AMPERE_24
  npm run runcomfy:fetch-deployment -- --deployment-id <uuid>
  npm run list-deployments
  node src/cli.js update-deployment --deployment-id <uuid> --enabled true
  npm run estimate -- --gpu 24gb --minutes 2 --runtime 20`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
