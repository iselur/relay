#!/usr/bin/env bash
# kimi_acp.drive() fail-closed contract (PLAN-009 slice 1) against a deterministic fake
# stdio peer. Pure logic — no sudo, no network, no kimi install. The load-bearing case is
# the C1 regression: a peer that exits 0 WITHOUT a terminal end_turn response must yield a
# nonzero EFFECTIVE status (amendment 2026-07-18) — plus raw-before-parse frame recording,
# agent-request refusal, duplicate/unknown response ids, wrong stop reason, JSON-RPC
# errors, deadline expiry, and a >MAX_ARG_STRLEN (131072) prompt completing through real
# pipes without a write-side deadlock (N4; hardened-chain variant is proven live by
# scripts/kimi-acp-check.sh). Review acp-slice-1 round 1-3 falsifiers are pinned here:
# an end_turn reply to a never-read prompt, and malformed-shape / field-level type
# violations (non-string method, string params on any notification, non-object config
# option even for a foreign session, missing jsonrpc member, numeric sessionId /
# sessionUpdate / content type, boolean response id) each fail closed even when the
# session otherwise completes. Model selection trusts set_model's success response
# (owner decision, amendment 2026-07-18 (3)): a missing or foreign-session read-back no
# longer blocks, model_value is recorded as evidence only, and the failing stage
# discriminates a set_model rejection from a prompt-stage error (negecho).
set -uo pipefail
cd "$(dirname "$0")/.."
PY="${ORCH_TEST_PY:-.venv/bin/python}"
[ -x "$PY" ] || { echo "SKIP kimi_acp_driver.sh: trusted Python runtime absent"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/peer.py" <<'PEER'
import json, os, sys, time

MODE = os.environ["PEER_MODE"]
ALIAS = "kimi-code/k3"

def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

def recv():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)

def note_model(value, sid="s1"):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid,
          "update": {"sessionUpdate": "config_option_update",
                     "configOptions": [{"id": "model", "currentValue": value}]}}})

def chunk(text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1",
          "update": {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": text}}}})

def drain():
    while sys.stdin.readline():
        pass
    sys.exit(0)

m = recv()  # initialize
if MODE == "stalemodel":
    note_model(ALIAS, sid="stale-old")  # review r1 falsifier: pre-session, other session
if MODE == "nojsonrpc":
    send({"id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    drain()
send({"jsonrpc": "2.0", "id": True if MODE == "boolid" else m["id"],
      "result": {"protocolVersion": 99 if MODE == "badversion" else 1,
                 "agentCapabilities": {}}})
if MODE == "badversion":
    drain()
if MODE == "malformed":
    sys.stdout.write("this is not json\n"); sys.stdout.flush()
    drain()

m = recv()  # session/new
if MODE == "agentreq":
    send({"jsonrpc": "2.0", "id": 777, "method": "fs/read_text_file",
          "params": {"path": "/etc/passwd"}})
    drain()
send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
note_model("kimi-code/kimi-for-coding")  # the real CLI's default: NOT the frozen alias
if MODE == "strparams":
    send({"jsonrpc": "2.0", "method": "session/update", "params": "bogus"})
    drain()
# review r2 falsifiers: inject one malformed frame, then keep serving the session
# normally — without the fix the session completes and grades 0
if MODE == "nummethod":
    send({"jsonrpc": "2.0", "method": 7})
if MODE == "unkstrparams":
    send({"jsonrpc": "2.0", "method": "weird/notification", "params": "bogus"})
if MODE == "foreignbadopt":
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "other",
          "update": {"sessionUpdate": "config_option_update",
                     "configOptions": ["not-an-object"]}}})
# review r3 falsifiers: field-level type violations, same inject-then-continue pattern
if MODE == "numsid":
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": 7,
          "update": {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": "x"}}}})
if MODE == "numkind":
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1",
          "update": {"sessionUpdate": 7}}})
if MODE == "numctype":
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1",
          "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": 7}}}})
if MODE == "badopts":
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1",
          "update": {"sessionUpdate": "config_option_update",
                     "configOptions": ["not-an-object"]}}})
    drain()

m = recv()  # session/set_model
if MODE == "modelerr":
    send({"jsonrpc": "2.0", "id": m["id"],
          "error": {"code": -32603, "message": "model not configured"}})
    drain()
send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
if MODE == "negecho":
    note_model(m["params"]["modelId"])  # echo whatever was asked, even a bogus alias
elif MODE not in ("noconfirm", "stalemodel"):
    note_model(ALIAS)

m = recv()  # session/set_mode
send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
if MODE in ("noread", "noreadhang"):
    # answer the prompt request (next id) WITHOUT ever reading it — review r1 falsifier
    send({"jsonrpc": "2.0", "id": m["id"] + 1, "result": {"stopReason": "end_turn"}})
    if MODE == "noread":
        sys.exit(0)
    time.sleep(60)

m = recv()  # session/prompt
ptext = m["params"]["prompt"][0]["text"]
if MODE == "exit0noterm":
    chunk("partial answer")
    sys.exit(0)  # clean exit, no terminal response — the C1 case
if MODE == "eofmid":
    chunk("half")
    sys.exit(1)
if MODE in ("prompterr", "negecho"):
    send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32000, "message": "boom"}})
elif MODE == "badstop":
    chunk("truncated")
    send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "max_tokens"}})
elif MODE == "dupid":
    send({"jsonrpc": "2.0", "id": 1, "result": {}})  # stale duplicate of an answered id
elif MODE == "slow":
    time.sleep(60)
elif MODE == "bigecho":
    chunk("LEN=%d" % len(ptext.encode()))
    send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
else:  # ok
    chunk("hello ")
    chunk("world")
    send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
