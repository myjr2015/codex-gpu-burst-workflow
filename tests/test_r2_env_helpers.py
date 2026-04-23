import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class R2EnvHelperTests(unittest.TestCase):
    def test_resolve_r2_account_id_uses_endpoint_when_explicit_ids_missing(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        command = (
            f". '{helper_path}'; "
            "$env:CLOUDFLARE_ACCOUNT_ID = ''; "
            "$env:ASSET_S3_ACCOUNT_ID = ''; "
            "$result = Resolve-R2AccountId "
            "-CloudflareAccountId '' "
            "-AssetAccountId '' "
            "-Endpoint 'https://4aa19d68af34d61d2fac61c5da4d2c45.r2.cloudflarestorage.com'; "
            "ConvertTo-Json -InputObject $result -Compress"
        )

        completed = subprocess.run(
            ["pwsh", "-NoProfile", "-Command", command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(json.loads(completed.stdout.strip()), "4aa19d68af34d61d2fac61c5da4d2c45")


if __name__ == "__main__":
    unittest.main()
