import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "generate_model_download_script.py"
MANIFEST_PATH = ROOT / "output" / "vast-clean-anchor-multitalk-24g" / "requirements_manifest.json"


def load_module():
    spec = importlib.util.spec_from_file_location("generate_model_download_script", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GenerateModelDownloadScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()
        cls.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_script_contains_expected_download_commands(self):
        script_text = self.module.build_download_script(self.manifest)

        self.assertIn("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors", script_text)
        self.assertIn("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors", script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/loras"', script_text)
        self.assertIn('curl -L --fail -o "$MODELS_DIR/loras/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"', script_text)
        self.assertIn("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors", script_text)
        self.assertIn("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors", script_text)
        self.assertIn("huggingface-cli download TencentGameMate/chinese-wav2vec2-base", script_text)

    def test_write_script_persists_output_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "download_models.sh"
            self.module.write_script(output_path, self.module.build_download_script(self.manifest))
            text = output_path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith("#!/usr/bin/env bash"))


if __name__ == "__main__":
    unittest.main()
