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

function patchPrompt(prompt, { imageName, videoName, outputPrefix }) {
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
  });

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(patched, null, 2)}\n`, "utf8");
  console.log(`prepared ${outputPath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
