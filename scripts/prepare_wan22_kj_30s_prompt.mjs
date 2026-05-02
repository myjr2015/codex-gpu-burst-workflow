import fs from "node:fs/promises";
import path from "node:path";
import { convertCanvasWorkflow } from "./convert_comfy_canvas_to_api.mjs";

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

const defaultNegativePrompt =
  "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走";

function patchPrompt(prompt, {
  imageName,
  videoName,
  positivePrompt,
  negativePrompt,
  outputPrefix,
  frameLoadCap,
  attentionMode,
  seed,
  outputWidth,
  outputHeight,
  backgroundImageName,
  backgroundRepeatAmount,
  maskGrow,
}) {
  const prepared = JSON.parse(JSON.stringify(prompt));

  delete prepared["137"];
  delete prepared["143"];
  delete prepared["148"];
  delete prepared["157"];
  delete prepared["158"];
  delete prepared["159"];
  delete prepared["165"];
  delete prepared["166"];
  delete prepared["170"];
  delete prepared["174"];
  delete prepared["180"];
  delete prepared["183"];

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
      continue;
    }

    if (node.class_type === "LoadImage") {
      node.inputs.image = imageName;
      node.inputs.upload = "image";
    }

    if (node.class_type === "VHS_LoadVideo") {
      node.inputs.video = videoName;
      node.inputs.force_rate = 16;
      node.inputs.force_size = "Disabled";
      node.inputs.custom_width = outputWidth;
      node.inputs.custom_height = outputHeight;
      if (Number.isInteger(frameLoadCap) && frameLoadCap > 0) {
        node.inputs.frame_load_cap = frameLoadCap;
      }
      node.inputs.skip_first_frames = 0;
      node.inputs.select_every_nth = 1;
      node.inputs.format = "Wan";
    }

    if (node.class_type === "PrimitiveStringMultiline") {
      node.inputs.value = positivePrompt;
    }

    if (node.class_type === "WanVideoTextEncodeCached") {
      node.inputs.model_name = "umt5-xxl-enc-fp8_e4m3fn.safetensors";
      node.inputs.precision = "bf16";
      node.inputs.positive_prompt = positivePrompt;
      node.inputs.negative_prompt = negativePrompt || defaultNegativePrompt;
      node.inputs.quantization = "disabled";
      node.inputs.use_disk_cache = false;
      node.inputs.device = "gpu";
    }

    if (nodeId === "140" && node.class_type === "WanVideoModelLoader") {
      node.inputs.base_precision = "fp16";
      node.inputs.attention_mode = attentionMode || "sdpa";
      delete node.inputs.compile_args;
    }

    if (nodeId === "154" && node.class_type === "LayerUtility: ImageScaleByAspectRatio V2") {
      node.inputs.scale_to_side = "width";
      node.inputs.scale_to_length = outputWidth;
    }

    if (nodeId === "172" && node.class_type === "WanVideoContextOptions") {
      node.inputs.context_frames = 241;
    }

    if (nodeId === "168" && node.class_type === "WanVideoSampler") {
      node.inputs.steps = 6;
      node.inputs.cfg = 1;
      node.inputs.shift = 3;
      node.inputs.seed = Number.isFinite(seed) ? seed : 387956277078883;
      node.inputs.force_offload = true;
      node.inputs.scheduler = "dpm++_sde";
      node.inputs.riflex_freq_index = 0;
      node.inputs.denoise_strength = 1;
      node.inputs.batched_cfg = false;
      node.inputs.rope_function = "comfy";
      node.inputs.start_step = 0;
      node.inputs.end_step = -1;
      node.inputs.add_noise_to_samples = false;
    }

    if (node.class_type === "VHS_VideoCombine") {
      node.inputs.filename_prefix = outputPrefix;
      if (nodeId === "156") {
        node.inputs.save_output = true;
      } else {
        node.inputs.save_output = false;
      }
    }
  }

  if (backgroundImageName) {
    for (const b2NodeId of ["901", "902", "903", "904", "905"]) {
      if (prepared[b2NodeId]) {
        throw new Error(`B2 runtime node id ${b2NodeId} already exists in converted workflow`);
      }
    }

    const repeatAmount = Number.isInteger(backgroundRepeatAmount) && backgroundRepeatAmount > 0
      ? backgroundRepeatAmount
      : frameLoadCap;
    if (!Number.isInteger(repeatAmount) || repeatAmount < 1) {
      throw new Error("backgroundRepeatAmount must be a positive integer when backgroundImageName is set");
    }

    prepared["901"] = {
      inputs: {
        image: backgroundImageName,
        upload: "image",
      },
      class_type: "LoadImage",
      _meta: {
        title: "LoadImage B2 background anchor",
      },
    };
    prepared["902"] = {
      inputs: {
        image: ["901", 0],
        amount: repeatAmount,
      },
      class_type: "RepeatImageBatch",
      _meta: {
        title: "RepeatImageBatch B2 background anchor",
      },
    };
    prepared["903"] = {
      inputs: {
        image: imageName,
        channel: "alpha",
      },
      class_type: "LoadImageMask",
      _meta: {
        title: "LoadImageMask B2 IP alpha",
      },
    };
    prepared["904"] = {
      inputs: {
        mask: ["903", 0],
      },
      class_type: "InvertMask",
      _meta: {
        title: "InvertMask B2 person area",
      },
    };

    let finalMaskLink = ["904", 0];
    const growPixels = Number.isInteger(maskGrow) ? maskGrow : 12;
    if (growPixels !== 0) {
      prepared["905"] = {
        inputs: {
          mask: ["904", 0],
          expand: growPixels,
          tapered_corners: true,
        },
        class_type: "GrowMask",
        _meta: {
          title: "GrowMask B2 person protection",
        },
      };
      finalMaskLink = ["905", 0];
    }

    const animateNode = prepared["171"];
    if (!animateNode || animateNode.class_type !== "WanVideoAnimateEmbeds") {
      throw new Error("missing WanVideoAnimateEmbeds node 171 for B2 background conditioning");
    }
    animateNode.inputs.bg_images = ["902", 0];
    animateNode.inputs.mask = finalMaskLink;
  }

  return prepared;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.input || !options.output || !options["image-name"] || !options["video-name"] || !options.prompt) {
    throw new Error("Usage: node scripts/prepare_wan22_kj_30s_prompt.mjs --input <canvas.json> --output <workflow_api.json> --image-name <name> --video-name <name> --prompt <text> [--negative-prompt <text>] [--seed <number>] [--output-prefix <prefix>] [--frame-load-cap <frames>] [--output-width <720>] [--output-height <1280>] [--attention-mode <sdpa|sageattn|comfy>] [--background-image-name <name>] [--background-repeat-amount <frames>] [--mask-grow <pixels>]");
  }

  const inputPath = path.resolve(process.cwd(), options.input);
  const outputPath = path.resolve(process.cwd(), options.output);
  const outputWidth = options["output-width"] ? Number.parseInt(options["output-width"], 10) : 720;
  const outputHeight = options["output-height"] ? Number.parseInt(options["output-height"], 10) : 1280;
  if (!Number.isInteger(outputWidth) || outputWidth < 64 || outputWidth % 8 !== 0) {
    throw new Error(`--output-width must be an integer >= 64 and divisible by 8, got ${JSON.stringify(options["output-width"])}`);
  }
  if (!Number.isInteger(outputHeight) || outputHeight < 64 || outputHeight % 8 !== 0) {
    throw new Error(`--output-height must be an integer >= 64 and divisible by 8, got ${JSON.stringify(options["output-height"])}`);
  }
  const workflow = JSON.parse(await fs.readFile(inputPath, "utf8"));
  const converted = convertCanvasWorkflow(workflow);
  const patched = patchPrompt(converted, {
    imageName: options["image-name"],
    videoName: options["video-name"],
    positivePrompt: options.prompt,
    negativePrompt: options["negative-prompt"],
    outputPrefix: options["output-prefix"] || "wan22-kj-30s",
    frameLoadCap: options["frame-load-cap"] ? Number.parseInt(options["frame-load-cap"], 10) : undefined,
    attentionMode: options["attention-mode"] || "sdpa",
    seed: options.seed ? Number.parseInt(options.seed, 10) : undefined,
    outputWidth,
    outputHeight,
    backgroundImageName: options["background-image-name"],
    backgroundRepeatAmount: options["background-repeat-amount"] ? Number.parseInt(options["background-repeat-amount"], 10) : undefined,
    maskGrow: options["mask-grow"] ? Number.parseInt(options["mask-grow"], 10) : undefined,
  });

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(patched, null, 2)}\n`, "utf8");
  console.log(`prepared ${outputPath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
