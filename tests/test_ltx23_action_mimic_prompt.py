import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "prepare_ltx23_action_mimic_prompt.mjs"
WORKFLOW = ROOT / "workflows" / "LTX2.3动作模仿+音频对口型-V3候选.json"


class Ltx23ActionMimicPromptTests(unittest.TestCase):
    def test_background_prompt_is_composed_into_action_mimic_positive_prompt(self):
        background_prompt = "bright daytime rooftop photovoltaic installation"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            runtime_path = temp_path / "workflow_runtime.json"
            metadata_path = temp_path / "workflow_runtime.metadata.json"

            subprocess.run(
                [
                    "node",
                    str(SCRIPT),
                    "--input",
                    str(WORKFLOW),
                    "--output",
                    str(runtime_path),
                    "--metadata-output",
                    str(metadata_path),
                    "--image-name",
                    "speaker.png",
                    "--audio-name",
                    "speech.wav",
                    "--reference-video-name",
                    "reference_video.mp4",
                    "--background-prompt",
                    background_prompt,
                    "--camera-prompt",
                    "stable front-facing vertical camera",
                    "--prompt-guardrails",
                    "single person only",
                    "--dwpose-detect-body",
                    "disable",
                    "--dwpose-detect-hand",
                    "enable",
                    "--dwpose-detect-face",
                    "enable",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            runtime = json.loads(runtime_path.read_text(encoding="utf-8"))

        self.assertEqual(metadata["positive_prompt_source"], "action_mimic_composed_prompt")
        self.assertEqual(metadata["background_prompt"], background_prompt)
        self.assertIn(background_prompt, metadata["positive_prompt"])
        self.assertIn("stable front-facing vertical camera", metadata["positive_prompt"])
        self.assertEqual(metadata["dwpose_detect_body"], "disable")
        self.assertEqual(metadata["dwpose_detect_hand"], "enable")
        self.assertEqual(metadata["dwpose_detect_face"], "enable")

        dwpose_nodes = [node for node in runtime.values() if node.get("class_type") == "DWPreprocessor"]
        self.assertGreaterEqual(len(dwpose_nodes), 1)
        self.assertTrue(all(node["inputs"]["detect_body"] == "disable" for node in dwpose_nodes))


if __name__ == "__main__":
    unittest.main()
