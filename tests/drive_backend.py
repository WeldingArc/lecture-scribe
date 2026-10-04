"""Drive backend.py over stdio like the app shell does. Usage: drive_backend.py file <path> | live <seconds>"""
import json, subprocess, sys, threading, time, os
mode, arg = sys.argv[1], sys.argv[2]
env = dict(os.environ)
# DRIVE_APP=<path to .app> drives the app's bundled Python + engine instead of the checkout.
app = os.environ.get("DRIVE_APP")
cmd = ([f"{app}/Contents/Resources/python/bin/python3", "-I", "-B", "-u", f"{app}/Contents/Resources/engine/backend.py"]
       if app else [".venv/bin/python", "backend.py"])
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=open("logs/test-backend.log", "w"), env=env, text=True, bufsize=1)
events = []
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
t0 = time.time(); saved = None; levels = 0; interims = 0
for line in p.stdout:
    ev = json.loads(line); events.append(ev)
    k = ev["ev"]
    if k == "level": levels += 1; continue
    if k == "engine":
        print(f"{time.time()-t0:6.1f}s engine {ev['state']}")
        if ev["state"] == "error":
            send({"cmd": "shutdown"})
        if ev["state"] == "ready":
            send({"cmd": "file", "path": arg} if mode == "file" else {"cmd": "start"})
            if mode == "live":
                threading.Timer(float(arg), lambda: send({"cmd": "stop"})).start()
    elif k == "seg":
        if not ev["final"]: interims += 1
        print(f"{time.time()-t0:6.1f}s seg#{ev['id']} [{ev['t']:6.1f}] {'FINAL' if ev['final'] else 'interim'}: {ev['text']}")
    elif k == "saved":
        saved = ev; print(f"{time.time()-t0:6.1f}s SAVED {ev}"); send({"cmd": "shutdown"})
    elif k in ("rec", "notice", "bye"):
        print(f"{time.time()-t0:6.1f}s {k} {ev}")
p.wait(timeout=30)
print(f"exit={p.returncode} levels={levels} interims={interims}")
