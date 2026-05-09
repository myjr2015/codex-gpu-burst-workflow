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

    def test_import_project_dotenv_ignores_env_file_values(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            env_path = Path(temp_dir) / ".env"
            env_path.write_text("ASSET_S3_ACCESS_KEY_ID=test-key\n", encoding="utf-8")
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:ASSET_S3_ACCESS_KEY_ID -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "Write-Output ([string]::IsNullOrEmpty($env:ASSET_S3_ACCESS_KEY_ID))"
            )

            completed = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", command],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(completed.stdout.strip(), "True")

    def test_import_project_dotenv_reads_root_config_json_when_env_is_missing(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            env_path = temp_root / ".env"
            config_path = temp_root / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "ASSET_S3_BUCKET": "json-bucket",
                        "RUNCOMFY_BASE_URL": "https://api.example.test/v1",
                    }
                ),
                encoding="utf-8",
            )
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:ASSET_S3_BUCKET -ErrorAction SilentlyContinue; "
                "Remove-Item Env:RUNCOMFY_BASE_URL -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "$result = @{ bucket=$env:ASSET_S3_BUCKET; baseUrl=$env:RUNCOMFY_BASE_URL }; "
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
                    "bucket": "json-bucket",
                    "baseUrl": "https://api.example.test/v1",
                },
            )

    def test_import_project_dotenv_reads_config_json_and_ignores_env_values(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            env_path = temp_root / ".env"
            config_path = temp_root / "config.json"
            env_path.write_text("ASSET_S3_BUCKET=legacy-bucket\n", encoding="utf-8")
            config_path.write_text(json.dumps({"ASSET_S3_BUCKET": "json-bucket"}), encoding="utf-8")
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:ASSET_S3_BUCKET -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "Write-Output $env:ASSET_S3_BUCKET"
            )

            completed = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", command],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(completed.stdout.strip(), "json-bucket")

    def test_import_project_dotenv_maps_common_api_txt_site_aliases(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            env_path = temp_root / ".env"
            api_path = temp_root / "api.txt"
            api_path.write_text(
                "RunComfy.com\nruncomfy-key\n\n"
                "runninghub.cn\nrunninghub-key\n\n"
                "runpod.io\nrunpod-key\n\n",
                encoding="utf-8",
            )
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:RUNCOMFY_API_KEY -ErrorAction SilentlyContinue; "
                "Remove-Item Env:RUNNINGHUB_API_KEY -ErrorAction SilentlyContinue; "
                "Remove-Item Env:RUNNINGHUB_KEY -ErrorAction SilentlyContinue; "
                "Remove-Item Env:RUNPOD_API_KEY -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "$result = @{ runcomfy=$env:RUNCOMFY_API_KEY; runninghub=$env:RUNNINGHUB_API_KEY; runninghubAlias=$env:RUNNINGHUB_KEY; runpod=$env:RUNPOD_API_KEY }; "
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
                    "runcomfy": "runcomfy-key",
                    "runninghub": "runninghub-key",
                    "runninghubAlias": "runninghub-key",
                    "runpod": "runpod-key",
                },
            )

    def test_import_project_dotenv_reads_api_txt_and_ignores_env_for_secret_values(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            env_path = temp_root / ".env"
            api_path = temp_root / "api.txt"
            env_path.write_text("RUNCOMFY_API_KEY=legacy-runcomfy-key\n", encoding="utf-8")
            api_path.write_text("RunComfy.com\napi-runcomfy-key\n\n", encoding="utf-8")
            command = (
                f". '{helper_path}'; "
                "Remove-Item Env:RUNCOMFY_API_KEY -ErrorAction SilentlyContinue; "
                f"Import-ProjectDotEnv -Path '{env_path}'; "
                "Write-Output $env:RUNCOMFY_API_KEY"
            )

            completed = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", command],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(completed.stdout.strip(), "api-runcomfy-key")

    def test_import_project_dotenv_loads_api_txt_for_secret_keys(self):
        helper_path = ROOT / "scripts" / "r2_env_helpers.ps1"
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            api_path = temp_root / "api.txt"
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
                f"Import-ProjectDotEnv -Path '{temp_root / '.env'}'; "
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

    def test_import_project_dotenv_ignores_stale_env_values_for_r2(self):
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
