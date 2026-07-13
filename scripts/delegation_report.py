#!/usr/bin/env python3
"""Report delegated attempts and direct control-plane merges as JSON.

This is intentionally standalone and read-only.  It does not share code with the
dispatcher so running a report cannot invoke or mutate orchestration state.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


RISK_CLASSES = ("low", "default", "high")


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def read_risk_class(spec_path: Path) -> str:
    """Return a recognized top-level risk_class, otherwise unclassified."""
    try:
        text = spec_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return "unclassified"

    try:
        import yaml  # type: ignore[import-not-found]

        document = yaml.safe_load(text)
        risk = document.get("risk_class") if isinstance(document, dict) else None
    except ImportError:
        # The project pins PyYAML, but retaining a narrow fallback makes an absent
        # optional dependency fail closed to "unclassified" rather than crashing.
        match = re.search(
            r"(?m)^risk_class\s*:\s*(['\"]?)(low|default|high)\1\s*(?:#.*)?$",
            text,
        )
        risk = match.group(2) if match else None
    except Exception:
        risk = None

    return risk if risk in RISK_CLASSES else "unclassified"


def attempt_directories(attempts_dir: Path) -> list[Path]:
    if not attempts_dir.is_dir():
        return []

    attempts: list[Path] = []
    try:
        spec_directories = sorted(attempts_dir.iterdir(), key=lambda path: path.name)
    except OSError:
        return []
    for spec_directory in spec_directories:
        if not spec_directory.is_dir():
            continue
        try:
            candidates = sorted(spec_directory.iterdir(), key=lambda path: path.name)
        except OSError:
            continue
        for candidate in candidates:
            if candidate.is_dir() and (
                (candidate / "launch.json").is_file()
                or (candidate / "result.json").is_file()
            ):
                attempts.append(candidate)
    return attempts


def attempt_spec_id(attempt_dir: Path, launch: dict[str, Any] | None,
                    result: dict[str, Any] | None) -> str:
    for evidence in (launch, result):
        spec_id = evidence.get("spec_id") if evidence else None
        if isinstance(spec_id, str) and spec_id:
            return spec_id
    return attempt_dir.parent.name


def scan_attempts(attempts_dir: Path, specs_dir: Path) -> tuple[dict[str, int], int, int]:
    by_risk = {risk: 0 for risk in (*RISK_CLASSES, "unclassified")}
    merged = 0
    risk_cache: dict[str, str] = {}
    attempts = attempt_directories(attempts_dir)

    for attempt_dir in attempts:
        launch = read_json(attempt_dir / "launch.json")
        result = read_json(attempt_dir / "result.json")
        spec_id = attempt_spec_id(attempt_dir, launch, result)
        if spec_id not in risk_cache:
            risk_cache[spec_id] = read_risk_class(specs_dir / f"{spec_id}.yaml")
        by_risk[risk_cache[spec_id]] += 1
        if result is not None and result.get("merged") is True:
            merged += 1

    return by_risk, len(attempts), merged


def git_output(repo: Path, *args: str) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo), *args],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    return completed.stdout if completed.returncode == 0 else None


def merged_branch(message: str) -> str | None:
    """Extract a merged branch from common Git and GitHub merge messages."""
    patterns = (
        r"^Merge (?:remote-tracking )?branch ['\"]([^'\"]+)['\"]",
        r"^Merge pull request #\d+ from ([^\s]+)",
    )
    branch = None
    for pattern in patterns:
        match = re.search(pattern, message, re.MULTILINE)
        if match:
            branch = match.group(1)
            break
    if branch is None:
        return None

    branch = re.sub(r"^(?:refs/heads/|refs/remotes/|remotes/)", "", branch)
    branch = re.sub(r"^origin/", "", branch)
    # GitHub records heads as owner/branch.  Preserve the actual branch portion
    # for the codex namespace while leaving unrelated names non-codex.
    codex_marker = branch.find("/codex/")
    if codex_marker >= 0:
        branch = branch[codex_marker + 1:]
    return branch


def scan_merges(repo: Path) -> tuple[int, int, str | None]:
    branch_output = git_output(repo, "branch", "--show-current")
    branch = branch_output.strip() if branch_output and branch_output.strip() else None
    log = git_output(repo, "log", "--merges", "--format=%B%x00", "HEAD")
    if log is None:
        return 0, 0, branch

    codex = 0
    direct = 0
    for message in log.split("\x00"):
        if not message.strip():
            continue
        name = merged_branch(message)
        if name is not None and name.startswith("codex/"):
            codex += 1
        else:
            direct += 1
    return codex, direct, branch


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--attempts-dir", type=Path, default=root / ".orchestrator" / "attempts")
    parser.add_argument("--specs-dir", type=Path, default=root / "specs")
    parser.add_argument("--repo", type=Path, default=root)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    attempts_dir = args.attempts_dir.absolute()
    specs_dir = args.specs_dir.absolute()
    repo = args.repo.absolute()

    by_risk, attempts_total, merged_total = scan_attempts(attempts_dir, specs_dir)
    codex_merges, direct_merges, branch = scan_merges(repo)
    report = {
        "codex_attempts_by_risk_class": by_risk,
        "codex_attempts_total": attempts_total,
        "codex_merged_total": merged_total,
        "claude_direct_merges": direct_merges,
        "codex_branch_merges": codex_merges,
        "window": {
            "attempts": f"all evidence directories under {attempts_dir}",
            "merges": f"all merge commits reachable from HEAD in {repo}",
            "current_branch": branch,
        },
    }
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
