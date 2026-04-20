#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
INPUT_DIR="$COMFY_ROOT/input"

echo "[1/4] Rebuilding ComfyUI environment under: $COMFY_ROOT"
bash "$SCRIPT_DIR/rebuild_comfy_env.sh"

echo "[2/4] Downloading Wan 2.1 workflow models"
bash "$SCRIPT_DIR/download_models.sh"

echo "[3/4] Ensuring input directory exists"
mkdir -p "$INPUT_DIR"

echo "[4/4] Copy these assets into $INPUT_DIR before running the workflow:"
echo "  - clean-anchor-image.png"
echo "  - clean-anchor-audio.wav"
echo
echo "Environment bootstrap complete."
echo "Next step: start ComfyUI and import workflow_api_24g_pruned.json"
