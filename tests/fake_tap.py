#!/usr/bin/env python3
"""Stand-in for bin/lecture-tap in soak tests: streams audio files as live 16 kHz float32 PCM at
real-time pace (then silence), and exits when stdin closes — exactly like the real helper."""
import os, subprocess, sys, threading, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
files = os.environ["FAKE_TAP_FILES"].split(":")
pcm = b"".join(subprocess.run([os.path.join(ROOT, "bin/lecture-tap"), "--file", f],
                              capture_output=True, check=True).stdout for f in files)
sys.stderr.write('{"event":"started","mode":"fake","seconds":%.1f}\n' % (len(pcm) / 4 / 16000)); sys.stderr.flush()
def watch():
    while os.read(0, 64): pass
    os._exit(0)
threading.Thread(target=watch, daemon=True).start()
chunk = 1600 * 4          # 100 ms
t0 = time.time(); i = 0; out = sys.stdout.buffer
while True:
    data = pcm[i * chunk:(i + 1) * chunk] or b"\x00" * chunk
    try: out.write(data); out.flush()
    except BrokenPipeError: os._exit(0)
    i += 1
    time.sleep(max(0, t0 + i * 0.1 - time.time()))
