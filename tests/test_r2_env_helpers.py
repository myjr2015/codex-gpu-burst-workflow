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
                "Cloudflare\ncf-api-token\n\n"
                "Cloudflare Account ID\n4aa19d68af34d61d2fac61c5da4d2c45\n\n"
                "Cloudflare_R2\napi-access-key\napi-secret-key\n\n",
                encoding="utf-8",
            )
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue; "
                "Remove-Item Env:CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue; "
                "Remove-Item Env:R2_ACCESS_KEY_ID -ErrorAction SilentlyContinue; "
                "Remove-Item Env:R2_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "$result = @{ token=$env:CLOUDFLARE_API_TOKEN; account=$env:CLOUDFLARE_ACCOUNT_ID; access=$env:R2_ACCESS_KEY_ID; secret=$env:R2_SECRET_ACCESS_KEY }; "
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
                {
                    "token": "cf-api-token",
                    "account": "4aa19d68af34d61d2fac61c5da4d2c45",
                    "access": "api-access-key",
                    "secret": "api-secret-key",
                },
            )

    def test_import_project_dotenv_prefers_api_txt_for_r2_over_stale_env_values(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            env_path = temp_root / ".env"
            api_path = temp_root / "api.txt"
            env_path.write_text(
                "CLOUDFLARE_ACCOUNT_ID=old-account\n"
                "R2_ACCESS_KEY_ID=old-access\n"
                "R2_SECRET_ACCESS_KEY=old-secret\n",
                encoding="utf-8",
            )
            api_path.write_text(
                "Cloudflare Account ID\nnew-account\n\n"
                "Cloudflare_R2\nnew-access\nnew-secret\n\n",
                encoding="utf-8",
            )
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue; "
                "Remove-Item Env:R2_ACCESS_KEY_ID -ErrorAction SilentlyContinue; "
                "Remove-Item Env:R2_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "$result = @{ account=$env:CLOUDFLARE_ACCOUNT_ID; access=$env:R2_ACCESS_KEY_ID; secret=$env:R2_SECRET_ACCESS_KEY }; "
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
                {
                    "account": "new-account",
                    "access": "new-access",
                    "secret": "new-secret",
                },
            )


if __name__ == "__main__":
    unittest.main()
