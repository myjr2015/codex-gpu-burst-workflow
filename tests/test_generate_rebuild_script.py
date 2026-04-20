import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "generate_comfy_rebuild_script.py"
MANIFEST_PATH = ROOT / "output" / "vast-clean-anchor-multitalk-24g" / "requirements_manifest.json"


def load_module():
    spec = importlib.util.spec_from_file_location("generate_comfy_rebuild_script", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GenerateRebuildScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()
        cls.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_build_script_contains_git_clone_pip_install_and_model_dirs(self):
        script_text = self.module.build_rebuild_script(self.manifest)

        self.assertIn("git clone https://github.com/kijai/ComfyUI-WanVideoWrapper", script_text)
        self.assertIn("git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite", script_text)
        self.assertIn('python3 -m pip install -r "$COMFY_ROOT/requirements.txt"', script_text)
        self.assertIn('python3 -m pip install "accelerate>=1.2.1"', script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/vae"', script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/text_encoders"', script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/diffusion_models"', script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/loras"', script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/controlnet"', script_text)
        self.assertIn('mkdir -p "$MODELS_DIR/transformers"', script_text)

    def test_write_script_persists_output_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "rebuild.sh"
            self.module.write_script(output_path, self.module.build_rebuild_script(self.manifest))
            text = output_path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith("#!/usr/bin/env bash"))


if __name__ == "__main__":
    unittest.main()
