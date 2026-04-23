import json
import subprocess
import tempfile
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

    def test_import_project_dotenv_sets_missing_process_values(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            env_path = Path(temp_dir) / ".env"
            env_path.write_text("ASSET_S3_ACCESS_KEY_ID=test-key\n", encoding="utf-8")
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:ASSET_S3_ACCESS_KEY_ID -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "Write-Output $env:ASSET_S3_ACCESS_KEY_ID"
            )

            completed = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", command],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(completed.stdout.strip(), "test-key")

    def test_import_project_dotenv_falls_back_to_api_txt_for_missing_keys(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            env_path = temp_root / ".env"
            api_path = temp_root / "api.txt"
            env_path.write_text("ASSET_S3_BUCKET=test-bucket\n", encoding="utf-8")
            api_path.write_text(
                "Cloudflare R2 AccessKeyId\napi-access-key\n\n"
                "Cloudflare R2 SecretAccessKey\napi-secret-key\n\n",
                encoding="utf-8",
            )
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:ASSET_S3_ACCESS_KEY_ID -ErrorAction SilentlyContinue; "
                "Remove-Item Env:ASSET_S3_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "$result = @{ access=$env:ASSET_S3_ACCESS_KEY_ID; secret=$env:ASSET_S3_SECRET_ACCESS_KEY }; "
                "ConvertTo-Json -InputObject $result -Compress"
            )

            completed = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", command],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(
                json.loads(completed.stdout.strip()),
                {"access": "api-access-key", "secret": "api-secret-key"},
            )


if __name__ == "__main__":
    unittest.main()
