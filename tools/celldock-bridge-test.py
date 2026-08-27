import asyncio, json, os, websockets
from pathlib import Path

TOKEN = (Path.home() / "Library/Application Support/CellDock/remote-bridge-token").read_text().strip()
TEST_NUMBER = os.environ.get("CELLDOCK_TEST_PHONE_NUMBER")
URI = "ws://127.0.0.1:48765"

async def main():
    if not TEST_NUMBER:
        raise SystemExit("Set CELLDOCK_TEST_PHONE_NUMBER to a safe test destination before running.")
    results = {}
    async def check(label, cond, detail=""):
        if cond:
            print(f"PASS {label}")
            results[label] = True
        else:
            print(f"FAIL {label}: {detail}")
            results[label] = False

    async with websockets.connect(URI, max_size=65536) as ws:
        welcome = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        await check("welcome", welcome["type"] == "welcome" and welcome["protocol"] == 1)

        await ws.send(json.dumps({"type": "auth", "token": "WRONG"}))
        err = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        await check("wrong-token", err["type"] == "error" and err["code"] == "auth_failed")

        await ws.send(json.dumps({"type": "auth", "token": TOKEN}))
        frames = []
        for _ in range(2):
            frames.append(json.loads(await asyncio.wait_for(ws.recv(), timeout=8)))
        device = next((m for m in frames if m["type"] == "device_status"), None)
        call0 = next((m for m in frames if m["type"] == "call_state"), None)
        await check("device_online", device is not None and device.get("moduleOnline"))
        await check("device_sim_ready", device is not None and device.get("simReady"))
        await check("call_state_initial", call0 is not None and call0["state"] in ("idle", "unavailable", "error"))
        await check("signal_bars_int", device is not None and isinstance(device.get("signalBars"), int))

        # Dial the explicitly supplied test destination and watch the state.
        await ws.send(json.dumps({"type": "dial", "number": TEST_NUMBER}))
        states = []
        t0 = asyncio.get_event_loop().time()
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            t = m.get("type")
            if t == "result":
                actions = results.setdefault("results", {})
                actions[m.get("action")] = m
                continue
            if t == "call_state":
                states.append(m["state"])
                print("  state:", m["state"], "raw=", m.get("rawPhase"))
            if "dialing" in states or m.get("state") in ("idle", "error", "ended"):
                break
            if asyncio.get_event_loop().time() - t0 > 65:
                break
        await check("dial_result_ok", results["results"].get("dial", {}).get("ok") is True)
        await check("dial_reached_dialing", "dialing" in states)
        await check("dial_came_back_to_terminal", any(s in ("idle", "error", "ended") for s in states))

        # hangup on idle → expected failure (no active call), not a crash
        await ws.send(json.dumps({"type": "hangup"}))
        t0 = asyncio.get_event_loop().time()
        hangup_resp = None
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
            if m.get("type") == "result" and m.get("action") == "hangup":
                hangup_resp = m
                break
            if m.get("type") == "call_state":
                print("  state:", m["state"])
            if asyncio.get_event_loop().time() - t0 > 10:
                break
        await check("hangup_response_received", hangup_resp is not None)
        await check("hangup_blocked_when_idle", hangup_resp is not None and not hangup_resp["ok"])

        # invalid number
        await ws.send(json.dumps({"type": "dial", "number": "abc!"}))
        inv = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        await check("invalid_number_rejected", inv.get("type") == "error" and inv.get("code") == "invalid_number")

        # answer when idle
        await ws.send(json.dumps({"type": "answer"}))
        ans = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        await check("answer_when_idle_gives_result", ans.get("type") == "result" and ans.get("action") == "answer")

        # get_status round trip
        await ws.send(json.dumps({"type": "get_status"}))
        gp = 0
        while gp < 3:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            if m.get("type") in ("device_status", "call_state"):
                gp += 1
        await check("get_status_returns_frames", gp >= 2)

        total = len(results)
        pass_n = sum(1 for v in results.values() if v is True)
        fail_n = total - pass_n
        print(f"\nTOTAL {total} PASS={pass_n} FAIL={fail_n}")

asyncio.run(main())
