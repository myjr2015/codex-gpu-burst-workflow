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

function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.manifest || !options.output) {
    throw new Error("Usage: node scripts/generate_wan22_kj_30s_segmented_onstart.mjs --manifest <manifest.json> --output <onstart.sh>");
  }

  const manifestPath = path.resolve(process.cwd(), options.manifest);
  const outputPath = path.resolve(process.cwd(), options.output);
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const r2 = manifest.r2 || {};
  const publicBase = String(r2.public_base_url || "").replace(/\/+$/, "");
  const prefix = String(r2.prefix || "").replace(/^\/+|\/+$/g, "");
  const segments = Array.isArray(manifest.segments) ? manifest.segments : [];

  if (!publicBase || !prefix) {
    throw new Error("Manifest missing r2.public_base_url or r2.prefix");
  }
  if (segments.length < 1) {
    throw new Error("Manifest has no segments");
  }

  const url = (key) => `${publicBase}/${encodePath(key)}`;
  const fetchLines = [
    `fetch ${shQuote(url(`${prefix}/manifest.json`))} "$RUN_DIR/manifest.json"`,
    `fetch ${shQuote(url(`${prefix}/bootstrap_wan22_kj_30s.sh`))} "$RUN_DIR/bootstrap_wan22_kj_30s.sh"`,
    `fetch ${shQuote(url(`${prefix}/remote_submit_wan22_kj_30s.sh`))} "$RUN_DIR/remote_submit_wan22_kj_30s.sh"`,
    `fetch ${shQuote(url(`${prefix}/inspect_wan22_kj_30s_warmstart.py`))} "$RUN_DIR/inspect_wan22_kj_30s_warmstart.py"`,
    `fetch ${shQuote(url(`${prefix}/input/ip_image.png`))} "$COMFY_ROOT/input/ip_image.png"`,
  ];

  for (const segment of segments) {
    fetchLines.push(
      `fetch ${shQuote(url(`${prefix}/${segment.workflow_runtime_name}`))} "$RUN_DIR/${segment.workflow_runtime_name}"`,
      `fetch ${shQuote(url(`${prefix}/input/${segment.input_video_name}`))} "$COMFY_ROOT/input/${segment.input_video_name}"`,
    );
  }

  const segmentArray = segments.map((segment) => shQuote(segment.id)).join(" ");
  const segmentCase = segments
    .map(
      (segment) => `    ${shQuote(segment.id)})
      workflow_name=${shQuote(segment.workflow_runtime_name)}
      video_name=${shQuote(segment.input_video_name)}
      ;;`,
    )
    .join("\n");

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

stage_event() {
  local stage_name="$1"
  local stage_status="$2"
  echo "[stage] $(date -Iseconds) $stage_name $stage_status"
}

echo "[onstart] started at $(date -Iseconds)"
${fetchLines.join("\n")}

chmod +x "$RUN_DIR/bootstrap_wan22_kj_30s.sh" "$RUN_DIR/remote_submit_wan22_kj_30s.sh"

SEGMENTS=(${segmentArray})
SEGMENT_INDEX=0
for segment_id in "\${SEGMENTS[@]}"; do
  SEGMENT_INDEX=$((SEGMENT_INDEX + 1))
  workflow_name=""
  video_name=""
  case "$segment_id" in
${segmentCase}
    *)
      echo "[remote-kj30s-segmented] unknown segment id: $segment_id" >&2
      exit 1
      ;;
  esac

  echo "[remote-kj30s-segmented] segment_\${segment_id} start at $(date -Iseconds)"
  stage_event "remote.segment_\${segment_id}" "start"
  if [ "$SEGMENT_INDEX" -gt 1 ]; then
    export HF_SPEEDTEST=0
  fi
  INPUT_IMAGE_NAME="ip_image.png" \\
    INPUT_VIDEO_NAME="$video_name" \\
    WORKFLOW_PATH="$RUN_DIR/$workflow_name" \\
    bash "$RUN_DIR/remote_submit_wan22_kj_30s.sh"
  stage_event "remote.segment_\${segment_id}" "end"
  echo "[remote-kj30s-segmented] segment_\${segment_id} end at $(date -Iseconds)"
done

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
