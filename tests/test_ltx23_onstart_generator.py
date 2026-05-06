import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate_ltx23_talking_head_onstart.mjs"


class Ltx23OnstartGeneratorTests(unittest.TestCase):
    def test_onstart_pins_mode_and_motion_lora_from_manifest(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            manifest_path = temp_path / "manifest.json"
            output_path = temp_path / "onstart.sh"
            manifest = {
                "r2": {
                    "public_base_url": "https://example.invalid",
                    "prefix": "runcomfy-inputs/ltx23_talking_head_smoke/demo",
                },
                "workflow": {
                    "input_image_name": "speaker.png",
                    "input_audio_name": "speech.wav",
                    "input_reference_video_name": None,
                    "action_mimic_enabled": False,
                    "motion_lora_enabled": True,
                    "motion_lora_name": "Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors",
                },
            }
            manifest_path.write_text(
                json.dumps(manifest, ensure_ascii=False),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "node",
                    str(SCRIPT),
                    "--manifest",
                    str(manifest_path),
                    "--output",
                    str(output_path),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            text = output_path.read_text(encoding="utf-8")

        self.assertIn('LTX23_ENABLE_ACTION_MIMIC="0"', text)
        self.assertIn('LTX23_DOWNLOAD_VBVR="1"', text)
        self.assertIn(
            'LTX23_MOTION_LORA_NAME="Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors"',
            text,
        )


if __name__ == "__main__":
    unittest.main()
