import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ApiTxtConfigFallbackTests(unittest.TestCase):
    def test_node_config_reads_api_txt_when_env_key_is_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            (temp_root / "api.txt").write_text(
                "RunComfy\nruncomfy-from-api\n\n"
                "Cloudflare R2 AccessKeyId\nr2-access-from-api\n\n"
                "Cloudflare R2 SecretAccessKey\nr2-secret-from-api\n\n",
                encoding="utf-8",
            )
            config_uri = (ROOT / "src" / "config.js").as_uri()
            script = (
                f"import {{ loadAppConfig }} from '{config_uri}';"
                "const config = loadAppConfig();"
                "console.log(JSON.stringify({"
                "runComfyApiKey: config.runComfyApiKey,"
                "s3AccessKeyId: config.assetStorage.s3AccessKeyId,"
                "s3SecretAccessKey: config.assetStorage.s3SecretAccessKey"
                "}));"
            )
            env = os.environ.copy()
            for name in (
                "RUNCOMFY_API_KEY",
                "ASSET_S3_ACCESS_KEY_ID",
                "ASSET_S3_SECRET_ACCESS_KEY",
                "R2_ACCESS_KEY_ID",
                "R2_SECRET_ACCESS_KEY",
            ):
                env.pop(name, None)

            completed = subprocess.run(
                ["node", "--input-type=module", "-e", script],
                cwd=temp_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertEqual(
                json.loads(completed.stdout.strip()),
                {
                    "runComfyApiKey": "runcomfy-from-api",
                    "s3AccessKeyId": "r2-access-from-api",
                    "s3SecretAccessKey": "r2-secret-from-api",
                },
            )


if __name__ == "__main__":
    unittest.main()
