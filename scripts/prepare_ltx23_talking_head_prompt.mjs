import fs from "node:fs/promises";
import path from "node:path";
import { convertCanvasWorkflow } from "./convert_comfy_canvas_to_api.mjs";

const DEFAULT_POSITIVE_PROMPT = [
  "A woman is speaking naturally to the camera.",
  "Stable face identity, natural lip sync, clean photovoltaic technology background.",
  "Clean camera frame, natural professional lighting, no on-screen graphics.",
].join(" ");

const DEFAULT_NEGATIVE_PROMPT = [
  "subtitles, captions, Chinese subtitles, pseudo Chinese text, fake Chinese characters",
  "karaoke lyrics, transcribed words, bottom text, lower third captions, text overlay",
  "watermark, logo, news ticker, speech bubble, comic text, blurry, out of focus",
  "flickering, motion blur, deformed face, distorted mouth, mismatched lip sync",
  "extra limbs, extra fingers, disfigured hands, duplicated person, bad anatomy",
  "cartoon, CGI, uncanny, low quality, noisy, artifacts",
].join(", ");

const FRONTEND_ONLY_NODE_TYPES = new Set([
  "MarkdownNote",
  "PrimitiveBoolean",
  "PrimitiveFloat",
  "PrimitiveInt",
  "PrimitiveStringMultiline",
  "ComfyMathExpression",
]);

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }

    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      options[key] = true;
      continue;
    }

    options[key] = next;
    index += 1;
  }
  return options;
}

function toInteger(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function toNumber(value, fallback) {
  const parsed = Number.parseFloat(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : fallback;
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function getTitle(node) {
  return String(node?._meta?.title || "");
}

function findNodes(prompt, classType) {
  return Object.entries(prompt).filter(([, node]) => node?.class_type === classType);
}

function allocateNodeId(prompt) {
  const numericIds = Object.keys(prompt)
    .map((nodeId) => Number.parseInt(nodeId, 10))
    .filter((nodeId) => Number.isFinite(nodeId));
  return String((numericIds.length ? Math.max(...numericIds) : 0) + 1);
}

function replaceReferences(prompt, sourceNodeId, replacement) {
  for (const node of Object.values(prompt)) {
    if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
      continue;
    }
    for (const [inputName, inputValue] of Object.entries(node.inputs)) {
      if (
        Array.isArray(inputValue) &&
        inputValue.length === 2 &&
        String(inputValue[0]) === String(sourceNodeId)
      ) {
        node.inputs[inputName] = cloneJson(replacement);
      }
    }
  }
}

function replaceOutputReferences(prompt, sourceNodeId, sourceSlot, replacement) {
  for (const node of Object.values(prompt)) {
    if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
      continue;
    }
    for (const [inputName, inputValue] of Object.entries(node.inputs)) {
      if (
        Array.isArray(inputValue) &&
        inputValue.length === 2 &&
        String(inputValue[0]) === String(sourceNodeId) &&
        Number(inputValue[1]) === Number(sourceSlot)
      ) {
        node.inputs[inputName] = cloneJson(replacement);
      }
    }
  }
}

function replaceModelReferences(prompt, sourceNodeId, replacement, skipNodeIds = new Set()) {
  for (const [nodeId, node] of Object.entries(prompt)) {
    if (skipNodeIds.has(String(nodeId))) {
      continue;
    }
    if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
      continue;
    }
    for (const [inputName, inputValue] of Object.entries(node.inputs)) {
      if (
        inputName === "model" &&
        Array.isArray(inputValue) &&
        inputValue.length === 2 &&
        String(inputValue[0]) === String(sourceNodeId)
      ) {
        node.inputs[inputName] = cloneJson(replacement);
      }
    }
  }
}

function findFirstNode(prompt, classType) {
  return findNodes(prompt, classType)[0] || null;
}

function patchFirst(prompt, classType, callback) {
  const entry = findNodes(prompt, classType)[0];
  if (!entry) {
    throw new Error(`Missing required node class: ${classType}`);
  }
  callback(entry[1], entry[0]);
}

function createNode(prompt, classType, inputs, title = classType) {
  const nodeId = allocateNodeId(prompt);
  prompt[nodeId] = {
    inputs,
    class_type: classType,
    _meta: {
      title,
    },
  };
  return nodeId;
}

function removeNagNodes(prompt) {
  for (const [nodeId, node] of findNodes(prompt, "LTX2_NAG")) {
    if (node.inputs?.model) {
      replaceReferences(prompt, nodeId, node.inputs.model);
    }
    delete prompt[nodeId];
  }
}

