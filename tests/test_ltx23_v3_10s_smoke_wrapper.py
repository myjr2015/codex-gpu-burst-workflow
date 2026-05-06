import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_ltx23_v3_10s_smoke.ps1"


class Ltx23V3SmokeWrapperTests(unittest.TestCase):
    def test_script_parses_as_powershell(self):
        completed = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-Command",
                "$null = [scriptblock]::Create((Get-Content -Raw 'scripts/run_ltx23_v3_10s_smoke.ps1')); 'parse ok'",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("parse ok", completed.stdout)

    def test_paid_run_requires_explicit_switch_and_excludes_cn(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("[switch]$RunPaid", text)
        self.assertIn("if (-not $RunPaid)", text)
        self.assertIn("geolocation notin [CN]", text)
        self.assertIn("[double]$MaxDphTotal = 0.15", text)
        self.assertIn("[int]$DiskGb = 180", text)

    def test_uses_v3_action_mimic_and_vl_background_prompt_file(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("[string]$BackgroundPromptPath", text)
        self.assertIn("Get-Content -Raw -LiteralPath $BackgroundPromptPath", text)
        self.assertIn("workflows\\LTX2.3动作模仿+音频对口型-V3候选.json", text)
        self.assertIn("2044017351640748034", text)
        self.assertIn("-BackgroundPrompt", text)
        self.assertNotIn("Qwen3-VL", text)
        self.assertNotIn("PromptRelay", text)


if __name__ == "__main__":
    unittest.main()
