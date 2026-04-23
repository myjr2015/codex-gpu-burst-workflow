import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(script_name: str):
    script_path = ROOT / "scripts" / script_name
    spec = importlib.util.spec_from_file_location(script_name.replace(".py", ""), script_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MachineRegistrySelectionTests(unittest.TestCase):
    def test_prefers_known_success_machine_and_enables_warm_start(self):
        module = load_module("vast_machine_registry.py")
        registry = {
            "machines": [
                {
                    "machine_id": 56268,
                    "host_id": 1820,
                    "result": "succeeded",
                    "last_success_at": "2026-04-23T11:47:28",
                    "total_until_download_seconds": 1476.0,
                }
            ]
        }
        offers = [
            {"id": 999001, "machine_id": 90001, "host_id": 5001, "dph_total": 0.17, "verification": "verified"},
            {"id": 35314367, "machine_id": 56268, "host_id": 1820, "dph_total": 0.21, "verification": "verified"},
        ]

        decision = module.choose_offer(offers=offers, registry=registry)

        self.assertEqual(decision["offer_id"], 35314367)
        self.assertTrue(decision["warm_start"])
        self.assertEqual(decision["selection_mode"], "preferred_machine")

    def test_falls_back_to_cheapest_offer_for_unknown_machine(self):
        module = load_module("vast_machine_registry.py")
        registry = {"machines": []}
        offers = [
            {"id": 35314367, "machine_id": 56268, "host_id": 1820, "dph_total": 0.21, "verification": "verified"},
            {"id": 999001, "machine_id": 90001, "host_id": 5001, "dph_total": 0.17, "verification": "verified"},
        ]

        decision = module.choose_offer(offers=offers, registry=registry)

        self.assertEqual(decision["offer_id"], 999001)
        self.assertFalse(decision["warm_start"])
        self.assertEqual(decision["selection_mode"], "cold_start")

    def test_can_exclude_known_successful_machines_for_fresh_test(self):
        module = load_module("vast_machine_registry.py")
        registry = {
            "machines": [
                {
                    "machine_id": 56268,
                    "host_id": 1820,
                    "result": "succeeded",
                    "last_success_at": "2026-04-23T11:47:28",
                }
            ]
        }
        offers = [
            {"id": 35314367, "machine_id": 56268, "host_id": 1820, "dph_total": 0.17, "verification": "verified"},
            {"id": 999001, "machine_id": 90001, "host_id": 5001, "dph_total": 0.21, "verification": "verified"},
        ]

        decision = module.choose_offer(offers=offers, registry=registry, exclude_known=True)

        self.assertEqual(decision["offer_id"], 999001)
        self.assertEqual(decision["machine_id"], 90001)
        self.assertFalse(decision["warm_start"])


class MachineRegistryUpdateTests(unittest.TestCase):
    def test_records_successful_run_with_warmstart_flags_and_timings(self):
        module = load_module("vast_machine_registry.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            registry_path = temp_root / "vast-machine-registry.json"
            registry_path.write_text(json.dumps({"machines": []}), encoding="utf-8")

            instance = {
                "id": 35455798,
                "host_id": 1820,
                "machine_id": 56268,
                "gpu_name": "RTX 3090",
                "gpu_ram": 24576,
                "driver_version": "590.48.01",
                "geolocation": "Quebec, CA",
                "verification": "verified",
                "dph_total": 0.21,
                "label": "wan_2_2_animate-job-v11-warmstart-samehost-002",
            }
            timing = {
                "lifecycle": {
                    "total_until_download_seconds": 1476.0,
                    "instance_started_at": "2026-04-23T03:23:07.0000000+00:00",
                },
                "prompt_execution": "00:13:51",
                "stages": [
                    {"stage": "remote.submit_workflow", "start": "2026-04-23T03:33:07.0000000+00:00"},
                ],
            }
            run_report = {"job_name": "v11-warmstart-samehost-002", "status": "succeeded"}
            analysis = {
                "warm_start": {
                    "custom_nodes": False,
                    "models": False,
                    "torch": False,
                }
            }

            module.record_run_result(
                registry_path=registry_path,
                instance=instance,
                timing_summary=timing,
                run_report=run_report,
                analysis=analysis,
            )

            registry = json.loads(registry_path.read_text(encoding="utf-8"))
            self.assertEqual(len(registry["machines"]), 1)
            record = registry["machines"][0]
            self.assertEqual(record["machine_id"], 56268)
            self.assertEqual(record["host_id"], 1820)
            self.assertEqual(record["offer_id"], None)
            self.assertEqual(record["job_name"], "v11-warmstart-samehost-002")
            self.assertEqual(record["result"], "succeeded")
            self.assertEqual(record["total_until_download_seconds"], 1476.0)
            self.assertEqual(record["instance_started_to_submit_seconds"], 600.0)
            self.assertEqual(record["prompt_execution"], "00:13:51")
            self.assertFalse(record["warmstart_hit_custom_nodes"])
            self.assertFalse(record["warmstart_hit_models"])
            self.assertFalse(record["warmstart_hit_torch"])

    def test_older_success_does_not_replace_newer_record_for_same_machine(self):
        module = load_module("vast_machine_registry.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            registry_path = temp_root / "vast-machine-registry.json"
            registry_path.write_text(
                json.dumps(
                    {
                        "machines": [
                            {
                                "machine_id": 56268,
                                "host_id": 1820,
                                "job_name": "newer-job",
                                "last_success_at": "2026-04-23T11:47:28",
                                "result": "succeeded",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            instance = {"id": 35453562, "host_id": 1820, "machine_id": 56268}
            timing = {"lifecycle": {"result_downloaded_at": "2026-04-23T10:32:51"}, "stages": []}
            run_report = {"job_name": "older-job", "status": "succeeded"}

            record = module.record_run_result(
                registry_path=registry_path,
                instance=instance,
                timing_summary=timing,
                run_report=run_report,
                analysis={"warm_start": {}},
            )

            self.assertEqual(record["job_name"], "newer-job")
            registry = json.loads(registry_path.read_text(encoding="utf-8"))
            self.assertEqual(registry["machines"][0]["job_name"], "newer-job")


if __name__ == "__main__":
    unittest.main()
