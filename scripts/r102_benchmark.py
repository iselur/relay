#!/usr/bin/env python3
"""Offline-verifiable adapter for the R102 tier-A benchmark slice."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
CANONICAL_CONFIG = ROOT / "scripts" / "r102_tier_a.json"
TASK_COPY = "task-manifest.json"
CONFIG_COPY = "config-manifest.json"


class EvidenceError(ValueError):
    pass


def _json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def _write_json_with_digest(path, value):
    data = _json_bytes(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    Path(str(path) + ".sha256").write_text(hashlib.sha256(data).hexdigest() + "\n")


def _read_json(path):
    try:
        return json.loads(path.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot read JSON {path}: {exc}") from exc


def _read_rows(path):
    value = _read_json(path)
    if not isinstance(value, list):
        raise EvidenceError(f"configuration manifest is not a JSON array: {path}")
    return value


def _sha256(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        raise EvidenceError(f"cannot hash {path}: {exc}") from exc


def _run_command(argv):
    started = time.monotonic()
    try:
        completed = subprocess.run(argv, text=True, capture_output=True, check=False)
        return completed.returncode, completed.stdout, completed.stderr, time.monotonic() - started
    except OSError as exc:
        return 127, "", str(exc), time.monotonic() - started


def _probe(argv):
    code, stdout, stderr, _ = _run_command(argv)
    return {
        "command": argv,
        "ok": code == 0,
        "output": (stdout or stderr).strip(),
        "returncode": code,
    }


def preflight(args):
    config_path = Path(args.config_manifest) if args.config_manifest else CANONICAL_CONFIG
    try:
        rows = _read_rows(config_path)
    except EvidenceError as exc:
        print(f"preflight: {exc}", file=sys.stderr)
        return 2
    probes = {
        "codex": _probe(["codex", "--version"]),
        "claude": _probe(["claude", "--version"]),
        "kimi": _probe(["kimi", "--version"]),
        "harbor": _probe(["harbor", "--version"]),
        "docker": _probe(["docker", "info", "--format", "{{.ServerVersion}}"]),
    }
    manifest = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "cli_versions": probes,
        "tier_a": rows,
        "task_source": "Terminal-Bench 2.1",
        "grader": "Harbor 0.20.0 official grader",
        "price_sheet": {
            "source": "July 2026 vendor price sheet",
            "effective": "2026-07",
        },
    }
    _write_json_with_digest(Path(args.out), manifest)
    failed = [name for name, result in probes.items() if not result["ok"]]
    if failed:
        print("preflight: failed probes: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


def _normal_token(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _find_tokens(value):
    if not isinstance(value, dict):
        return None, None
    input_keys = ("n_input_tokens", "input_tokens", "inputTokens", "prompt_tokens")
    output_keys = ("n_output_tokens", "output_tokens", "outputTokens", "completion_tokens")
    input_tokens = next((value[key] for key in input_keys if _normal_token(value.get(key))), None)
    output_tokens = next((value[key] for key in output_keys if _normal_token(value.get(key))), None)
    if input_tokens is not None and output_tokens is not None:
        return input_tokens, output_tokens
    for child in value.values():
        if isinstance(child, dict):
            found_input, found_output = _find_tokens(child)
            if found_input is not None and found_output is not None:
                return found_input, found_output
    return input_tokens, output_tokens


def _metadata_r102(result):
    agent_result = result.get("agent_result")
    if not isinstance(agent_result, dict):
        return {}
    metadata = agent_result.get("metadata")
    if isinstance(metadata, dict) and isinstance(metadata.get("r102"), dict):
        return metadata["r102"]
    context = agent_result.get("context")
    if isinstance(context, dict):
        metadata = context.get("metadata")
        if isinstance(metadata, dict) and isinstance(metadata.get("r102"), dict):
            return metadata["r102"]
    return {}


def _reward_value(value):
    if isinstance(value, dict):
        for key in ("reward", "score", "verdict", "result"):
            if key in value:
                return _reward_value(value[key])
        if len(value) == 1:
            return _reward_value(next(iter(value.values())))
        return None
    if isinstance(value, bool):
        return "PASS" if value else "FAIL"
    if isinstance(value, (int, float)):
        return "PASS" if value > 0 else "FAIL"
    if isinstance(value, str):
        text = value.strip()
        try:
            return _reward_value(json.loads(text))
        except json.JSONDecodeError:
            upper = text.upper()
            if upper in {"PASS", "PASSED", "SUCCESS", "TRUE"}:
                return "PASS"
            if upper in {"FAIL", "FAILED", "FAILURE", "FALSE"}:
                return "FAIL"
            try:
                return "PASS" if float(text) > 0 else "FAIL"
            except ValueError:
                return None
    return None


def _raw_reward(path):
    try:
        data = path.read_text().strip()
    except OSError as exc:
        raise EvidenceError(f"raw grader file unreadable: {path}: {exc}") from exc
    if not data:
        raise EvidenceError(f"raw grader file is empty: {path}")
    if path.suffix == ".json":
        try:
            value = json.loads(data)
        except json.JSONDecodeError as exc:
            raise EvidenceError(f"raw grader JSON malformed: {path}: {exc}") from exc
    else:
        value = data
    verdict = _reward_value(value)
    if verdict is None:
        raise EvidenceError(f"raw grader verdict unrecognized: {path}")
    return verdict


def _result_verdict(result):
    verifier = result.get("verifier_result")
    if verifier is None:
        return None
    return _reward_value(verifier)


def _usage_files(trial_dir):
    return sorted(trial_dir.rglob("usage.jsonl"))


def _read_usage(trial_dir):
    events = []
    files = _usage_files(trial_dir)
    for path in files:
        try:
            lines = path.read_text().splitlines()
        except OSError as exc:
            raise EvidenceError(f"usage log unreadable: {path}: {exc}") from exc
        for number, line in enumerate(lines, 1):
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                raise EvidenceError(f"malformed usage event {path}:{number}: {exc}") from exc
            if not isinstance(event, dict):
                raise EvidenceError(f"usage event is not an object: {path}:{number}")
            events.append(event)
    return events


def _role_totals(events):
    totals = {}
    for event in events:
        role = event.get("role")
        if not isinstance(role, str):
            continue
        current = totals.setdefault(role, {"input_tokens": 0, "output_tokens": 0})
        for key in ("input_tokens", "output_tokens"):
            value = event.get(key)
            if _normal_token(value):
                current[key] += value
    return totals


def _harness_usage_error(row, events, metadata):
    if not events:
        return "no per-role usage events"
    roles = {"orchestrator", "worker"}
    if row["reviewer"] is not None:
        roles.add("reviewer")
    seen = set()
    quality_only = metadata.get("quality_only") is True
    if quality_only:
        if row.get("worker_mode") != "subagent":
            return "quality_only is permitted only for the subagent row"
        probe = metadata.get("attribution_probe")
        if not isinstance(probe, str) or not probe:
            return "quality_only subagent usage lacks an attribution_probe"
    for event in events:
        role = event.get("role")
        if role not in roles:
            return f"unexpected usage role {role!r}"
        binding = row[role]
        if any(event.get(key) != binding[key] for key in ("vendor", "model", "effort")):
            return f"{role} usage binding mismatch"
        if not quality_only and (not _normal_token(event.get("input_tokens")) or
                                 not _normal_token(event.get("output_tokens"))):
            return f"{role} token evidence absent"
        seen.add(role)
    missing = roles - seen
    if missing:
        return "missing usage roles: " + ", ".join(sorted(missing))
    if row["reviewer"] is None and "reviewer" in seen:
        return "reviewer event present on reviewer-null row"
    recorded_totals = metadata.get("per_role")
    if not isinstance(recorded_totals, dict) or recorded_totals != _role_totals(events):
        return "per-role totals do not match usage events"
    evidence = metadata.get("orchestrator_evidence")
    binding = row["orchestrator"]
    if not isinstance(evidence, dict):
        return "orchestrator evidence absent"
    if evidence.get("vendor") != binding["vendor"] or evidence.get("model") != binding["model"]:
        return "orchestrator evidence binding mismatch"
    if not isinstance(evidence.get("log"), str) or not evidence["log"]:
        return "orchestrator invocation log absent"
    return None


def _copy_inputs(evidence, task_path, config_path):
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / TASK_COPY).write_bytes(task_path.read_bytes())
    (evidence / CONFIG_COPY).write_bytes(config_path.read_bytes())


def _relative(path, root):
    return path.resolve().relative_to(root.resolve()).as_posix()


def kill_test(args):
    if os.environ.get("R102_BENCHMARK") != "1":
        print("kill-test refused: set R102_BENCHMARK=1 to enable paid benchmark runs", file=sys.stderr)
        return 2
    task_path = Path(args.task_manifest)
    config_path = Path(args.config_manifest)
    try:
        canonical = _read_rows(CANONICAL_CONFIG)
        rows = _read_rows(config_path)
        if rows != canonical:
            raise EvidenceError("configuration manifest differs from canonical tier-A rows")
        task_manifest = _read_json(task_path)
        if not isinstance(task_manifest, dict):
            raise EvidenceError("task manifest is not an object")
        if task_manifest.get("benchmark") != args.benchmark:
            raise EvidenceError("task manifest benchmark does not match --benchmark")
        task = task_manifest.get("task")
        if not isinstance(task, str) or not task:
            raise EvidenceError("task manifest requires a non-empty task field")
        if args.trials < 1:
            raise EvidenceError("--trials must be at least 1")
        task_digest = _sha256(task_path)
        config_digest = _sha256(config_path)
    except EvidenceError as exc:
        print(f"kill-test: {exc}", file=sys.stderr)
        return 2

    evidence = Path(args.evidence)
    try:
        _copy_inputs(evidence, task_path, config_path)
    except OSError as exc:
        print(f"kill-test: cannot retain input manifests: {exc}", file=sys.stderr)
        return 2

    launch = {}
    for row in rows:
        for trial_number in range(1, args.trials + 1):
            trial_dir = evidence / "harbor" / row["name"] / f"trial-{trial_number}"
            argv = [
                "harbor", "run", "--agent", row["harbor_agent"], "-m", row["model"],
                "-t", task, "-o", str(trial_dir), "-k", "1", "-y",
            ]
            if row["kind"] == "harness":
                argv.extend(["--ak", "row=" + json.dumps(row, separators=(",", ":"))])
            code, stdout, stderr, wall_s = _run_command(argv)
            launch[(row["name"], trial_number)] = {
                "returncode": code,
                "stdout": stdout,
                "stderr": stderr,
                "wall_s": wall_s,
            }

    manifest_rows = []
    all_evidence = True
    for row in rows:
        errors = []
        results = []
        raw_paths = []
        usage = [] if row["kind"] == "harness" else {"input_tokens": 0, "output_tokens": 0}
        metadata_values = []
        trial_dirs = []
        wall_s = 0.0
        for trial_number in range(1, args.trials + 1):
            trial_dir = evidence / "harbor" / row["name"] / f"trial-{trial_number}"
            trial_dirs.append(_relative(trial_dir, evidence))
            run = launch[(row["name"], trial_number)]
            wall_s += run["wall_s"]
            if run["returncode"] != 0:
                detail = (run["stderr"] or run["stdout"]).strip()
                errors.append(f"trial-{trial_number} harbor exit {run['returncode']}: {detail}")
            result_path = trial_dir / "result.json"
            try:
                result = _read_json(result_path)
                if not isinstance(result, dict):
                    raise EvidenceError(f"result is not an object: {result_path}")
                grader_files = [path for path in (
                    trial_dir / "verifier" / "reward.json",
                    trial_dir / "verifier" / "reward.txt",
                ) if path.is_file()]
                if not grader_files:
                    raise EvidenceError(f"no retained raw grader reward in {trial_dir / 'verifier'}")
                verdicts = {_raw_reward(path) for path in grader_files}
                if len(verdicts) != 1:
                    raise EvidenceError(f"raw grader files disagree in {trial_dir}")
                raw_verdict = next(iter(verdicts))
                result_verdict = _result_verdict(result)
                if result_verdict is not None and result_verdict != raw_verdict:
                    raise EvidenceError(f"result and raw grader disagree in {trial_dir}")
                results.append((result, raw_verdict))
                raw_paths.extend(_relative(path, evidence) for path in grader_files)
                if row["kind"] == "harness":
                    trial_usage = _read_usage(trial_dir)
                    metadata = _metadata_r102(result)
                    usage.extend(trial_usage)
                    metadata_values.append(metadata)
                    if metadata.get("config") != row["name"]:
                        raise EvidenceError(f"r102 metadata config mismatch in {result_path}")
                    usage_error = _harness_usage_error(row, trial_usage, metadata)
                    if usage_error:
                        raise EvidenceError(f"required usage evidence invalid: {usage_error}")
                    invocation_log = metadata["orchestrator_evidence"]["log"]
                    if not any(path.name == invocation_log for path in trial_dir.rglob("*")):
                        raise EvidenceError(f"orchestrator invocation log not retained in {trial_dir}")
                else:
                    input_tokens, output_tokens = _find_tokens(result.get("agent_result"))
                    if input_tokens is None or output_tokens is None:
                        raise EvidenceError(f"single-agent token totals absent in {result_path}")
                    usage["input_tokens"] += input_tokens
                    usage["output_tokens"] += output_tokens
            except EvidenceError as exc:
                errors.append(str(exc))

        task_names = {item[0].get("task_name") for item in results}
        task_checksums = {item[0].get("task_checksum") for item in results}
        verdicts = {item[1] for item in results}
        task_name = next(iter(task_names)) if len(task_names) == 1 else None
        task_checksum = next(iter(task_checksums)) if len(task_checksums) == 1 else None
        verdict = next(iter(verdicts)) if len(verdicts) == 1 else None
        if len(results) != args.trials or not task_name or not task_checksum or verdict is None:
            errors.append("official verdict, task identity, or trial result is incomplete")

        review_rounds = 0
        quality_only = False
        orchestrator_evidence = None
        if row["kind"] == "harness":
            for metadata in metadata_values:
                if not isinstance(metadata, dict):
                    errors.append("r102 agent metadata absent")
                    continue
                rounds = metadata.get("review_rounds")
                if not _normal_token(rounds):
                    errors.append("review round count absent")
                else:
                    review_rounds += rounds
                quality_only = quality_only or metadata.get("quality_only") is True
            if metadata_values:
                orchestrator_evidence = metadata_values[0].get("orchestrator_evidence")
                probe_values = {json.dumps(value.get("orchestrator_evidence"), sort_keys=True)
                                for value in metadata_values}
                if len(probe_values) != 1:
                    errors.append("orchestrator evidence differs across trials")
            else:
                errors.append("r102 agent metadata absent")
        evidence_errors = [error for error in errors if " harbor exit " not in error]
        if evidence_errors:
            all_evidence = False
        manifest_rows.append({
            "name": row["name"],
            "trial_dirs": trial_dirs,
            "task_name": task_name,
            "task_checksum": task_checksum,
            "verdict": verdict,
            "grader_raw": raw_paths,
            "usage": usage,
            "wall_s": wall_s,
            "review_rounds": review_rounds,
            "quality_only": quality_only,
            "orchestrator_evidence": orchestrator_evidence,
            "error": "; ".join(errors) if errors else None,
        })

    common_names = {row["task_name"] for row in manifest_rows}
    common_checksums = {row["task_checksum"] for row in manifest_rows}
    if len(common_names) != 1 or len(common_checksums) != 1 or None in common_names | common_checksums:
        all_evidence = False
    manifest = {
        "benchmark": args.benchmark,
        "task_manifest_digest": task_digest,
        "config_manifest_digest": config_digest,
        "rows": manifest_rows,
    }
    _write_json_with_digest(evidence / "manifest.json", manifest)
    return 0 if all_evidence else 1


class CheckReporter:
    def __init__(self):
        self.ok = True

    def check(self, name, function):
        try:
            function()
            print(f"ok {name}")
        except (EvidenceError, KeyError, TypeError, ValueError, OSError) as exc:
            self.ok = False
            print(f"FAIL {name}: {exc}")


def _require(condition, message):
    if not condition:
        raise EvidenceError(message)


def _verified_trials(evidence, manifest, canonical):
    by_name = {row["name"]: row for row in canonical}
    verified = []
    for summary in manifest["rows"]:
        row = by_name[summary["name"]]
        trial_dirs = summary.get("trial_dirs")
        _require(isinstance(trial_dirs, list) and trial_dirs, f"no trials for {row['name']}")
        for relative in trial_dirs:
            trial_dir = evidence / relative
            result = _read_json(trial_dir / "result.json")
            _require(isinstance(result, dict), f"non-object result for {row['name']}")
            verified.append((row, summary, trial_dir, result))
    return verified


def verify(args):
    evidence = Path(args.evidence)
    reporter = CheckReporter()
    manifest_path = evidence / "manifest.json"
    manifest = None
    canonical = None

    def manifest_digest_check():
        try:
            expected = Path(str(manifest_path) + ".sha256").read_text().strip()
        except OSError as exc:
            raise EvidenceError(f"manifest digest unreadable: {exc}") from exc
        _require(len(expected) == 64, "manifest digest malformed")
        _require(_sha256(manifest_path) == expected, "manifest sha256 mismatch")

    reporter.check("manifest-sha256", manifest_digest_check)
    try:
        manifest = _read_json(manifest_path)
        _require(isinstance(manifest, dict), "manifest is not an object")
        canonical = _read_rows(CANONICAL_CONFIG)
    except EvidenceError as exc:
        for name in ("input-digests", "canonical-rows", "common-task", "raw-grader",
                     "harness-usage", "vanilla-usage", "reviewer-null",
                     "codex-orchestrator", "subagent-attribution"):
            reporter.check(name, lambda exc=exc: (_ for _ in ()).throw(exc))
        return 1

    def input_digest_check():
        _require(_sha256(evidence / TASK_COPY) == manifest.get("task_manifest_digest"),
                 "task manifest digest mismatch")
        _require(_sha256(evidence / CONFIG_COPY) == manifest.get("config_manifest_digest"),
                 "config manifest digest mismatch")
        task_manifest = _read_json(evidence / TASK_COPY)
        _require(isinstance(task_manifest, dict), "retained task manifest is not an object")
        _require(task_manifest.get("benchmark") == manifest.get("benchmark"),
                 "retained task benchmark differs from evidence manifest")
        _require(isinstance(task_manifest.get("task"), str) and task_manifest["task"],
                 "retained task reference is absent")
        _read_rows(evidence / CONFIG_COPY)

    reporter.check("input-digests", input_digest_check)

    def canonical_check():
        retained = _read_rows(evidence / CONFIG_COPY)
        _require(retained == canonical, "retained configuration is not canonical")
        summaries = manifest.get("rows")
        _require(isinstance(summaries, list), "rows missing")
        _require([row.get("name") for row in summaries] == [row["name"] for row in canonical],
                 "row names or order differ from canonical tier-A")

    reporter.check("canonical-rows", canonical_check)

    def common_task_check():
        identities = set()
        for _, summary, _, result in _verified_trials(evidence, manifest, canonical):
            identity = (result.get("task_name"), result.get("task_checksum"))
            _require(all(isinstance(value, str) and value for value in identity),
                     "task identity absent from result")
            _require(summary.get("task_name") == identity[0] and
                     summary.get("task_checksum") == identity[1],
                     f"summary task identity contradicts {summary['name']} raw result")
            identities.add(identity)
        _require(len(identities) == 1, "task name/checksum differs across rows")

    reporter.check("common-task", common_task_check)

    def raw_grader_check():
        for _, summary, trial_dir, result in _verified_trials(evidence, manifest, canonical):
            raw = summary.get("grader_raw")
            _require(isinstance(raw, list) and raw, f"raw grader paths absent for {summary['name']}")
            trial_prefix = _relative(trial_dir, evidence) + "/verifier/"
            paths = [evidence / path for path in raw if path.startswith(trial_prefix)]
            _require(paths, f"raw grader path absent for trial {trial_dir.name}")
            verdicts = {_raw_reward(path) for path in paths}
            _require(len(verdicts) == 1, f"raw grader files disagree for {summary['name']}")
            verdict = next(iter(verdicts))
            _require(summary.get("verdict") == verdict,
                     f"manifest verdict contradicts raw grader for {summary['name']}")
            result_verdict = _result_verdict(result)
            _require(result_verdict is None or result_verdict == verdict,
                     f"result verdict contradicts raw grader for {summary['name']}")

    reporter.check("raw-grader", raw_grader_check)

    def harness_usage_check():
        by_name = {row["name"]: row for row in canonical}
        for summary in manifest["rows"]:
            row = by_name[summary["name"]]
            if row["kind"] != "harness":
                continue
            events = []
            metadata = []
            for raw_row, _, trial_dir, result in _verified_trials(evidence, manifest, canonical):
                if raw_row["name"] == row["name"]:
                    trial_events = _read_usage(trial_dir)
                    trial_metadata = _metadata_r102(result)
                    _require(trial_metadata.get("config") == row["name"],
                             f"metadata config mismatch for {row['name']}")
                    error = _harness_usage_error(row, trial_events, trial_metadata)
                    _require(error is None, f"{row['name']}: {error}")
                    invocation_log = trial_metadata["orchestrator_evidence"]["log"]
                    _require(any(path.name == invocation_log for path in trial_dir.rglob("*")),
                             f"orchestrator invocation log missing for {row['name']}")
                    events.extend(trial_events)
                    metadata.append(trial_metadata)
            _require(events == summary.get("usage"), f"usage summary contradicts raw log for {row['name']}")
            _require(metadata, f"metadata absent for {row['name']}")
            _require(summary.get("review_rounds") == sum(
                value["review_rounds"] for value in metadata),
                f"review round summary contradicts raw metadata for {row['name']}")
            _require(summary.get("quality_only") is any(
                value.get("quality_only") is True for value in metadata),
                f"quality_only summary contradicts raw metadata for {row['name']}")
            orchestrator_values = [value["orchestrator_evidence"] for value in metadata]
            _require(all(value == orchestrator_values[0] for value in orchestrator_values),
                     f"orchestrator evidence differs across trials for {row['name']}")
            _require(summary.get("orchestrator_evidence") == orchestrator_values[0],
                     f"orchestrator evidence summary contradicts raw metadata for {row['name']}")

    reporter.check("harness-usage", harness_usage_check)

    def vanilla_usage_check():
        by_name = {row["name"]: row for row in canonical}
        for summary in manifest["rows"]:
            row = by_name[summary["name"]]
            if row["kind"] != "vanilla":
                continue
            totals = {"input_tokens": 0, "output_tokens": 0}
            for raw_row, _, _, result in _verified_trials(evidence, manifest, canonical):
                if raw_row["name"] != row["name"]:
                    continue
                input_tokens, output_tokens = _find_tokens(result.get("agent_result"))
                _require(input_tokens is not None and output_tokens is not None,
                         f"single-agent totals absent for {row['name']}")
                totals["input_tokens"] += input_tokens
                totals["output_tokens"] += output_tokens
            _require(summary.get("usage") == totals,
                     f"single-agent totals contradict raw result for {row['name']}")

    reporter.check("vanilla-usage", vanilla_usage_check)

    def reviewer_null_check():
        summary = next(row for row in manifest["rows"] if row["name"] == "harness-opus-luna-none")
        _require(summary.get("review_rounds") == 0, "reviewer-null row has nonzero review rounds")
        _require(not any(event.get("role") == "reviewer" for event in summary.get("usage", [])),
                 "reviewer-null row has reviewer usage")

    reporter.check("reviewer-null", reviewer_null_check)

    def codex_orchestrator_check():
        summary = next(row for row in manifest["rows"] if row["name"] == "harness-sol-luna-opus")
        evidence_value = summary.get("orchestrator_evidence")
        _require(isinstance(evidence_value, dict), "Codex orchestrator evidence absent")
        _require(evidence_value.get("vendor") == "codex", "Codex orchestrator vendor mismatch")
        _require(evidence_value.get("model") == "gpt-5.6-sol", "Codex orchestrator model mismatch")
        _require(isinstance(evidence_value.get("log"), str) and evidence_value["log"],
                 "Codex orchestrator invocation log absent")

    reporter.check("codex-orchestrator", codex_orchestrator_check)

    def subagent_check():
        summary = next(row for row in manifest["rows"] if row["name"] == "harness-opus-sub-opus")
        metadata_values = []
        for row, _, _, result in _verified_trials(evidence, manifest, canonical):
            if row["name"] == summary["name"]:
                metadata_values.append(_metadata_r102(result))
        fully_attributed = all(
            _normal_token(event.get("input_tokens")) and _normal_token(event.get("output_tokens"))
            for event in summary.get("usage", [])
        ) and bool(summary.get("usage"))
        fallback = summary.get("quality_only") is True and all(
            isinstance(metadata.get("attribution_probe"), str) and metadata["attribution_probe"]
            for metadata in metadata_values
        )
        _require(fully_attributed or fallback,
                 "subagent row is neither attributed nor marked quality_only with attribution_probe")

    reporter.check("subagent-attribution", subagent_check)
    return 0 if reporter.ok else 1


def build_parser():
    parser = argparse.ArgumentParser(prog="r102-benchmark")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    preflight_parser = subparsers.add_parser("preflight")
    preflight_parser.add_argument("--out", required=True)
    preflight_parser.add_argument("--config-manifest")
    preflight_parser.set_defaults(handler=preflight)

    kill_parser = subparsers.add_parser("kill-test")
    kill_parser.add_argument("--benchmark", required=True)
    kill_parser.add_argument("--task-manifest", required=True)
    kill_parser.add_argument("--config-manifest", required=True)
    kill_parser.add_argument("--trials", required=True, type=int)
    kill_parser.add_argument("--evidence", required=True)
    kill_parser.set_defaults(handler=kill_test)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--evidence", required=True)
    verify_parser.set_defaults(handler=verify)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
