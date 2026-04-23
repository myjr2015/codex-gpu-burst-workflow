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
    throw new Error("Usage: node scripts/generate_001skills_onstart.mjs --manifest <manifest.json> --output <onstart.sh>");
  }

  const manifestPath = path.resolve(process.cwd(), options.manifest);
  const outputPath = path.resolve(process.cwd(), options.output);
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const r2 = manifest.r2;
  const publicBase = String(r2.public_base_url || "").replace(/\/+$/, "");
  const prefix = String(r2.prefix || "").replace(/^\/+|\/+$/g, "");
  const localBundleDir = manifest?.local?.node_bundles ? path.resolve(String(manifest.local.node_bundles)) : null;

  if (!publicBase || !prefix) {
    throw new Error("Manifest missing r2.public_base_url or r2.prefix");
  }
  if (!localBundleDir) {
    throw new Error("Manifest missing local.node_bundles");
  }

  const bundleNames = (await fs.readdir(localBundleDir))
    .filter((name) => name.toLowerCase().endsWith(".zip"))
    .sort((left, right) => left.localeCompare(right));

  const files = {
    workflowRuntime: `${prefix}/workflow_runtime.json`,
    bootstrap: `${prefix}/bootstrap_wan22_root_canvas.sh`,
    remoteSubmit: `${prefix}/remote_submit_wan22_root_canvas.sh`,
    inputVideo: `${prefix}/input/光伏2.mp4`,
    inputImage: `${prefix}/input/美女带背景.png`,
  };

  const url = (key) => `${publicBase}/${encodePath(key)}`;
  const bundleFetchLines = bundleNames
    .map((name) => `fetch "${url(`${prefix}/node-bundles/${name}`)}" "$BUNDLE_DIR/${name}"`)
    .join("\n");

  const script = `#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="/workspace/ComfyUI"
RUN_DIR="/workspace/wan22-root-canvas-run"
BUNDLE_DIR="$RUN_DIR/node-bundles"
mkdir -p "$RUN_DIR" "$BUNDLE_DIR" "$COMFY_ROOT/input"
exec > >(tee -a "$RUN_DIR/onstart.log") 2>&1

fetch() {
  local url="$1"
  local target="$2"
  mkdir -p "$(dirname "$target")"
  echo "[onstart] fetch $url -> $target"
  curl --http1.1 --fail --location --silent --show-error \
    --retry 10 --retry-delay 8 --retry-all-errors \
    --connect-timeout 30 --max-time 1800 \
    -o "$target" "$url"
}

echo "[onstart] started at $(date -Iseconds)"
fetch "${url(files.workflowRuntime)}" "$RUN_DIR/workflow_runtime.json"
fetch "${url(files.bootstrap)}" "$RUN_DIR/bootstrap_wan22_root_canvas.sh"
fetch "${url(files.remoteSubmit)}" "$RUN_DIR/remote_submit_wan22_root_canvas.sh"
fetch "${url(files.inputVideo)}" "$COMFY_ROOT/input/光伏2.mp4"
fetch "${url(files.inputImage)}" "$COMFY_ROOT/input/美女带背景.png"
${bundleFetchLines}

chmod +x "$RUN_DIR/bootstrap_wan22_root_canvas.sh" "$RUN_DIR/remote_submit_wan22_root_canvas.sh"
INPUT_VIDEO_NAME="光伏2.mp4" INPUT_IMAGE_NAME="美女带背景.png" bash "$RUN_DIR/remote_submit_wan22_root_canvas.sh"
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
