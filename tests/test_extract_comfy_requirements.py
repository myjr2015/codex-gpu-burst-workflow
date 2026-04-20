import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "extract_comfy_requirements.py"
WORKFLOW_PATH = ROOT / "output" / "vast-clean-anchor-multitalk-24g" / "workflow_api_24g_pruned.json"
NODE_BUNDLES_PATH = ROOT / "output" / "vast-node-bundles" / "src"


def load_module():
    spec = importlib.util.spec_from_file_location("extract_comfy_requirements", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ExtractComfyRequirementsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()
        cls.workflow = json.loads(WORKFLOW_PATH.read_text(encoding="utf-8"))

    def test_summarize_workflow_collects_models_assets_and_packages(self):
        summary = self.module.summarize_workflow_requirements(self.workflow, NODE_BUNDLES_PATH)

        self.assertIn("wan_2.1_vae.safetensors", summary["models"])
        self.assertIn("Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors", summary["models"])
        self.assertIn("WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors", summary["models"])
        self.assertIn("TencentGameMate/chinese-wav2vec2-base", summary["models"])

        self.assertIn("clean-anchor-image.png", summary["input_assets"])
        self.assertIn("clean-anchor-audio.wav", summary["input_assets"])

        self.assertIn("ComfyUI-WanVideoWrapper", summary["custom_node_packages"])
        self.assertIn("ComfyUI-VideoHelperSuite", summary["custom_node_packages"])

    def test_summary_includes_python_dependencies_from_local_bundle_metadata(self):
        summary = self.module.summarize_workflow_requirements(self.workflow, NODE_BUNDLES_PATH)
        deps = summary["python_dependencies"]

        self.assertIn("accelerate>=1.2.1", deps["ComfyUI-WanVideoWrapper"])
        self.assertNotIn("accelerate >= 1.2.1", deps["ComfyUI-WanVideoWrapper"])
        self.assertIn("opencv-python", deps["ComfyUI-VideoHelperSuite"])
        self.assertIn("imageio-ffmpeg", deps["ComfyUI-VideoHelperSuite"])


if __name__ == "__main__":
    unittest.main()
