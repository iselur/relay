#!/usr/bin/env python3
"""The ONE validator for scripts/models.json, shared by every consumer (round-1 review, both
blocking findings): scripts/dispatch.py imports validate(); scripts/review and scripts/codex-plan
invoke the CLI, so the shell consumers check the WHOLE config — not just the one value they read.
Stdlib only: the shell consumers must not need the dispatcher venv.

Usage:
  models_check.py CONFIG                 validate only
  models_check.py CONFIG get DOTTED.PATH validate, then print the (non-empty string) value
  models_check.py CONFIG vendor MODEL    validate, then print the declared vendor or 'unknown'
Any validation failure prints every error to stderr and exits 2, printing no value at all.
"""
import json
import sys

ROLES = ("orchestrator", "spec_author", "utility_subagent", "worker",
         "bound_reviewer", "orchestrator_artifact_reviewer")
VENDORS = ("claude", "codex")
SECTIONS = ("schema_version", "roles", "reviewer_failover", "cli_aliases", "vendor_map")
# Contradiction TRIPWIRE, not a classifier (round-1 review, finding 1): a name carrying a known
# vendor prefix may not be declared as the other vendor — that misdeclaration is exactly what
# would let same-vendor review pass. A name with no known prefix still needs its explicit
# vendor_map entry; nothing here ever infers a vendor for it.
PREFIX_RULES = (("claude", "claude"), ("gpt-", "codex"), ("codex", "codex"))


def _nonempty_str(v) -> bool:
    return isinstance(v, str) and bool(v.strip())


def validate(cfg) -> list:
    """Every problem in the config, as a list of messages; [] means valid."""
    if not isinstance(cfg, dict):
        return ["config is not a JSON object"]
    errs = []
    for k in SECTIONS:
        if k not in cfg:
            errs.append(f"missing required section: {k}")
    for k in sorted(set(cfg) - set(SECTIONS)):
        errs.append(f"unknown section: {k}")
    if "schema_version" in cfg and cfg["schema_version"] != "1":
        errs.append("schema_version must be the string '1'")

    named_models = set()
    roles = cfg.get("roles")
    if roles is not None and not isinstance(roles, dict):
        errs.append("roles must be an object")
        roles = {}
    roles = roles or {}
    for r in ROLES:
        if r not in roles:
            errs.append(f"missing role: {r}")
            continue
        entry = roles[r]
        if not isinstance(entry, dict):
            errs.append(f"roles.{r} must be an object")
            continue
        for k in sorted(set(entry) - {"model", "effort"}):
            errs.append(f"roles.{r} has unknown key: {k}")
        for k in ("model", "effort"):
            if not _nonempty_str(entry.get(k)):
                errs.append(f"roles.{r}.{k} must be a non-empty string")
        if _nonempty_str(entry.get("model")):
            named_models.add(entry["model"])
    for r in sorted(set(roles) - set(ROLES)):
        errs.append(f"unknown role: {r}")

    fo = cfg.get("reviewer_failover")
    if fo is not None:
        if not isinstance(fo, dict):
            errs.append("reviewer_failover must be an object")
        else:
            for k in sorted(set(fo) - {"trigger_model", "fallback_model"}):
                errs.append(f"reviewer_failover has unknown key: {k}")
            for k in ("trigger_model", "fallback_model"):
                if not _nonempty_str(fo.get(k)):
                    errs.append(f"reviewer_failover.{k} must be a non-empty string")
                else:
                    named_models.add(fo[k])

    aliases = cfg.get("cli_aliases")
    if aliases is not None:
        if not isinstance(aliases, dict):
            errs.append("cli_aliases must be an object")
        else:
            for k, v in aliases.items():
                if not _nonempty_str(v):
                    errs.append(f"cli_aliases.{k} must be a non-empty string")

    vm = cfg.get("vendor_map")
    if vm is not None and not isinstance(vm, dict):
        errs.append("vendor_map must be an object")
        vm = {}
    vm = vm if isinstance(vm, dict) else {}
    for m, v in sorted(vm.items()):
        if v not in VENDORS:
            errs.append(f"vendor_map.{m} must be one of {'/'.join(VENDORS)}, not {v!r}")
            continue
        for prefix, vendor in PREFIX_RULES:
            if m.lower().startswith(prefix) and v != vendor:
                errs.append(f"vendor_map contradiction: {m} declared as {v}")
    if "vendor_map" in cfg:
        # Completeness: every model the config itself names must carry a vendor declaration,
        # or dispatch could launch a model that scripts/review can never classify.
        for m in sorted(named_models - set(vm)):
            errs.append(f"model named in config but not declared in vendor_map: {m}")
    return errs


def load_and_validate(path: str) -> dict:
    """Read, decode, parse, and validate; raises SystemExit(2) with all errors on stderr."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"models_check: unreadable config {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)
    try:
        cfg = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"models_check: invalid JSON in {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)
    errs = validate(cfg)
    if errs:
        for e in errs:
            print(f"models_check: {path}: {e}", file=sys.stderr)
        raise SystemExit(2)
    return cfg


def main(argv) -> int:
    if len(argv) < 2 or (len(argv) > 2 and argv[2] not in ("get", "vendor")) \
            or (len(argv) > 2 and len(argv) != 4):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cfg = load_and_validate(argv[1])
    if len(argv) == 2:
        return 0
    if argv[2] == "get":
        node = cfg
        for part in argv[3].split("."):
            if not isinstance(node, dict) or part not in node:
                print(f"models_check: no such config path: {argv[3]}", file=sys.stderr)
                return 2
            node = node[part]
        if not _nonempty_str(node):
            print(f"models_check: {argv[3]} is not a non-empty string", file=sys.stderr)
            return 2
        print(node)
        return 0
    vendor = cfg["vendor_map"].get(argv[3], "unknown")
    print(vendor if vendor in VENDORS else "unknown")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
