#!/usr/bin/env python3
"""Failure-path scenarios for backend.py (each runs a real backend + whisper-server).

  mixed     Korean → English verse → short Korean phrase: nothing may come back translated
  killsrv   whisper-server is killed mid-lecture: every sentence must still be transcribed
  quitsave  정지 then quit 0.3 s later: the save must complete (all lines + 출석 section)
  accident  start/stop within 1.5 s: no files may be left behind
Usage: scenarios.py <outdir> [names…]
"""
import json, os, signal, subprocess, sys, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(sys.argv[1])
NAMES = sys.argv[2:] or ["mixed", "killsrv", "quitsave", "accident"]
PY = str(ROOT / ".venv/bin/python")


def run(name, files, plan, live=True):
    out = OUT / name
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LECTURE_OUT_DIR=str(out))
    if live:
        env.update(LECTURE_TAP_BIN=str(ROOT / "tests/fake_tap.py"), FAKE_TAP_FILES=":".join(files))
    p = subprocess.Popen([PY, "backend.py"], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=open(ROOT / f"logs/scenario-{name}.log", "w"), env=env, text=True, bufsize=1)
    events, t0 = [], time.time()

    def send(o):
        try:
            p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass

    def reader():
        for line in p.stdout:
            ev = json.loads(line)
            ev["_t"] = round(time.time() - t0, 2)
            events.append(ev)
    th = threading.Thread(target=reader, daemon=True)
    th.start()
    while not any(e["ev"] == "engine" and e["state"] in ("ready", "error") for e in events):
        time.sleep(0.1)
    plan(send, events, p)
    try:
        p.wait(timeout=240)
    except subprocess.TimeoutExpired:
        p.kill()
        events.append({"ev": "TIMEOUT"})
    th.join(timeout=2)
    txts = sorted(out.glob("*.txt"))
    return events, out, (txts[-1].read_text(encoding="utf-8") if txts else "")


def wait_for(events, pred, timeout=120):
    end = time.time() + timeout
    while time.time() < end:
        if any(pred(e) for e in events):
            return True
        time.sleep(0.1)
    return False


def report(name, ok, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {name:9s} {detail}")


def leftovers():
    r = subprocess.run(["pgrep", "-fl", "backend.py|whisper-server|lecture-tap|fake_tap"],
                       capture_output=True, text=True).stdout.strip()
    return r


for name in NAMES:
    if name == "mixed":
        def plan(send, ev, p):
            send({"cmd": "file", "path": str(ROOT / "tests/mixed_lang.wav")})
            wait_for(ev, lambda e: e["ev"] == "saved")
            send({"cmd": "shutdown"})
        events, out, txt = run(name, [], plan, live=False)
        lines = [l for l in txt.splitlines() if l.startswith("[")]
        ok = ("사과" in txt and ("butcher" in txt or "benevolence" in txt) and "무지개" in txt
              and "The word" not in txt and "the word" not in txt)
        report(name, ok, " | ".join(l[8:60] for l in lines[:5]))

    elif name == "killsrv":
        def plan(send, ev, p):
            send({"cmd": "start"})
            wait_for(ev, lambda e: e["ev"] == "seg" and e["final"] and e["text"], 60)
            pid = subprocess.run(["pgrep", "-f", "bin/whisper-server.*--port"], capture_output=True,
                                 text=True).stdout.split()
            for x in pid:
                os.kill(int(x), signal.SIGKILL)
            time.sleep(70)
            send({"cmd": "stop"})
            wait_for(ev, lambda e: e["ev"] == "saved", 120)
            send({"cmd": "shutdown"})
        events, out, txt = run(name, [str(ROOT / "tests/lecture.aiff")], plan)
        n = len([l for l in txt.splitlines() if l.startswith("[")])
        log = (ROOT / "logs/scenario-killsrv.log").read_text()
        starts = log.count("whisper-server starting")
        ok = n >= 9 and "코끼리" in txt and "푸른 하늘 은하수" in txt and starts >= 2
        report(name, ok, f"{n} lines, server starts={starts}, hidden words="
               f"{'코끼리' in txt}/{'푸른 하늘 은하수' in txt}")

    elif name == "quitsave":
        def plan(send, ev, p):
            send({"cmd": "start"})
            time.sleep(40)
            send({"cmd": "stop"})
            time.sleep(0.3)
            send({"cmd": "shutdown"})
        events, out, txt = run(name, [str(ROOT / "tests/lecture.aiff")], plan)
        n = len([l for l in txt.splitlines() if l.startswith("[")])
        saved = any(e["ev"] == "saved" for e in events)
        m4a = list(out.glob("*.m4a"))
        wav = list(out.glob("*.wav"))
        ok = saved and n >= 6 and "코끼리" in txt and not wav and len(m4a) == 1
        report(name, ok, f"saved={saved} lines={n} m4a={len(m4a)} wav={len(wav)} "
               f"important-section={'중요 문장' in txt}")

    elif name == "accident":
        def plan(send, ev, p):
            send({"cmd": "start"})
            time.sleep(1.5)
            send({"cmd": "stop"})
            wait_for(ev, lambda e: e["ev"] == "saved", 30)
            send({"cmd": "shutdown"})
        events, out, txt = run(name, [str(ROOT / "tests/silence_4s.wav")], plan)
        files = [f.name for f in out.iterdir()]
        report(name, not files, f"files left: {files}")

    time.sleep(1)
    lo = leftovers()
    if lo:
        print("      leftover processes:", lo.replace("\n", " ; "))
