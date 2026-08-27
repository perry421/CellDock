"""CellDock LAN Bridge MVP — end-to-end test against live Mac process.

Protocol: ws://<mac-ip>:48765
Token file: ~/Library/Application Support/CellDock/remote-bridge-token

Expected PASS on a module with valid SIM (中国电信 tested here).
"""
import asyncio, json, os, sys, websockets
from pathlib import Path

TOKEN = (Path.home() / "Library/Application Support/CellDock/remote-bridge-token").read_text().strip()
TEST_NUMBER = os.environ.get("CELLDOCK_TEST_PHONE_NUMBER")
URI = "ws://127.0.0.1:48765"
TERMINAL = {"idle", "ended", "error"}

async def main():
    if not TEST_NUMBER:
        raise SystemExit("Set CELLDOCK_TEST_PHONE_NUMBER to a safe test destination before running.")
    ok = 0
    fail = 0
    def report(label, cond, detail=""):
        nonlocal ok, fail
        if cond:
            print(f"PASS {label}")
            ok += 1
        else:
            print(f"FAIL {label}: {detail}")
            fail += 1

    async with websockets.connect(URI, max_size=65536) as ws:
        welcome = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        report("welcome frame", welcome["type"] == "welcome" and welcome["protocol"] == 1)

        await ws.send(json.dumps({"type": "auth", "token": "WRONG"}))
        err = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        report("wrong-token rejected", err["type"] == "error" and err["code"] == "auth_failed")

        await ws.send(json.dumps({"type": "auth", "token": TOKEN}))
        frames = []
        for _ in range(2):
            try:
                frames.append(json.loads(await asyncio.wait_for(ws.recv(), timeout=8)))
            except asyncio.TimeoutError:
                report("auth-status frame received", False, "timeout")
                frames = None
                break
        if frames:
            device = next((m for m in frames if m["type"] == "device_status"), None)
            call0 = next((m for m in frames if m["type"] == "call_state"), None)
            report("device_online", device is not None and device.get("moduleOnline"))
            report("device_sim_ready", device is not None and device.get("simReady"))
            report("operator_name_present", device is not None and device.get("operatorName"))
            report("call_state_initial_idle_or_error", call0 is not None and call0["state"] in ("idle", "unavailable", "error"))

        # Dial the explicitly supplied test destination and wait until terminal state.
        await ws.send(json.dumps({"type": "dial", "number": TEST_NUMBER}))
        states = []
        dial_result = None
        t0 = asyncio.get_event_loop().time()
        while asyncio.get_event_loop().time() - t0 < 70:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=4))
                t = m.get("type")
                if t == "result":
                    if m.get("action") == "dial":
                        dial_result = m
                    continue
                if t == "call_state":
                    states.append(m["state"])
                    print(f"  state -> {m['state']} raw={m.get('rawPhase')}")
                if any(s in TERMINAL for s in states):
                    break
            except asyncio.TimeoutError:
                break
        report("dial result ok", dial_result is not None and dial_result.get("ok") is True)
        report("call reached dialing", "dialing" in states)
        report("call returned to terminal state", any(s in TERMINAL for s in states))

        # hangup when idle — must return explicit failure, not crash
        await ws.send(json.dumps({"type": "hangup"}))
        hangup_resp = None
        t0 = asyncio.get_event_loop().time()
        while asyncio.get_event_loop().time() - t0 < 10:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
                if m.get("type") == "result" and m.get("action") == "hangup":
                    hangup_resp = m
                    break
            except asyncio.TimeoutError:
                break
        report("hangup response received", hangup_resp is not None)
        report("hangup blocked when idle", hangup_resp is not None and hangup_resp.get("ok") is False)

        # invalid number — client-side rejection
        await ws.send(json.dumps({"type": "dial", "number": "abc!"}))
        inv = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        report("invalid_number rejected before modem", inv.get("type") == "error" and inv.get("code") == "invalid_number")

        # answer when idle — must return explicit failure
        await ws.send(json.dumps({"type": "answer"}))
        ans = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        report("answer when idle gives result", ans.get("type") == "result" and ans.get("action") == "answer")

        # get_status round trip — must yield both frames
        await ws.send(json.dumps({"type": "get_status"}))
        got = set()
        t0 = asyncio.get_event_loop().time()
        while len(got) < 2 and asyncio.get_event_loop().time() - t0 < 5:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
                got.add(m.get("type"))
            except asyncio.TimeoutError:
                break
        report("get_status yields device_status", "device_status" in got)
        report("get_status yields call_state", "call_state" in got)

    print(f"\nTOTAL {ok + fail} PASS={ok} FAIL={fail}")
    raise SystemExit(1 if fail else 0)

asyncio.run(main())
