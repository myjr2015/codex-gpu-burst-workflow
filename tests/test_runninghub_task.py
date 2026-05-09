import os
import tempfile
import unittest
from pathlib import Path

from scripts import runninghub_task


class RunningHubTaskTests(unittest.TestCase):
    def test_resolve_api_key_reads_api_txt_and_ignores_env_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            (repo_root / ".env").write_text("RUNNINGHUB_API_KEY=legacy-key\n", encoding="utf-8")
            (repo_root / "api.txt").write_text("runninghub.cn\napi-key\n\n", encoding="utf-8")

            old_api_key = os.environ.pop("RUNNINGHUB_API_KEY", None)
            old_key = os.environ.pop("RUNNINGHUB_KEY", None)
            try:
                self.assertEqual(runninghub_task.resolve_api_key(repo_root, ""), "api-key")
            finally:
                if old_api_key is not None:
                    os.environ["RUNNINGHUB_API_KEY"] = old_api_key
                if old_key is not None:
                    os.environ["RUNNINGHUB_KEY"] = old_key

    def test_resolve_api_key_ignores_env_file_when_api_txt_missing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            (repo_root / ".env").write_text("RUNNINGHUB_API_KEY=legacy-key\n", encoding="utf-8")

            old_api_key = os.environ.pop("RUNNINGHUB_API_KEY", None)
            old_key = os.environ.pop("RUNNINGHUB_KEY", None)
            try:
                with self.assertRaisesRegex(RuntimeError, "api.txt"):
                    runninghub_task.resolve_api_key(repo_root, "")
            finally:
                if old_api_key is not None:
                    os.environ["RUNNINGHUB_API_KEY"] = old_api_key
                if old_key is not None:
                    os.environ["RUNNINGHUB_KEY"] = old_key

    def test_resolve_api_key_keeps_process_env_highest_priority(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            (repo_root / "api.txt").write_text("runninghub.cn\napi-key\n\n", encoding="utf-8")

            old_api_key = os.environ.get("RUNNINGHUB_API_KEY")
            old_key = os.environ.pop("RUNNINGHUB_KEY", None)
            os.environ["RUNNINGHUB_API_KEY"] = "process-key"
            try:
                self.assertEqual(runninghub_task.resolve_api_key(repo_root, ""), "process-key")
            finally:
                if old_api_key is None:
                    os.environ.pop("RUNNINGHUB_API_KEY", None)
                else:
                    os.environ["RUNNINGHUB_API_KEY"] = old_api_key
                if old_key is not None:
                    os.environ["RUNNINGHUB_KEY"] = old_key


if __name__ == "__main__":
    unittest.main()
