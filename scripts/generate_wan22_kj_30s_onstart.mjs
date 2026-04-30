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
  return input.split("/").map((part) => encodeURIComponent(part)).join("/");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.manifest || !options.output) {
    throw new Error("Usage: node scripts/generate_wan22_kj_30s_onstart.mjs --manifest <manifest.json> --output <onstart.sh>");
  }

  const manifestPath = path.resolve(process.cwd(), options.manifest);
  const outputPath = path.resolve(process.cwd(), options.output);
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const r2 = manifest.r2 || {};
  const publicBase = String(r2.public_base_url || "").replace(/\/+$/, "");
  const prefix = String(r2.prefix || "").replace(/^\/+|\/+$/g, "");

  if (!publicBase || !prefix) {
    throw new Error("Manifest missing r2.public_base_url or r2.prefix");
  }

  const url = (key) => `${publicBase}/${encodePath(key)}`;
  const files = {
    workflowRuntime: `${prefix}/workflow_runtime.json`,
    bootstrap: `${prefix}/bootstrap_wan22_kj_30s.sh`,
    remoteSubmit: `${prefix}/remote_submit_wan22_kj_30s.sh`,
    warmstartInspector: `${prefix}/inspect_wan22_kj_30s_warmstart.py`,
    inputImage: `${prefix}/input/ip_image.png`,
    inputVideo: `${prefix}/input/reference_30s.mp4`,
  };

  const script = `#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="/workspace/ComfyUI"
RUN_DIR="/workspace/wan22-kj-30s-run"
mkdir -p "$RUN_DIR" "$COMFY_ROOT/input"
exec > >(tee -a "$RUN_DIR/onstart.log") 2>&1

fetch() {
  local url="$1"
  local target="$2"
  mkdir -p "$(dirname "$target")"
  echo "[onstart] fetch $url -> $target"
  curl --http1.1 --fail --location --silent --show-error \\
    --retry 10 --retry-delay 8 --retry-all-errors \\
    --connect-timeout 30 --max-time 7200 \\
    -o "$target" "$url"
}

echo "[onstart] started at $(date -Iseconds)"
fetch "${url(files.workflowRuntime)}" "$RUN_DIR/workflow_runtime.json"
fetch "${url(files.bootstrap)}" "$RUN_DIR/bootstrap_wan22_kj_30s.sh"
fetch "${url(files.remoteSubmit)}" "$RUN_DIR/remote_submit_wan22_kj_30s.sh"
fetch "${url(files.warmstartInspector)}" "$RUN_DIR/inspect_wan22_kj_30s_warmstart.py"
fetch "${url(files.inputImage)}" "$COMFY_ROOT/input/ip_image.png"
fetch "${url(files.inputVideo)}" "$COMFY_ROOT/input/reference_30s.mp4"

chmod +x "$RUN_DIR/bootstrap_wan22_kj_30s.sh" "$RUN_DIR/remote_submit_wan22_kj_30s.sh"
INPUT_IMAGE_NAME="ip_image.png" INPUT_VIDEO_NAME="reference_30s.mp4" bash "$RUN_DIR/remote_submit_wan22_kj_30s.sh"
echo "[onstart] finished at $(date -Iseconds)"
`;

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, script, "utf8");
  console.log(outputPath);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