function ensureLtxNag(prompt) {
  const conditioning = findNodes(prompt, "LTXVConditioning")[0];
  const loraModel = findNodes(prompt, "LoraLoaderModelOnly")[0];
  if (!conditioning || !loraModel) {
    return false;
  }

  const [conditioningId] = conditioning;
  const [loraModelId] = loraModel;
  let nagId = findNodes(prompt, "LTX2_NAG")[0]?.[0] || null;
  if (!nagId) {
    nagId = allocateNodeId(prompt);
    prompt[nagId] = {
      inputs: {
        model: [loraModelId, 0],
        nag_cond_video: [conditioningId, 1],
        nag_cond_audio: [conditioningId, 1],
        nag_scale: 15,
        nag_alpha: 0.4,
        nag_tau: 4,
        inplace: true,
      },
      class_type: "LTX2_NAG",
      _meta: {
        title: "LTX2_NAG",
      },
    };
  } else {
    const node = prompt[nagId];
    node.inputs.model = [loraModelId, 0];
    node.inputs.nag_cond_video = [conditioningId, 1];
    node.inputs.nag_cond_audio = [conditioningId, 1];
    node.inputs.nag_scale = 15;
    node.inputs.nag_alpha = 0.4;
    node.inputs.nag_tau = 4;
    node.inputs.inplace = true;
  }

  replaceModelReferences(prompt, loraModelId, [nagId, 0], new Set([String(nagId)]));
  return true;
}

function patchConditioningText(prompt, positivePrompt, negativePrompt) {
  let positivePatched = 0;
  let negativePatched = 0;

  for (const [, node] of findNodes(prompt, "LTXVConditioning")) {
    for (const [inputName, text] of [
      ["positive", positivePrompt],
      ["negative", negativePrompt],
    ]) {
      const inputValue = node.inputs?.[inputName];
      if (!Array.isArray(inputValue) || inputValue.length !== 2) {
        continue;
      }
      const textNode = prompt[String(inputValue[0])];
      if (!textNode || textNode.class_type !== "CLIPTextEncode") {
        continue;
      }
      textNode.inputs.text = text;
      if (inputName === "positive") {
        positivePatched += 1;
      } else {
        negativePatched += 1;
      }
    }
  }

  if (positivePatched > 0 && negativePatched > 0) {
    return { positivePatched, negativePatched };
  }

  for (const [, node] of findNodes(prompt, "CLIPTextEncode")) {
    const currentText = node.inputs.text;
    if (Array.isArray(currentText)) {
      node.inputs.text = positivePrompt;
      positivePatched += 1;
      continue;
    }
    const text = String(currentText || "");
    if (
      text.toLowerCase().includes("subtitles") ||
      text.toLowerCase().includes("watermark") ||
      text.toLowerCase().includes("pc game") ||
      text.toLowerCase().includes("cartoon")
    ) {
      node.inputs.text = negativePrompt;
      negativePatched += 1;
    } else if (!text.trim()) {
      node.inputs.text = positivePrompt;
      positivePatched += 1;
    }
  }

  return { positivePatched, negativePatched };
}

function patchVideoOutput(prompt, outputPrefix, fps) {
  const saveVideo = findFirstNode(prompt, "SaveVideo");
  if (saveVideo) {
    const [, node] = saveVideo;
    node.inputs.filename_prefix = outputPrefix;
    node.inputs.format = "auto";
    node.inputs.codec = "auto";
    return "SaveVideo";
  }

  const vhsVideo = findFirstNode(prompt, "VHS_VideoCombine");
  if (!vhsVideo) {
    throw new Error("Missing required output node class: SaveVideo or VHS_VideoCombine");
  }

  const [vhsNodeId, vhsNode] = vhsVideo;
  const imagesInput = vhsNode.inputs?.images;
  const audioInput = vhsNode.inputs?.audio;
  if (!imagesInput) {
    throw new Error("VHS_VideoCombine is missing images input.");
  }

  const createVideoInputs = {
    images: cloneJson(imagesInput),
    fps: cloneJson(vhsNode.inputs?.frame_rate ?? fps),
  };
  if (audioInput) {
    createVideoInputs.audio = cloneJson(audioInput);
  }
  const createVideoId = createNode(prompt, "CreateVideo", createVideoInputs);

  prompt[vhsNodeId] = {
    inputs: {
      video: [createVideoId, 0],
      filename_prefix: outputPrefix,
      format: "auto",
      codec: "auto",
    },
    class_type: "SaveVideo",
    _meta: {
      title: "SaveVideo",
    },
  };

  return "VHS_VideoCombine->CreateVideo+SaveVideo";
}

