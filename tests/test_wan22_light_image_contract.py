import ast
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCKER_DIR = ROOT / "docker" / "wan22-root-canvas"


class Wan22LightImageContractTests(unittest.TestCase):
    def test_custom_node_installer_contains_only_required_nodes(self):
        module_ast = ast.parse((DOCKER_DIR / "install_custom_nodes.py").read_text(encoding="utf-8"))
        repos = None
        for node in module_ast.body:
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id == "REPOS":
                        repos = ast.literal_eval(node.value)
                        break

        self.assertIsNotNone(repos)
        names = {entry["name"] for entry in repos}
        self.assertEqual(
            names,
            {
                "ComfyUI-GGUF",
                "ComfyUI-KJNodes",
                "ComfyUI-VideoHelperSuite",
                "ComfyUI-WanAnimatePreprocess",
            },
        )
        self.assertNotIn("ComfyUI-Easy-Use", names)
        self.assertNotIn("ComfyUI-WanVideoWrapper", names)
        self.assertNotIn("ComfyUI-segment-anything-2", names)

    def test_requirements_extra_does_not_reintroduce_heavy_unused_stacks(self):
        requirements = (DOCKER_DIR / "requirements-extra.txt").read_text(encoding="utf-8").lower()
        for forbidden in (
            "accelerate",
            "diffusers",
            "peft",
            "spandrel",
            "clip_interrogator",
            "clip-interrogator",
        ):
            self.assertNotIn(forbidden, requirements)

    def test_light_image_does_not_embed_model_downloads(self):
        dockerfile = (DOCKER_DIR / "Dockerfile").read_text(encoding="utf-8")
        forbidden_model_names = (
            "Wan2.2-Animate-14B-Q4_K_S.gguf",
            "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
            "wan_2.1_vae.safetensors",
            "clip_vision_h.safetensors",
        )
        for model_name in forbidden_model_names:
            self.assertNotIn(model_name, dockerfile)

    def test_light_image_installs_custom_nodes_into_app_root(self):
        dockerfile = (DOCKER_DIR / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn(
            "COMFY_ROOT=/opt/workspace-internal/ComfyUI python3 /tmp/wan22-root-canvas/install_custom_nodes.py",
            dockerfile,
        )

    def test_prewarmed_runtime_preserves_app_custom_nodes(self):
        remote_submit = (ROOT / "scripts" / "remote_submit_wan22_root_canvas.sh").read_text(encoding="utf-8")
        self.assertIn('if [ "${PREWARMED_IMAGE:-0}" = "1" ]; then', remote_submit)
        self.assertIn('mkdir -p "$COMFY_APP_ROOT/custom_nodes"', remote_submit)
        self.assertIn('ln -s "$COMFY_ROOT/custom_nodes" "$COMFY_APP_ROOT/custom_nodes"', remote_submit)

    def test_bootstrap_inspects_app_custom_nodes_for_prewarmed_image(self):
        bootstrap = (ROOT / "scripts" / "bootstrap_wan22_root_canvas.sh").read_text(encoding="utf-8")
        self.assertIn('if [ "$PREWARMED_IMAGE" = "1" ] && [ -d "$COMFY_APP_ROOT/custom_nodes" ]; then', bootstrap)
        self.assertIn('CUSTOM_NODES_DIR="$COMFY_APP_ROOT/custom_nodes"', bootstrap)

    def test_profile_pins_light_image_tag(self):
        config = json.loads((ROOT / "config" / "vast-workflow-profiles.json").read_text(encoding="utf-8"))
        image = config["profiles"]["001skills"]["light_image"]
        self.assertEqual(image, "j1c2k3/codex-comfy-wan22-root-canvas:1.2-light")


if __name__ == "__main__":
    unittest.main()
