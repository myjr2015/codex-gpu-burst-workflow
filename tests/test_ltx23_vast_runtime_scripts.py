import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "bootstrap_ltx23_talking_head.sh"
REMOTE_SUBMIT = ROOT / "scripts" / "remote_submit_ltx23_talking_head.sh"


class Ltx23VastRuntimeScriptTests(unittest.TestCase):
    def test_bootstrap_retries_pip_hash_mismatch_without_cache(self):
        text = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("THESE PACKAGES DO NOT MATCH THE HASHES", text)
        self.assertIn("python3 -m pip cache purge", text)
        self.assertIn("--no-cache-dir", text)

    def test_frontend_package_is_not_filtered_from_comfyui_requirements(self):
        text = BOOTSTRAP.read_text(encoding="utf-8")
        slow_optional_block = text.split("slow_optional_prefixes = (", 1)[1].split(")", 1)[0]
        self.assertNotIn("comfyui_frontend_package", slow_optional_block)
        self.assertNotIn("comfyui-frontend-package", slow_optional_block)
        self.assertIn('ensure_python_package "comfyui-frontend-package==1.42.11"', text)

    def test_host_cuda_driver_libs_are_preferred_for_bootstrap_and_comfyui(self):
        bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
        remote_text = REMOTE_SUBMIT.read_text(encoding="utf-8")
        self.assertIn("prefer_host_cuda_driver_libs", bootstrap_text)
        self.assertIn("prefer_host_cuda_driver_libs", remote_text)
        self.assertIn("/usr/lib/x86_64-linux-gnu", bootstrap_text)
        self.assertIn('LD_LIBRARY_PATH="$LD_LIBRARY_PATH" python3 -u main.py', remote_text)


if __name__ == "__main__":
    unittest.main()
