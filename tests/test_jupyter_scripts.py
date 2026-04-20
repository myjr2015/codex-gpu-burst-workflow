import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(script_name: str):
    script_path = ROOT / "scripts" / script_name
    spec = importlib.util.spec_from_file_location(script_name.replace(".py", ""), script_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class JupyterScriptsTests(unittest.TestCase):
    def test_terminal_exec_session_ignores_system_proxy(self):
        module = load_module("jupyter_terminal_exec.py")
        session = module.build_session()
        self.assertFalse(session.trust_env)

    def test_upload_session_ignores_system_proxy(self):
        module = load_module("jupyter_upload.py")
        session = module.build_session()
        self.assertFalse(session.trust_env)


if __name__ == "__main__":
    unittest.main()