drain()
PEER

if TMP="$TMP" "$PY" - <<'PY'
import importlib.util, json, os, subprocess, sys

spec = importlib.util.spec_from_file_location("kimi_acp", "scripts/kimi_acp.py")
ka = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ka)

TMP = os.environ["TMP"]
PEER = os.path.join(TMP, "peer.py")
ALIAS = "kimi-code/k3"
fails = []

def run(mode, prompt="ping", alias=ALIAS, deadline=15):
    sink_path = os.path.join(TMP, mode + ".events.jsonl")
    with open(sink_path, "wb") as sink:
        proc = subprocess.Popen([sys.executable, PEER], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env={**os.environ, "PEER_MODE": mode})
        res = ka.drive(proc, prompt_text=prompt, cwd="/tmp", model_alias=alias,
                       frame_sink=sink, deadline_s=deadline)
    res["events"] = open(sink_path, "rb").read()
    return res

def case(name, cond, res):
    if cond:
        print(f"  ok: {name}")
    else:
        fails.append(name)
        print(f"  FAIL: {name}: {({k: v for k, v in res.items() if k != 'events'})}")

r = run("ok")
case("happy path grades 0", r["effective_status"] == 0 and r["failure"] is None
     and r["stop_reason"] == "end_turn" and r["proc_exit"] == 0, r)
case("happy path recovers chunk text", r["final_message"] == "hello world", r)
case("happy path records the model read-back", r["model_value"] == ALIAS, r)
first = json.loads(r["events"].splitlines()[0])
case("raw frames recorded from the handshake on", first.get("id") == 1
     and first["result"]["protocolVersion"] == 1, r)

r = run("exit0noterm")
case("C1: clean exit 0 without end_turn is NOT success",
     r["proc_exit"] == 0 and r["effective_status"] != 0 and r["failure"] == "eof", r)

r = run("malformed")
case("malformed frame fails closed", r["effective_status"] != 0
     and r["failure"] == "malformed_frame", r)
case("malformed frame still raw-recorded before parse",
     b"this is not json" in r["events"], r)

r = run("prompterr")
case("JSON-RPC error on prompt fails closed", r["effective_status"] != 0
     and r["failure"] == "jsonrpc_error", r)

r = run("modelerr")
case("JSON-RPC error on set_model fails closed at that stage", r["effective_status"] != 0
     and r["failure"] == "jsonrpc_error" and r["stage"] == "session/set_model", r)

r = run("noconfirm")
case("missing read-back no longer blocks, and the default stays visible as evidence",
     r["effective_status"] == 0 and r["model_value"] == "kimi-code/kimi-for-coding", r)

r = run("badversion")
case("protocol version mismatch fails closed", r["effective_status"] != 0
     and r["failure"] == "protocol_version", r)

r = run("badstop")
case("non-end_turn stop reason fails closed", r["effective_status"] != 0
     and r["failure"] == "stop_reason", r)
case("chunks before a bad stop are still recovered",
     r["final_message"] == "truncated", r)

r = run("eofmid")
case("EOF mid-stream fails closed with chunks kept", r["effective_status"] != 0
     and r["failure"] == "eof" and r["final_message"] == "half", r)

r = run("dupid")
case("duplicate/unknown response id fails closed", r["effective_status"] != 0
     and r["failure"] == "unexpected_response_id", r)

r = run("slow", deadline=3)
case("deadline expiry fails closed and reaps the peer", r["effective_status"] != 0
     and r["failure"] == "deadline" and r["proc_exit"] is not None, r)

r = run("agentreq")
case("agent-to-client request is refused and fails closed",
     r["effective_status"] != 0 and r["failure"] == "agent_request", r)

r = run("noread", prompt="y" * 200_000)
case("r1: end_turn for a never-read prompt fails closed",
     r["effective_status"] != 0 and r["failure"] == "write_failed", r)

r = run("noreadhang", prompt="y" * 200_000, deadline=3)
case("r1: unread prompt held open is a write stall",
     r["effective_status"] != 0 and r["failure"] == "write_stall", r)

r = run("nojsonrpc")
case("r1: frame missing the jsonrpc member fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("strparams")
case("r1: session/update with string params fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("badopts")
case("r1: non-object config option entry fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("stalemodel")
case("r1: foreign-session read-back is never consumed as this session's model",
     r["effective_status"] == 0 and r["model_value"] == "kimi-code/kimi-for-coding", r)

r = run("nummethod")
case("r2: non-string method fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("unkstrparams")
case("r2: unknown notification with string params fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("foreignbadopt")
case("r2: foreign-session non-object config option fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("numsid")
case("r3: numeric sessionId fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("numkind")
case("r3: numeric sessionUpdate discriminator fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("numctype")
case("r3: numeric content type fails closed",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("boolid")
case("r3: boolean response id is not our integer request id (True == 1)",
     r["effective_status"] != 0 and r["failure"] == "malformed_frame", r)

r = run("negecho", alias="kimi-code/bogus-echo")
case("r3: prompt-stage error is discriminated by its stage (negative-control)",
     r["effective_status"] != 0 and r["failure"] == "jsonrpc_error"
     and r["stage"] == "session/prompt"
     and r["model_value"] == "kimi-code/bogus-echo", r)

big = "x" * 140_000  # > MAX_ARG_STRLEN 131072
r = run("bigecho", prompt=big)
case("oversized prompt completes with no write deadlock",
     r["effective_status"] == 0 and f"LEN={len(big.encode())}" in r["final_message"], r)

sys.exit(1 if fails else 0)
PY
then echo "PASS kimi_acp_driver.sh"; exit 0
else echo "FAIL kimi_acp_driver.sh"; exit 1; fi
