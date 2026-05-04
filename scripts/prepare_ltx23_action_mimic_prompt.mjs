import fs from "node:fs/promises";
import path from "node:path";
import { convertCanvasWorkflow } from "./convert_comfy_canvas_to_api.mjs";

const DEFAULT_POSITIVE_PROMPT = [
  "A single woman speaks naturally to the camera in a clean photovoltaic technology scene.",
  "She follows the body pose and hand gesture rhythm from the reference video.",
  "Stable face identity, natural lip sync, realistic hands, seated or standing full-body framing as shown in the input image.",
  "Clean solar panels, no readable signs, no subtitles, no captions, no on-screen graphics.",
].join(" ");

const DEFAULT_NEGATIVE_PROMPT = [
  "subtitles, captions, Chinese subtitles, pseudo Chinese text, fake Chinese characters",
  "karaoke lyrics, transcribed words, bottom text, lower third captions, text overlay",
  "watermark, logo, news ticker, speech bubble, comic text",
  "duplicated person, two people, double body, extra limbs, extra hands, extra fingers",
  "deformed hands, bad anatomy, distorted mouth, mismatched lip sync",
  "flickering, blurry, low quality, noisy, artifacts, cropped body",
].join(", ");

const FRONTEND_OR_OPTIONAL_NODE_TYPES = new Set([
  "ComfyMathExpression",
  "GetImageSize",
  "PrimitiveBoolean",
  "PrimitiveFloat",
  "PrimitiveInt",
  "PrimitiveStringMultiline",
  "Qwen3ASRLoader",
  "Qwen3ASRTranscribe",
  "easy ifElse",
  "easy imageSizeBySide",
  "easy positive",
  "easy promptReplace",
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

function findNodes(prompt, classType) {
  return Object.entries(prompt).filter(([, node]) => node?.class_type === classType);
}

function findFirstNode(prompt, classType) {
  return findNodes(prompt, classType)[0] || null;
}

function patchFirst(prompt, classType, callback) {
  const entry = findFirstNode(prompt, classType);
  if (!entry) {
    throw new Error(`Missing required node class: ${classType}`);
  }
  callback(entry[1], entry[0]);
}

function allocateNodeId(prompt) {
  const numericIds = Object.keys(prompt)
    .map((nodeId) => Number.parseInt(nodeId, 10))
    .filter((nodeId) => Number.isFinite(nodeId));
  return String((numericIds.length ? Math.max(...numericIds) : 0) + 1);
}

function createNode(prompt, classType, inputs, title = classType) {
  const nodeId = allocateNodeId(prompt);
  prompt[nodeId] = {
    inputs,
    class_type: classType,
    _meta: { title },
  };
  return nodeId;
}

function replaceReferences(prompt, sourceNodeId, replacement) {
  for (const node of Object.values(prompt)) {
    if (!node?.inputs || typeof node.inputs !== "object") {
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
    if (!node?.inputs || typeof node.inputs !== "object") {
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
    if (skipNodeIds.has(String(nodeId)) || !node?.inputs || typeof node.inputs !== "object") {
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
    throw new Error("Missing output node class: SaveVideo or VHS_VideoCombine");
  }

  const [vhsNodeId, vhsNode] = vhsVideo;
  const imagesInput = vhsNode.inputs?.images;
  const audioInput = vhsNode.inputs?.audio;
  if (!imagesInput) {
    throw new Error("VHS_VideoCombine is missing images input.");
  }

  const createVideoInputs = {
    images: cloneJson(imagesInput),
    fps,
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
    _meta: { title: "SaveVideo" },
  };

  return "VHS_VideoCombine->CreateVideo+SaveVideo";
}

function patchText(prompt, positivePrompt, negativePrompt) {
  let positivePatched = 0;
  let negativePatched = 0;

  for (const [, node] of findNodes(prompt, "LTXVConditioning")) {
    const positiveInput = node.inputs?.positive;
    const negativeInput = node.inputs?.negative;
    if (Array.isArray(positiveInput)) {
      const textNode = prompt[String(positiveInput[0])];
      if (textNode?.class_type === "CLIPTextEncode") {
        textNode.inputs.text = positivePrompt;
        positivePatched += 1;
      }
    }
    if (Array.isArray(negativeInput)) {
      const textNode = prompt[String(negativeInput[0])];
      if (textNode?.class_type === "CLIPTextEncode") {
        textNode.inputs.text = negativePrompt;
        negativePatched += 1;
      }
    }
  }

  return { positivePatched, negativePatched };
}

function removeOptionalAudioCleanup(prompt, loadAudioId) {
  for (const [nodeId] of findNodes(prompt, "MelBandRoFormerSampler")) {
    replaceOutputReferences(prompt, nodeId, 0, [loadAudioId, 0]);
    delete prompt[nodeId];
  }
  for (const [nodeId] of findNodes(prompt, "MelBandRoFormerModelLoader")) {
    delete prompt[nodeId];
  }
  for (const [nodeId] of findNodes(prompt, "LTXVAudioVAEDecode")) {
    replaceOutputReferences(prompt, nodeId, 0, [loadAudioId, 0]);
    delete prompt[nodeId];
  }
}

function patchPrompt(
  prompt,
  {
    imageName,
    audioName,
    referenceVideoName,
    outputPrefix,
    outputWidth,
    outputHeight,
    durationSeconds,
    fps,
    positivePrompt,
    negativePrompt,
    seed,
    actionGuideStrength,
    actionLoraStrength,
    identityLoraStrength,
    identityGuidanceScale,
    dwposeResolution,
  },
) {
  const prepared = cloneJson(prompt);
  const frameCount = Math.max(9, Math.floor((durationSeconds * fps) / 8) * 8 + 1);

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

  let loadVideoId = null;
  patchFirst(prepared, "VHS_LoadVideo", (node, nodeId) => {
    loadVideoId = nodeId;
    node.inputs.video = referenceVideoName;
    node.inputs.force_rate = fps;
    node.inputs.force_size = "Disabled";
    node.inputs.custom_width = 0;
    node.inputs.custom_height = 0;
    node.inputs.frame_load_cap = frameCount;
    node.inputs.skip_first_frames = 0;
    node.inputs.select_every_nth = 1;
    node.inputs.format = "AnimateDiff";
  });

  removeOptionalAudioCleanup(prepared, loadAudioId);

  for (const [, node] of findNodes(prepared, "LTXVAudioVAEEncode")) {
    node.inputs.audio = [loadAudioId, 0];
  }
  const audioEncode = findFirstNode(prepared, "LTXVAudioVAEEncode");
  const audioMask = findFirstNode(prepared, "SetLatentNoiseMask");
  const audioLatentRef = audioMask ? [audioMask[0], 0] : audioEncode ? [audioEncode[0], 0] : null;
  if (audioEncode && audioMask) {
    audioMask[1].inputs.samples = [audioEncode[0], 0];
  }
  if (!audioLatentRef) {
    throw new Error("Missing audio latent chain for action mimic workflow.");
  }
  for (const [, node] of findNodes(prepared, "LTXVConcatAVLatent")) {
    node.inputs.audio_latent = cloneJson(audioLatentRef);
  }

  for (const [, node] of findNodes(prepared, "LTXVReferenceAudio")) {
    node.inputs.reference_audio = [loadAudioId, 0];
    node.inputs.identity_guidance_scale = identityGuidanceScale;
    node.inputs.start_percent = 0;
    node.inputs.end_percent = 1;
  }

  for (const [, node] of findNodes(prepared, "VHS_VideoCombine")) {
    node.inputs.audio = [loadAudioId, 0];
    node.inputs.frame_rate = fps;
    node.inputs.filename_prefix = outputPrefix;
  }

  const outputContainer = patchVideoOutput(prepared, outputPrefix, fps);

  for (const [, node] of findNodes(prepared, "EmptyLTXVLatentVideo")) {
    node.inputs.width = outputWidth;
    node.inputs.height = outputHeight;
    node.inputs.length = frameCount;
    node.inputs.batch_size = 1;
  }

  for (const [, node] of findNodes(prepared, "LTXVEmptyLatentAudio")) {
    node.inputs.frames_number = frameCount;
    node.inputs.frame_rate = fps;
    node.inputs.batch_size = 1;
  }

  for (const [, node] of findNodes(prepared, "SolidMask")) {
    node.inputs.width = outputWidth;
    node.inputs.height = outputHeight;
  }

  for (const [, node] of findNodes(prepared, "LTXVConditioning")) {
    node.inputs.frame_rate = fps;
  }

  for (const [, node] of findNodes(prepared, "CreateVideo")) {
    node.inputs.fps = fps;
  }

  for (const [, node] of findNodes(prepared, "DWPreprocessor")) {
    node.inputs.image = [loadVideoId, 0];
    node.inputs.detect_hand = "enable";
    node.inputs.detect_body = "enable";
    node.inputs.detect_face = "enable";
    node.inputs.resolution = dwposeResolution;
    node.inputs.bbox_detector = "yolox_l.torchscript.pt";
    node.inputs.pose_estimator = "dw-ll_ucoco_384_bs5.torchscript.pt";
    node.inputs.scale_stick_for_xinsr_cn = "disable";
  }

  for (const [, node] of findNodes(prepared, "ResizeImageMaskNode")) {
    if (node.inputs?.input) {
      node.inputs.resize_type = "scale to multiple";
      node.inputs.scale_method = "area";
      node.inputs["resize_type.multiple"] = 32;
    }
  }

  for (const [, node] of findNodes(prepared, "LTXAddVideoICLoRAGuide")) {
    node.inputs.frame_idx = 0;
    node.inputs.strength = actionGuideStrength;
    node.inputs.crop = "disabled";
    node.inputs.use_tiled_encode = false;
    node.inputs.tile_size = 256;
    node.inputs.tile_overlap = 64;
  }

  for (const [, node] of findNodes(prepared, "LTXICLoRALoaderModelOnly")) {
    node.inputs.lora_name = "ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors";
    node.inputs.strength_model = actionLoraStrength;
  }

  for (const [, node] of findNodes(prepared, "LoraLoaderModelOnly")) {
    node.inputs.lora_name = "ltx-2.3-id-lora-talkvid-3k.safetensors";
    node.inputs.strength_model = identityLoraStrength;
  }

  for (const [, node] of findNodes(prepared, "UNETLoader")) {
    node.inputs.unet_name = "ltx-2.3-22b-distilled_transformer_only_fp8_input_scaled_v3.safetensors";
    node.inputs.weight_dtype = "default";
  }

  for (const [, node] of findNodes(prepared, "DualCLIPLoader")) {
    node.inputs.clip_name1 = "gemma_3_12B_it_fp4_mixed.safetensors";
    node.inputs.clip_name2 = "ltx-2.3_text_projection_bf16.safetensors";
    node.inputs.type = "ltxv";
    node.inputs.device = "default";
  }

  for (const [, node] of findNodes(prepared, "VAELoaderKJ")) {
    const title = String(node._meta?.title || "").toLowerCase();
    const current = String(node.inputs.vae_name || "").toLowerCase();
    if (title.includes("audio") || current.includes("audio")) {
      node.inputs.vae_name = "LTX23_audio_vae_bf16.safetensors";
    } else {
      node.inputs.vae_name = "LTX23_video_vae_bf16.safetensors";
    }
    node.inputs.device = "main_device";
    node.inputs.weight_dtype = "bf16";
  }

  for (const [, node] of findNodes(prepared, "PathchSageAttentionKJ")) {
    node.inputs.sage_attention = "disabled";
    node.inputs.allow_compile = false;
  }

  for (const [, node] of findNodes(prepared, "ModelPatchTorchSettings")) {
    node.inputs.enable_fp16_accumulation = true;
  }

  const textPatch = patchText(prepared, positivePrompt, negativePrompt);

  if (Number.isSafeInteger(seed)) {
    for (const [, node] of findNodes(prepared, "RandomNoise")) {
      node.inputs.noise_seed = seed;
    }
  }

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!FRONTEND_OR_OPTIONAL_NODE_TYPES.has(node.class_type)) {
      continue;
    }
    replaceReferences(prepared, nodeId, null);
    delete prepared[nodeId];
  }

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!node?.inputs || typeof node.inputs !== "object") {
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

  const actionGuideCount = findNodes(prepared, "LTXAddVideoICLoRAGuide").length;
  if (actionGuideCount < 1) {
    throw new Error("Prepared workflow has no LTXAddVideoICLoRAGuide node.");
  }

  return {
    prompt: prepared,
    metadata: {
      mode: "action_mimic",
      output_width: outputWidth,
      output_height: outputHeight,
      requested_duration_seconds: durationSeconds,
      fps,
      frame_count: frameCount,
      expected_video_seconds: frameCount / fps,
      output_container: outputContainer,
      positive_prompt_source: "action_mimic_override",
      positive_prompt: positivePrompt,
      speaker_prompt: null,
      background_prompt: null,
      camera_prompt: null,
      prompt_guardrails: null,
      negative_prompt: negativePrompt,
      seed: Number.isSafeInteger(seed) ? seed : null,
      nag_enabled: false,
      motion_lora_enabled: false,
      motion_lora_name: null,
      motion_lora_strength: null,
      input_image_name: imageName,
      input_audio_name: audioName,
      input_reference_video_name: referenceVideoName,
      action_guide_strength: actionGuideStrength,
      action_lora_name: "ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors",
      action_lora_strength: actionLoraStrength,
      identity_lora_name: "ltx-2.3-id-lora-talkvid-3k.safetensors",
      identity_lora_strength: identityLoraStrength,
      identity_guidance_scale: identityGuidanceScale,
      dwpose_resolution: dwposeResolution,
      patched_positive_text_nodes: textPatch.positivePatched,
      patched_negative_text_nodes: textPatch.negativePatched,
      action_guide_node_count: actionGuideCount,
    },
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (
    !options.input ||
    !options.output ||
    !options["image-name"] ||
    !options["audio-name"] ||
    !options["reference-video-name"]
  ) {
    throw new Error(
      "Usage: node scripts/prepare_ltx23_action_mimic_prompt.mjs --input <canvas.json> --output <workflow_api.json> --image-name <name> --audio-name <name> --reference-video-name <name>",
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
    referenceVideoName: options["reference-video-name"],
    outputPrefix: options["output-prefix"] || "ltx23_talking_head_smoke",
    outputWidth: toInteger(options["output-width"], 512),
    outputHeight: toInteger(options["output-height"], 896),
    durationSeconds: toNumber(options["duration-seconds"], 10),
    fps: toInteger(options.fps, 24),
    positivePrompt: options["positive-prompt"] || DEFAULT_POSITIVE_PROMPT,
    negativePrompt: options["negative-prompt"] || DEFAULT_NEGATIVE_PROMPT,
    seed: Number.isSafeInteger(seed) ? seed : null,
    actionGuideStrength: toNumber(options["action-guide-strength"], 0.55),
    actionLoraStrength: toNumber(options["action-lora-strength"], 0.75),
    identityLoraStrength: toNumber(options["identity-lora-strength"], 0.75),
    identityGuidanceScale: toNumber(options["identity-guidance-scale"], 2.5),
    dwposeResolution: toInteger(options["dwpose-resolution"], 512),
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
  console.log(`action_guide_strength=${result.metadata.action_guide_strength}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
