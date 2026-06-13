#!/usr/bin/env python3
"""End-to-end regression for the converge transition gate (required_gates).

Proves the FSM enforces `no-blockers` server-side: a reviewer's verdict event
gates the advance transition, so you cannot escalate/approve past a blocker, and
a missing verdict cannot advance at all (fail-closed). Simulates the reviewer
(posts a verdict event) and the orchestrator (attempts a transition) with curl-
level calls — no agent runtime required, fully deterministic.

Run against a scratch instance (auth disabled):
    ./zig-out/bin/nulltickets --port 7800 --db /tmp/nt-gate.db &
    python3 tests/gate_e2e.py
Exits 0 if all checks pass.
"""
import json, sys, urllib.request, urllib.error

BASE = "http://127.0.0.1:7800"


def req(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw}


PIPELINE = {
    "name": "converge-review",
    "definition": {
        "initial": "staff-review",
        "states": {
            "staff-review": {"agent_role": "v_staff-engineer", "description": "Staff engineer review"},
            "cto-review": {"agent_role": "v_cto", "description": "CTO converge gate"},
            "approved": {"terminal": True, "description": "Approved — no blockers from any persona"},
            "blocked": {"terminal": True, "description": "Blocked by review blockers"},
        },
        "transitions": [
            {"from": "staff-review", "to": "cto-review", "trigger": "escalate", "required_gates": ["no-blockers"]},
            {"from": "staff-review", "to": "blocked", "trigger": "block"},
            {"from": "cto-review", "to": "approved", "trigger": "approve", "required_gates": ["no-blockers"]},
            {"from": "cto-review", "to": "blocked", "trigger": "block"},
        ],
    },
}

results = []


def check(name, cond, detail=""):
    cond = bool(cond)
    results.append(cond)
    print(f"  {'OK  ' if cond else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not cond else ""))


def err_code(body):
    e = body.get("error")
    return e.get("code") if isinstance(e, dict) else e


st, pj = req("POST", "/pipelines", PIPELINE)
pid = pj.get("id")
check("pipeline registered", st in (200, 201) and pid, f"status={st} body={pj}")


def new_task(title):
    req("POST", "/tasks", {"pipeline_id": pid, "title": title, "description": "diff under review"})


def claim(role):
    return req("POST", "/leases/claim", {"agent_id": "sim-" + role, "agent_role": role, "lease_ttl_ms": 300000})


print("\nScenario A — blocker found: escalate is gated shut, block fires")
new_task("PR with a blocker")
st, c = claim("v_staff-engineer")
tok, rid, stage = c.get("lease_token"), c.get("run", {}).get("id"), c.get("task", {}).get("stage")
check("claimed staff-review", st == 200 and rid, f"status={st}")
st, _ = req("POST", f"/runs/{rid}/events", {"kind": "verdict", "data": {"blockers": 2}}, token=tok)
check("posted verdict blockers=2", st in (200, 201), f"status={st}")
st, e = req("POST", f"/runs/{rid}/transition", {"trigger": "escalate", "expected_stage": stage}, token=tok)
check("escalate REJECTED by gate (409)", st == 409 and err_code(e) == "gate_not_satisfied", f"status={st} body={e}")
st, b = req("POST", f"/runs/{rid}/transition", {"trigger": "block", "expected_stage": stage}, token=tok)
check("block accepted -> blocked", st == 200 and b.get("new_stage") == "blocked", f"status={st} body={b}")

print("\nScenario B — clean through both personas: escalate then approve")
new_task("clean PR")
st, c = claim("v_staff-engineer")
tok, rid, stage = c.get("lease_token"), c.get("run", {}).get("id"), c.get("task", {}).get("stage")
check("claimed staff-review", st == 200 and rid, f"status={st}")
req("POST", f"/runs/{rid}/events", {"kind": "verdict", "data": {"blockers": 0}}, token=tok)
st, e = req("POST", f"/runs/{rid}/transition", {"trigger": "escalate", "expected_stage": stage}, token=tok)
check("escalate accepted -> cto-review", st == 200 and e.get("new_stage") == "cto-review", f"status={st} body={e}")
st, c = claim("v_cto")
tok, rid, stage = c.get("lease_token"), c.get("run", {}).get("id"), c.get("task", {}).get("stage")
check("claimed cto-review", st == 200 and rid and stage == "cto-review", f"status={st} stage={stage}")
req("POST", f"/runs/{rid}/events", {"kind": "verdict", "data": {"blockers": 0}}, token=tok)
st, a = req("POST", f"/runs/{rid}/transition", {"trigger": "approve", "expected_stage": stage}, token=tok)
check("approve accepted -> approved", st == 200 and a.get("new_stage") == "approved", f"status={st} body={a}")

print("\nScenario C — no verdict posted: cannot advance at all (fail-closed)")
new_task("PR with no review")
st, c = claim("v_staff-engineer")
tok, rid, stage = c.get("lease_token"), c.get("run", {}).get("id"), c.get("task", {}).get("stage")
check("claimed staff-review", st == 200 and rid, f"status={st}")
st, e = req("POST", f"/runs/{rid}/transition", {"trigger": "escalate", "expected_stage": stage}, token=tok)
check("escalate REJECTED (no verdict, 409)", st == 409 and err_code(e) == "gate_not_satisfied", f"status={st} body={e}")

ok = all(results)
print(f"\n{'=' * 50}\n{'ALL PASSED' if ok else 'SOME FAILED'}: {sum(results)}/{len(results)} checks")
sys.exit(0 if ok else 1)
