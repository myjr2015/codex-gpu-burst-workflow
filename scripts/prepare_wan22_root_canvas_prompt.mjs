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

function splitList(value) {
  if (!value) {
    return [];
  }
  return String(value)
    .split("|")
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function getNextNodeId(prepared) {
  const numericIds = Object.keys(prepared)
    .map((key) => Number.parseInt(key, 10))
    .filter((value) => Number.isInteger(value));
  return (numericIds.length ? Math.max(...numericIds) : 0) + 1;
}

function createContinuationBatch(prepared, imageNames) {
  if (!imageNames.length) {
    return null;
  }

  let nextNodeId = getNextNodeId(prepared);
  let currentRef = null;

  for (const imageName of imageNames) {
    const loadId = String(nextNodeId);
    nextNodeId += 1;
    prepared[loadId] = {
      inputs: {
        image: imageName,
        upload: "image",
      },
      class_type: "LoadImage",
      _meta: {
        title: "LoadImage",
      },
    };

    const loadRef = [loadId, 0];
    if (!currentRef) {
      currentRef = loadRef;
      continue;
    }

    const batchId = String(nextNodeId);
    nextNodeId += 1;
    prepared[batchId] = {
      inputs: {
        image1: currentRef,
        image2: loadRef,
      },
      class_type: "ImageBatch",
      _meta: {
        title: "ImageBatch",
      },
    };
    currentRef = [batchId, 0];
  }

  return currentRef;
}

function patchPrompt(
  prompt,
  {
    imageName,
    videoName,
    outputPrefix,
    frameLoadCap,
    continueMotionImages,
    continueMotionMaxFrames,
    videoFrameOffset,
  },
) {
  const prepared = JSON.parse(JSON.stringify(prompt));

  function replaceReferences(sourceNodeId, replacement) {
    for (const node of Object.values(prepared)) {
      if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
        continue;
      }
      for (const [inputName, inputValue] of Object.entries(node.inputs)) {
        if (
          Array.isArray(inputValue) &&
          inputValue.length === 2 &&
          String(inputValue[0]) === String(sourceNodeId)
        ) {
          node.inputs[inputName] = replacement;
        }
      }
    }
  }

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!node || typeof node !== "object") {
      continue;
    }

    const { class_type: classType, inputs } = node;
    if (!inputs || typeof inputs !== "object") {
      continue;
    }

    if (classType === "LoadImage") {
      inputs.image = imageName;
    }

    if (classType === "VHS_LoadVideo") {
      inputs.video = videoName;
      if (Number.isInteger(frameLoadCap) && frameLoadCap > 0) {
        inputs.frame_load_cap = frameLoadCap;
      }
    }

    if (classType === "VHS_VideoCombine") {
      if (!inputs.images) {
        delete prepared[nodeId];
        continue;
      }
      inputs.filename_prefix = outputPrefix;
    }

    if (classType === "PathchSageAttentionKJ") {
      inputs.sage_attention = "disabled";
    }

    if (classType === "WanAnimateToVideo") {
      if (Number.isInteger(videoFrameOffset) && videoFrameOffset >= 0) {
        inputs.video_frame_offset = videoFrameOffset;
      }
    }
  }

  for (const [nodeId, node] of Object.entries(prepared)) {
    if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
      continue;
    }
    if (node.class_type === "TorchCompileModelWanVideoV2" && Array.isArray(node.inputs.model)) {
      replaceReferences(nodeId, node.inputs.model);
      delete prepared[nodeId];
    }
  }

  const continuationRef = createContinuationBatch(prepared, continueMotionImages);
  if (continuationRef) {
    for (const node of Object.values(prepared)) {
      if (!node || typeof node !== "object" || !node.inputs || typeof node.inputs !== "object") {
        continue;
      }
      if (node.class_type !== "WanAnimateToVideo") {
        continue;
      }
      node.inputs.continue_motion = continuationRef;
      if (Number.isInteger(continueMotionMaxFrames) && continueMotionMaxFrames > 0) {
        node.inputs.continue_motion_max_frames = continueMotionMaxFrames;
      }
    }
  }

  return prepared;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.input || !options.output || !options["image-name"] || !options["video-name"]) {
    throw new Error("Usage: node scripts/prepare_wan22_root_canvas_prompt.mjs --input <canvas.json> --output <workflow_api.json> --image-name <name> --video-name <name> [--output-prefix <prefix>]");
  }

  const inputPath = path.resolve(process.cwd(), options.input);
  const outputPath = path.resolve(process.cwd(), options.output);
  const workflow = JSON.parse(await fs.readFile(inputPath, "utf8"));
  const converted = convertCanvasWorkflow(workflow);
  const patched = patchPrompt(converted, {
    imageName: options["image-name"],
    videoName: options["video-name"],
    outputPrefix: options["output-prefix"] || "wan22-root-canvas",
    frameLoadCap: options["frame-load-cap"] ? Number.parseInt(options["frame-load-cap"], 10) : undefined,
    continueMotionImages: splitList(options["continue-motion-images"]),
    continueMotionMaxFrames: options["continue-motion-max-frames"]
      ? Number.parseInt(options["continue-motion-max-frames"], 10)
      : undefined,
    videoFrameOffset: options["video-frame-offset"]
      ? Number.parseInt(options["video-frame-offset"], 10)
      : undefined,
  });

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(patched, null, 2)}\n`, "utf8");
  console.log(`prepared ${outputPath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
