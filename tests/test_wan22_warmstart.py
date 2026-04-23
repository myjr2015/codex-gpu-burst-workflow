import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(script_name: str):
    script_path = ROOT / "scripts" / script_name
    spec = importlib.util.spec_from_file_location(script_name.replace(".py", ""), script_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WarmStartStateTests(unittest.TestCase):
    def test_reports_ready_when_all_required_nodes_and_models_exist(self):
        module = load_module("inspect_wan22_warmstart.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            custom_nodes = root / "custom_nodes"
            models = root / "models"
            for node_name in (
                "ComfyUI-GGUF",
                "ComfyUI-KJNodes",
                "ComfyUI-VideoHelperSuite",
                "ComfyUI-WanAnimatePreprocess",
            ):
                (custom_nodes / node_name).mkdir(parents=True, exist_ok=True)

            required_models = (
                "unet/Wan2.2-Animate-14B-Q4_K_S.gguf",
                "text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
                "vae/wan_2.1_vae.safetensors",
                "clip_vision/clip_vision_h.safetensors",
                "loras/lightx2v_elite_it2v_animate_face.safetensors",
                "loras/FullDynamic_Ultimate_Fusion_Elite.safetensors",
                "loras/wan2.2_face_complete_distilled.safetensors",
                "loras/WanAnimate_relight_lora_fp16.safetensors",
                "detection/yolov10m.onnx",
                "detection/vitpose-l-wholebody.onnx",
            )
            for rel_path in required_models:
                path = models / rel_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"x")

            state = module.inspect_runtime_state(custom_nodes, models)
            self.assertTrue(state["custom_nodes_ready"])
            self.assertTrue(state["models_ready"])
            self.assertEqual(state["missing_custom_nodes"], [])
            self.assertEqual(state["missing_models"], [])

    def test_reports_missing_items_when_runtime_is_incomplete(self):
        module = load_module("inspect_wan22_warmstart.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            custom_nodes = root / "custom_nodes"
            models = root / "models"
            custom_nodes.mkdir(parents=True, exist_ok=True)
            models.mkdir(parents=True, exist_ok=True)

            state = module.inspect_runtime_state(custom_nodes, models)
            self.assertFalse(state["custom_nodes_ready"])
            self.assertFalse(state["models_ready"])
            self.assertIn("ComfyUI-GGUF", state["missing_custom_nodes"])
            self.assertIn("unet/Wan2.2-Animate-14B-Q4_K_S.gguf", state["missing_models"])


class LaunchExtraEnvTests(unittest.TestCase):
    def test_warm_start_switch_adds_only_warm_start_env(self):
        helper_path = ROOT / "scripts" / "launch_wan_2_2_animate_vast_job_helpers.ps1"
        command = (
            f". '{helper_path}'; "
            "$result = Get-Wan22AnimateLaunchExtraEnv -WarmStart:$true; "
            "ConvertTo-Json -InputObject ([object[]]@($result)) -Compress"
        )

        completed = subprocess.run(
            ["pwsh", "-NoProfile", "-Command", command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        extra_env = json.loads(completed.stdout.strip())
        self.assertEqual(extra_env, ["WARM_START=1"])


if __name__ == "__main__":
    unittest.main()
