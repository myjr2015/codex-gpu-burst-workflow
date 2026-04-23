import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_REGISTRY = {
    "machines": [],
    "updated_at": None,
}


def _now_iso() -> str:
    return datetime.now().replace(microsecond=0).isoformat()


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def _to_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def load_registry(path: Path) -> dict[str, Any]:
    if not path.exists():
        return dict(DEFAULT_REGISTRY)
    data = json.loads(path.read_text(encoding="utf-8"))
    data.setdefault("machines", [])
    data.setdefault("updated_at", None)
    return data


def save_registry(path: Path, registry: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    registry["updated_at"] = _now_iso()
    path.write_text(json.dumps(registry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _offer_sort_key(offer: dict[str, Any]) -> tuple[float, float, int]:
    return (
        _to_float(offer.get("dph_total"), float("inf")),
        -_to_float(offer.get("dlperf"), 0.0),
        int(offer.get("id", 0)),
    )


def _successful_machine_ids(registry: dict[str, Any]) -> set[int]:
    result: set[int] = set()
    for record in registry.get("machines", []):
        if record.get("result") != "succeeded":
            continue
        machine_id = record.get("machine_id")
        if machine_id is not None:
            result.add(int(machine_id))
    return result


def choose_offer(offers: list[dict[str, Any]], registry: dict[str, Any], exclude_known: bool = False) -> dict[str, Any]:
    if not offers:
        raise ValueError("No Vast offers available for selection.")

    if exclude_known:
        known_ids = _successful_machine_ids(registry)
        offers = [offer for offer in offers if offer.get("machine_id") not in known_ids]
        if not offers:
            raise ValueError("No Vast offers remain after excluding known machines.")

    successful_by_machine: dict[int, dict[str, Any]] = {}
    for record in registry.get("machines", []):
        if record.get("result") != "succeeded":
            continue
        machine_id = record.get("machine_id")
        if machine_id is None:
            continue
        existing = successful_by_machine.get(machine_id)
        if existing is None:
            successful_by_machine[machine_id] = record
            continue

        existing_time = _parse_iso(existing.get("last_success_at"))
        record_time = _parse_iso(record.get("last_success_at"))
        if record_time and (existing_time is None or record_time > existing_time):
            successful_by_machine[machine_id] = record

    preferred_candidates: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for offer in offers:
        machine_id = offer.get("machine_id")
        if machine_id in successful_by_machine:
            preferred_candidates.append((offer, successful_by_machine[machine_id]))

    if preferred_candidates:
        def _preferred_sort_key(item: tuple[dict[str, Any], dict[str, Any]]) -> tuple[float, float, tuple[float, float, int]]:
            offer, record = item
            success_time = _parse_iso(record.get("last_success_at"))
            success_marker = success_time.timestamp() if success_time else 0.0
            return (
                -success_marker,
                _to_float(record.get("total_until_download_seconds"), float("inf")),
                _offer_sort_key(offer),
            )

        preferred_candidates.sort(
            key=_preferred_sort_key
        )
        offer, record = preferred_candidates[0]
        return {
            "offer_id": offer.get("id"),
            "machine_id": offer.get("machine_id"),
            "host_id": offer.get("host_id"),
            "warm_start": True,
            "selection_mode": "preferred_machine",
            "selection_reason": f"matched previous success on machine {offer.get('machine_id')}",
            "previous_success": record,
            "offer": offer,
        }

    cheapest_offer = sorted(offers, key=_offer_sort_key)[0]
    return {
        "offer_id": cheapest_offer.get("id"),
        "machine_id": cheapest_offer.get("machine_id"),
        "host_id": cheapest_offer.get("host_id"),
        "warm_start": False,
        "selection_mode": "cold_start",
        "selection_reason": "no previously successful machine matched available offers",
        "offer": cheapest_offer,
    }


def analyze_warmstart_log(log_text: str) -> dict[str, dict[str, bool | None]]:
    return {
        "warm_start": {
            "custom_nodes": "[bootstrap] warm-start hit: custom_nodes" in log_text,
            "models": "[bootstrap] warm-start hit: models" in log_text,
            "torch": (
                "[bootstrap] existing torch stack is compatible with this workflow runtime" in log_text
                or "[bootstrap] reusing existing torch stack:" in log_text
                or "[bootstrap] prewarmed image provides torch torchvision torchaudio" in log_text
            ),
        }
    }


def _extract_offer_id(run_report: dict[str, Any]) -> int | None:
    for step in run_report.get("steps", []):
        if step.get("name") != "launch":
            continue
        args = step.get("args") or []
        for index, value in enumerate(args):
            if value == "-OfferId" and index + 1 < len(args):
                try:
                    return int(args[index + 1])
                except (TypeError, ValueError):
                    return None
    return None


def _find_stage_start(timing_summary: dict[str, Any], stage_name: str) -> datetime | None:
    for stage in timing_summary.get("stages", []):
        if stage.get("stage") == stage_name:
            return _parse_iso(stage.get("start"))
    return None


def _compute_submit_delta_seconds(timing_summary: dict[str, Any]) -> float | None:
    lifecycle = timing_summary.get("lifecycle", {})
    started_at = _parse_iso(lifecycle.get("instance_started_at"))
    submit_at = _find_stage_start(timing_summary, "remote.submit_workflow")
    if not started_at or not submit_at:
        return None
    return round((submit_at - started_at).total_seconds(), 3)


def record_run_result(
    registry_path: Path,
    instance: dict[str, Any],
    timing_summary: dict[str, Any],
    run_report: dict[str, Any],
    analysis: dict[str, Any] | None = None,
    result_status: str | None = None,
) -> dict[str, Any]:
    registry = load_registry(registry_path)
    analysis = analysis or {"warm_start": {}}
    warm_start = analysis.get("warm_start", {})
    record = {
        "machine_id": instance.get("machine_id"),
        "host_id": instance.get("host_id"),
        "offer_id": _extract_offer_id(run_report),
        "gpu_name": instance.get("gpu_name"),
        "gpu_ram": instance.get("gpu_ram"),
        "driver_version": instance.get("driver_version"),
        "geolocation": instance.get("geolocation"),
        "verification": instance.get("verification"),
        "dph_total": instance.get("dph_total"),
        "job_name": run_report.get("job_name"),
        "instance_id": instance.get("id"),
        "result": result_status or run_report.get("status"),
        "last_success_at": (
            run_report.get("ended_at")
            or timing_summary.get("lifecycle", {}).get("result_downloaded_at")
            or _now_iso()
        ),
        "total_until_download_seconds": timing_summary.get("lifecycle", {}).get("total_until_download_seconds"),
        "instance_started_to_submit_seconds": _compute_submit_delta_seconds(timing_summary),
        "prompt_execution": timing_summary.get("prompt_execution"),
        "warmstart_hit_custom_nodes": bool(warm_start.get("custom_nodes")),
        "warmstart_hit_models": bool(warm_start.get("models")),
        "warmstart_hit_torch": bool(warm_start.get("torch")),
        "updated_at": _now_iso(),
    }

    machines = registry.setdefault("machines", [])
    replaced = False
    for index, existing in enumerate(machines):
        if existing.get("machine_id") == record["machine_id"]:
            existing_time = _parse_iso(existing.get("last_success_at"))
            record_time = _parse_iso(record.get("last_success_at"))
            if existing_time and record_time and existing_time > record_time:
                record = existing
            else:
                machines[index] = record
            replaced = True
            break
    if not replaced:
        machines.append(record)

    save_registry(registry_path, registry)
    return record


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    choose_parser = subparsers.add_parser("choose-offer")
    choose_parser.add_argument("--registry-path", required=True)
    choose_parser.add_argument("--offers-path", required=True)
    choose_parser.add_argument("--exclude-known", action="store_true")

    update_parser = subparsers.add_parser("record-run")
    update_parser.add_argument("--registry-path", required=True)
    update_parser.add_argument("--instance-path", required=True)
    update_parser.add_argument("--timing-path", required=True)
    update_parser.add_argument("--run-report-path", required=True)
    update_parser.add_argument("--log-path")
    update_parser.add_argument("--result")

    args = parser.parse_args()

    if args.command == "choose-offer":
        registry = load_registry(Path(args.registry_path))
        offers = _read_json(Path(args.offers_path))
        decision = choose_offer(offers=offers, registry=registry, exclude_known=args.exclude_known)
        print(json.dumps(decision, ensure_ascii=False))
        return 0

    if args.command == "record-run":
        analysis = None
        if args.log_path:
            analysis = analyze_warmstart_log(Path(args.log_path).read_text(encoding="utf-8", errors="replace"))
        record = record_run_result(
            registry_path=Path(args.registry_path),
            instance=_read_json(Path(args.instance_path)),
            timing_summary=_read_json(Path(args.timing_path)),
            run_report=_read_json(Path(args.run_report_path)),
            analysis=analysis,
            result_status=args.result,
        )
        print(json.dumps(record, ensure_ascii=False))
        return 0

    raise ValueError(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