function bypassKnownOptionalNodes(prompt, loadImageId, loadAudioId, preserveAudioCleanup) {
  for (const [nodeId] of findNodes(prompt, "ImageResizeKJv2")) {
    replaceOutputReferences(prompt, nodeId, 0, [loadImageId, 0]);
    delete prompt[nodeId];
  }

  if (!preserveAudioCleanup) {
    for (const [nodeId] of findNodes(prompt, "NormalizeAudioLoudness")) {
      replaceOutputReferences(prompt, nodeId, 0, [loadAudioId, 0]);
      delete prompt[nodeId];
    }
    for (const [nodeId] of findNodes(prompt, "MelBandRoFormerSampler")) {
      replaceOutputReferences(prompt, nodeId, 0, [loadAudioId, 0]);
      delete prompt[nodeId];
    }
    for (const [nodeId] of findNodes(prompt, "MelBandRoFormerModelLoader")) {
      delete prompt[nodeId];
    }
  }
}

function patchPrompt(
  prompt,
  {
    imageName,
    audioName,
    outputPrefix,
    outputWidth,
    outputHeight,
    durationSeconds,
    fps,
    positivePrompt,
    negativePrompt,
    seed,
    enableNag,
    disableNag,
    preserveAudioCleanup,
  },
) {
  const prepared = cloneJson(prompt);
  const frameCount = Math.max(9, Math.floor((durationSeconds * fps) / 8) * 8 + 1);
  const baseWidth = Math.max(64, Math.round(outputWidth / 2));
  const baseHeight = Math.max(64, Math.round(outputHeight / 2));

  let loadImageId = null;
  patchFirst(prepared, "LoadImage", (node, nodeId) => {
    loadImageId = nodeId;
    node.inputs.image = imageName;
    node.inputs.upload = "image";
  });

  let loadAudioId = null;
  patchFirst(prepared, "LoadAudio", (node, nodeId) => {
    loadAudioId = nodeId;
    node.inputs.audio = audioName;
    delete node.inputs.audioUI;
    delete node.inputs.upload;
  });

  const outputContainer = patchVideoOutput(prepared, outputPrefix, fps);
  bypassKnownOptionalNodes(prepared, loadImageId, loadAudioId, preserveAudioCleanup);

  patchFirst(prepared, "EmptyLTXVLatentVideo", (node) => {
    node.inputs.width = baseWidth;
    node.inputs.height = baseHeight;
    node.inputs.length = frameCount;
    node.inputs.batch_size = 1;
  });

  for (const [, node] of findNodes(prepared, "SolidMask")) {
    node.inputs.width = baseWidth;
    node.inputs.height = baseHeight;
  }

  for (const [, node] of findNodes(prepared, "CreateVideo")) {
    node.inputs.fps = fps;
  }

  for (const [, node] of findNodes(prepared, "LTXVConditioning")) {
    node.inputs.frame_rate = fps;
  }

  for (const [, node] of findNodes(prepared, "TrimAudioDuration")) {
    node.inputs.start_index = 0;
    node.inputs.duration = durationSeconds;
  }

  for (const [, node] of findNodes(prepared, "LTXVImgToVideoInplace")) {
    node.inputs.bypass = false;
  }

  for (const [nodeId] of findNodes(prepared, "ResizeImageMaskNode")) {
    replaceReferences(prepared, nodeId, [loadImageId, 0]);
    delete prepared[nodeId];
  }

  for (const [, node] of findNodes(prepared, "ResizeImagesByLongerEdge")) {
    node.inputs.longer_edge = Math.max(outputWidth, outputHeight);
  }

  for (const [, node] of findNodes(prepared, "CheckpointLoaderSimple")) {
    node.inputs.ckpt_name = "ltx-2.3-22b-dev-fp8.safetensors";
  }

  for (const [, node] of findNodes(prepared, "LTXVAudioVAELoader")) {
    node.inputs.ckpt_name = "ltx-2.3-22b-dev-fp8.safetensors";
  }

  for (const [, node] of findNodes(prepared, "LTXAVTextEncoderLoader")) {
    node.inputs.text_encoder = "gemma_3_12B_it_fp4_mixed.safetensors";
    node.inputs.ckpt_name = "ltx-2.3-22b-dev-fp8.safetensors";
    node.inputs.device = "default";
  }

  for (const [, node] of findNodes(prepared, "LatentUpscaleModelLoader")) {
    node.inputs.model_name = "ltx-2.3-spatial-upscaler-x2-1.0.safetensors";
  }

  for (const [, node] of findNodes(prepared, "LoraLoaderModelOnly")) {
    node.inputs.lora_name = "ltx-2.3-22b-distilled-lora-384.safetensors";
    node.inputs.strength_model = 0.5;
  }

  if (disableNag) {
    removeNagNodes(prepared);
  } else if (enableNag) {
    ensureLtxNag(prepared);
  }
  const nagEnabled = findNodes(prepared, "LTX2_NAG").length > 0;

  const textPatch = patchConditioningText(prepared, positivePrompt, negativePrompt);

  if (Number.isSafeInteger(seed)) {
    for (const [, node] of findNodes(prepared, "RandomNoise")) {
      node.inputs.noise_seed = seed;
    }
  }

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!FRONTEND_ONLY_NODE_TYPES.has(node.class_type)) {
      continue;
    }
    replaceReferences(prepared, nodeId, null);
    delete prepared[nodeId];
  }

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
      continue;
    }
    for (const [inputName, inputValue] of Object.entries(node.inputs)) {
      if (
        Array.isArray(inputValue) &&
        inputValue.length === 2 &&
        !Object.hasOwn(prepared, String(inputValue[0]))
      ) {
        throw new Error(
          `Node ${nodeId} (${node.class_type}) input ${inputName} references missing node ${inputValue[0]}`,
        );
      }
    }
  }

  return {
    prompt: prepared,
    metadata: {
      output_width: outputWidth,
      output_height: outputHeight,
      base_width: baseWidth,
      base_height: baseHeight,
      requested_duration_seconds: durationSeconds,
      fps,
      frame_count: frameCount,
      expected_video_seconds: frameCount / fps,
      output_container: outputContainer,
      positive_prompt: positivePrompt,
      negative_prompt: negativePrompt,
      seed: Number.isSafeInteger(seed) ? seed : null,
      nag_enabled: nagEnabled,
      preserve_audio_cleanup: preserveAudioCleanup,
      patched_positive_text_nodes: textPatch.positivePatched,
      patched_negative_text_nodes: textPatch.negativePatched,
    },
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.input || !options.output || !options["image-name"] || !options["audio-name"]) {
    throw new Error(
      "Usage: node scripts/prepare_ltx23_talking_head_prompt.mjs --input <canvas.json> --output <workflow_api.json> --image-name <name> --audio-name <name> [--output-prefix <prefix>]",
    );
  }

  const inputPath = path.resolve(process.cwd(), options.input);
  const outputPath = path.resolve(process.cwd(), options.output);
  const workflow = JSON.parse(await fs.readFile(inputPath, "utf8"));
  const converted = convertCanvasWorkflow(workflow);
  const seed = options.seed ? toInteger(options.seed, Number.NaN) : Number.NaN;
  const result = patchPrompt(converted, {
    imageName: options["image-name"],
    audioName: options["audio-name"],
    outputPrefix: options["output-prefix"] || "ltx23_talking_head_smoke",
    outputWidth: toInteger(options["output-width"], 512),
    outputHeight: toInteger(options["output-height"], 896),
    durationSeconds: toNumber(options["duration-seconds"], 10),
    fps: toInteger(options.fps, 24),
    positivePrompt: options["positive-prompt"] || DEFAULT_POSITIVE_PROMPT,
    negativePrompt: options["negative-prompt"] || DEFAULT_NEGATIVE_PROMPT,
    seed: Number.isSafeInteger(seed) ? seed : null,
    enableNag: options["enable-nag"] === true,
    disableNag: options["disable-nag"] === true,
    preserveAudioCleanup: options["preserve-audio-cleanup"] === true,
  });

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(result.prompt, null, 2)}\n`, "utf8");

  const metadataPath = options["metadata-output"]
    ? path.resolve(process.cwd(), options["metadata-output"])
    : path.join(path.dirname(outputPath), "workflow_runtime.metadata.json");
  await fs.writeFile(metadataPath, `${JSON.stringify(result.metadata, null, 2)}\n`, "utf8");

  console.log(`prepared ${outputPath}`);
  console.log(`metadata ${metadataPath}`);
  console.log(`frame_count=${result.metadata.frame_count}`);
  console.log(`expected_video_seconds=${result.metadata.expected_video_seconds.toFixed(3)}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
