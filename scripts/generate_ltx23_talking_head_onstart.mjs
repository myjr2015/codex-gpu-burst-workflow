import fs from "node:fs/promises";
import path from "node:path";

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) continue;
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

function encodePath(input) {
  return input
    .split("/")
    .map((part) => encodeURIComponent(part))
    .join("/");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.manifest || !options.output) {
    throw new Error("Usage: node scripts/generate_ltx23_talking_head_onstart.mjs --manifest <manifest.json> --output <onstart.sh>");
  }

  const manifestPath = path.resolve(process.cwd(), options.manifest);
  const outputPath = path.resolve(process.cwd(), options.output);
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const r2 = manifest.r2;
  const publicBase = String(r2.public_base_url || "").replace(/\/+$/, "");
  const prefix = String(r2.prefix || "").replace(/^\/+|\/+$/g, "");
  const inputImageName = manifest?.workflow?.input_image_name || "speaker.png";
  const inputAudioName = manifest?.workflow?.input_audio_name || "speech.wav";
  const inputReferenceVideoName = manifest?.workflow?.input_reference_video_name || "";

  if (!publicBase || !prefix) {
    throw new Error("Manifest missing r2.public_base_url or r2.prefix");
  }

  const files = {
    workflowRuntime: `${prefix}/workflow_runtime.json`,
    bootstrap: `${prefix}/bootstrap_ltx23_talking_head.sh`,
    remoteSubmit: `${prefix}/remote_submit_ltx23_talking_head.sh`,
    inputImage: `${prefix}/input/${inputImageName}`,
    inputAudio: `${prefix}/input/${inputAudioName}`,
  };
  if (inputReferenceVideoName) {
    files.inputReferenceVideo = `${prefix}/input/${inputReferenceVideoName}`;
  }

  const url = (key) => `${publicBase}/${encodePath(key)}`;

  const script = `#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="/workspace/ComfyUI"
RUN_DIR="/workspace/ltx23-talking-head-run"
mkdir -p "$RUN_DIR" "$COMFY_ROOT/input"
exec > >(tee -a "$RUN_DIR/onstart.log") 2>&1

fetch() {
  local url="$1"
  local target="$2"
  mkdir -p "$(dirname "$target")"
  echo "[onstart-ltx23] fetch $url -> $target"
  curl --http1.1 --fail --location --silent --show-error \
    --retry 10 --retry-delay 8 --retry-all-errors \
    --connect-timeout 30 --max-time 1800 \
    -o "$target" "$url"
}

echo "[onstart-ltx23] started at $(date -Iseconds)"
fetch "${url(files.workflowRuntime)}" "$RUN_DIR/workflow_runtime.json"
fetch "${url(files.bootstrap)}" "$RUN_DIR/bootstrap_ltx23_talking_head.sh"
fetch "${url(files.remoteSubmit)}" "$RUN_DIR/remote_submit_ltx23_talking_head.sh"
fetch "${url(files.inputImage)}" "$COMFY_ROOT/input/${inputImageName}"
fetch "${url(files.inputAudio)}" "$COMFY_ROOT/input/${inputAudioName}"
${inputReferenceVideoName ? `fetch "${url(files.inputReferenceVideo)}" "$COMFY_ROOT/input/${inputReferenceVideoName}"` : ""}

chmod +x "$RUN_DIR/bootstrap_ltx23_talking_head.sh" "$RUN_DIR/remote_submit_ltx23_talking_head.sh"
INPUT_IMAGE_NAME="${inputImageName}" INPUT_AUDIO_NAME="${inputAudioName}" INPUT_REFERENCE_VIDEO_NAME="${inputReferenceVideoName}" bash "$RUN_DIR/remote_submit_ltx23_talking_head.sh"
echo "[onstart-ltx23] finished at $(date -Iseconds)"
`;

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, script, "utf8");
  console.log(outputPath);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
