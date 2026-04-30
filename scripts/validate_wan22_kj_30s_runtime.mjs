import fs from "node:fs/promises";
import path from "node:path";

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

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertArrayLink(value, nodeId, slot, message) {
  if (!Array.isArray(value) || value[0] !== nodeId || value[1] !== slot) {
    throw new Error(`${message}: expected [${JSON.stringify(nodeId)}, ${slot}], got ${JSON.stringify(value)}`);
  }
}

function requireNode(prompt, nodeId, classType) {
  const node = prompt[nodeId];
  if (!node) {
    throw new Error(`missing node ${nodeId}`);
  }
  if (node.class_type !== classType) {
    throw new Error(`node ${nodeId} class mismatch: expected ${classType}, got ${node.class_type}`);
  }
  return node;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.input) {
    throw new Error("Usage: node scripts/validate_wan22_kj_30s_runtime.mjs --input <workflow_runtime.json> [--image-name <name>] [--video-name <name>]");
  }

  const inputPath = path.resolve(process.cwd(), options.input);
  const prompt = JSON.parse(await fs.readFile(inputPath, "utf8"));
  const expectedImageName = options["image-name"] || "ip_image.png";
  const expectedVideoName = options["video-name"] || "reference_30s.mp4";

  const imageNode = requireNode(prompt, "163", "LoadImage");
  assertEqual(imageNode.inputs.image, expectedImageName, "LoadImage.image");
  assertEqual(imageNode.inputs.upload, "image", "LoadImage.upload");

  const videoNode = requireNode(prompt, "178", "VHS_LoadVideo");
  assertEqual(videoNode.inputs.video, expectedVideoName, "VHS_LoadVideo.video");
  assertEqual(videoNode.inputs.force_rate, 16, "VHS_LoadVideo.force_rate");
  assertEqual(videoNode.inputs.force_size, "Disabled", "VHS_LoadVideo.force_size");
  assertEqual(videoNode.inputs.custom_width, 0, "VHS_LoadVideo.custom_width");
  assertEqual(videoNode.inputs.custom_height, 0, "VHS_LoadVideo.custom_height");
  assertEqual(videoNode.inputs.skip_first_frames, 0, "VHS_LoadVideo.skip_first_frames");
  assertEqual(videoNode.inputs.select_every_nth, 1, "VHS_LoadVideo.select_every_nth");
  assertEqual(videoNode.inputs.format, "Wan", "VHS_LoadVideo.format");
  if (!Number.isInteger(videoNode.inputs.frame_load_cap) || videoNode.inputs.frame_load_cap < 1) {
    throw new Error(`VHS_LoadVideo.frame_load_cap invalid: ${JSON.stringify(videoNode.inputs.frame_load_cap)}`);
  }

  const textNode = requireNode(prompt, "152", "WanVideoTextEncodeCached");
  assertEqual(textNode.inputs.model_name, "umt5-xxl-enc-fp8_e4m3fn.safetensors", "WanVideoTextEncodeCached.model_name");
  assertEqual(textNode.inputs.precision, "bf16", "WanVideoTextEncodeCached.precision");
  assertEqual(textNode.inputs.quantization, "disabled", "WanVideoTextEncodeCached.quantization");
  assertEqual(textNode.inputs.use_disk_cache, false, "WanVideoTextEncodeCached.use_disk_cache");
  assertEqual(textNode.inputs.device, "gpu", "WanVideoTextEncodeCached.device");
  if (!String(textNode.inputs.positive_prompt || "").trim()) {
    throw new Error("WanVideoTextEncodeCached.positive_prompt is empty");
  }

  const modelNode = requireNode(prompt, "140", "WanVideoModelLoader");
  assertEqual(modelNode.inputs.model, "Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors", "WanVideoModelLoader.model");
  assertEqual(modelNode.inputs.base_precision, "fp16", "WanVideoModelLoader.base_precision");
  if (Object.hasOwn(modelNode.inputs, "compile_args")) {
    throw new Error("WanVideoModelLoader.compile_args should be removed for RTX 3090 KJ runtime");
  }
  if (!["sdpa", "sageattn", "comfy"].includes(modelNode.inputs.attention_mode)) {
    throw new Error(`WanVideoModelLoader.attention_mode invalid: ${JSON.stringify(modelNode.inputs.attention_mode)}`);
  }

  const samplerNode = requireNode(prompt, "168", "WanVideoSampler");
  assertEqual(samplerNode.inputs.steps, 6, "WanVideoSampler.steps");
  assertEqual(samplerNode.inputs.cfg, 1, "WanVideoSampler.cfg");
  assertEqual(samplerNode.inputs.shift, 3, "WanVideoSampler.shift");
  assertEqual(typeof samplerNode.inputs.seed, "number", "WanVideoSampler.seed type");
  assertEqual(samplerNode.inputs.force_offload, true, "WanVideoSampler.force_offload");
  assertEqual(samplerNode.inputs.scheduler, "dpm++_sde", "WanVideoSampler.scheduler");
  assertEqual(samplerNode.inputs.riflex_freq_index, 0, "WanVideoSampler.riflex_freq_index");
  assertEqual(samplerNode.inputs.denoise_strength, 1, "WanVideoSampler.denoise_strength");
  assertEqual(samplerNode.inputs.batched_cfg, false, "WanVideoSampler.batched_cfg");
  assertEqual(samplerNode.inputs.rope_function, "comfy", "WanVideoSampler.rope_function");
  assertEqual(samplerNode.inputs.start_step, 0, "WanVideoSampler.start_step");
  assertEqual(samplerNode.inputs.end_step, -1, "WanVideoSampler.end_step");
  assertEqual(samplerNode.inputs.add_noise_to_samples, false, "WanVideoSampler.add_noise_to_samples");

  const finalVideo = requireNode(prompt, "156", "VHS_VideoCombine");
  assertArrayLink(finalVideo.inputs.images, "153", 0, "VHS_VideoCombine[156].images");
  assertArrayLink(finalVideo.inputs.audio, "178", 2, "VHS_VideoCombine[156].audio");
  assertEqual(finalVideo.inputs.save_output, true, "VHS_VideoCombine[156].save_output");

  const saveOutputNodes = Object.entries(prompt)
    .filter(([, node]) => node?.class_type === "VHS_VideoCombine" && node?.inputs?.save_output === true)
    .map(([nodeId]) => nodeId);
  assertEqual(saveOutputNodes.length, 1, "save_output node count");
  assertEqual(saveOutputNodes[0], "156", "save_output node id");

  for (const removedNodeId of ["137", "143", "148", "157", "158", "159", "165", "166", "170", "174", "180", "183"]) {
    if (prompt[removedNodeId]) {
      throw new Error(`helper node ${removedNodeId} should be folded out of KJ runtime`);
    }
  }

  const scaledImageNode = requireNode(prompt, "154", "LayerUtility: ImageScaleByAspectRatio V2");
  assertEqual(scaledImageNode.inputs.scale_to_length, 720, "ImageScaleByAspectRatio.scale_to_length");
  const contextNode = requireNode(prompt, "172", "WanVideoContextOptions");
  assertEqual(contextNode.inputs.context_frames, 241, "WanVideoContextOptions.context_frames");

  console.log(`validated ${inputPath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
