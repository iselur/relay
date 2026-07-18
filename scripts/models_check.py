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
VENDORS = ("claude", "codex", "kimi")
SECTIONS = ("schema_version", "roles", "cli_aliases", "vendor_patterns")
# Owner decision 2026-07-18: vendors are matched by NAME PATTERN, not a per-model registry.
# Only the vendors that need a non-default launch path are declared — `claude` runs as an
# in-session subagent, `kimi` needs its own CLI and has no unisolated mode. Everything else
# falls through to DEFAULT_VENDOR, the sandboxed external-CLI path, so a model nobody has
# heard of is confined rather than refused, and adding one costs no config at all.
DEFAULT_VENDOR = "codex"


def _nonempty_str(v) -> bool:
    return isinstance(v, str) and bool(v.strip())


def classify(model: str, cfg: dict) -> str:
    """The ONE vendor classifier: case-insensitive substring match of the model id against each
    declared vendor's patterns, DEFAULT_VENDOR when nothing matches. A name matching two
    different vendors is ambiguous and raises — picking one silently would launch the wrong CLI
    under the wrong isolation, so it fails closed instead."""
    lowered = (model or "").lower()
    hits = sorted({v for v, pats in (cfg.get("vendor_patterns") or {}).items()
                   if any(p.lower() in lowered for p in pats)})
    if len(hits) > 1:
        raise ValueError(f"model {model!r} matches patterns for more than one vendor "
                         f"({'/'.join(hits)}); no vendor can be chosen safely")
    return hits[0] if hits else DEFAULT_VENDOR


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

    aliases = cfg.get("cli_aliases")
    if aliases is not None:
        if not isinstance(aliases, dict):
            errs.append("cli_aliases must be an object")
        else:
            for k, v in aliases.items():
                if not _nonempty_str(v):
                    errs.append(f"cli_aliases.{k} must be a non-empty string")

    vp = cfg.get("vendor_patterns")
    if vp is not None and not isinstance(vp, dict):
        errs.append("vendor_patterns must be an object")
        vp = {}
    vp = vp if isinstance(vp, dict) else {}
    for v, pats in sorted(vp.items()):
        if v not in VENDORS:
            errs.append(f"vendor_patterns.{v} must be one of {'/'.join(VENDORS)}")
            continue
        if v == DEFAULT_VENDOR:
            errs.append(f"vendor_patterns.{v} is the default vendor and needs no patterns")
        if not isinstance(pats, list) or not pats or not all(_nonempty_str(p) for p in pats):
            errs.append(f"vendor_patterns.{v} must be a non-empty list of non-empty strings")
    # A pattern that also matches ANOTHER vendor's pattern makes every id hitting both
    # unclassifiable at launch. Catch it here, in the owner's config, not at dispatch time.
    if not errs:
        for m in sorted(named_models):
            try:
                classify(m, cfg)
            except ValueError as exc:
                errs.append(str(exc))
    if isinstance(aliases, dict):
        # R73 round-1 review (blocking): an alias whose TARGET is itself a declared model would
        # let one model masquerade as another at invocation time — resolution would compare the
        # distinct config ids while the CLI runs the alias target (self-review laundered through
        # cli_aliases). Aliases map a model id to its vendor-CLI name, never to another model.
        for k, v in sorted(aliases.items()):
            if _nonempty_str(v) and v != k and v in named_models:
                errs.append(f"cli_aliases.{k} targets another declared model ({v}): an alias "
                            f"maps a model id to its CLI name, never to a different model")
        # Kimi slice 3 (rounds 1-2 review): the kimi CLI accepts only its provider aliases,
        # never relay model ids — a kimi-vendor model without a cli_aliases entry would freeze
        # an alias map its adapter must refuse at every invocation, and an IDENTITY alias
        # (model id mapped to itself) would launder the raw relay id straight through the
        # translation. Required at validation: a non-empty alias DISTINCT from the model id.
        for m in sorted(named_models):
            if (not errs and classify(m, cfg) == "kimi"
                    and (not _nonempty_str(aliases.get(m)) or aliases.get(m) == m)):
                errs.append(f"{m} classifies as kimi-vendor but cli_aliases has no distinct "
                            f"entry for it (the kimi CLI accepts only its provider aliases, "
                            f"never relay model ids)")

    # Owner decision 2026-07-16: vendor PAIRING is the owner's call, made by editing this
    # config — nothing here polices same- vs cross-vendor. The one mechanical rule that remains:
    # same-MODEL self-review is refused at resolution in dispatch.py ("nothing reviews its
    # own work" — the one hard limit the rulebook keeps).
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
    try:
        print(classify(argv[3], cfg))
    except ValueError as exc:
        print(f"models_check: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
