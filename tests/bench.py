import json, time, urllib.request, uuid, wave, sys
import numpy as np

def wav_bytes(pcm16k):
    import io
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes((np.clip(pcm16k, -1, 1) * 32767).astype("<i2").tobytes())
    return b.getvalue()

def infer(pcm, **fields):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + wav_bytes(pcm) + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request("http://127.0.0.1:18765/inference", data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        res = json.loads(r.read())
    return time.time() - t, res

with wave.open("tests/short.wav") as w:
    pcm = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768
for _ in range(60):
    try:
        urllib.request.urlopen("http://127.0.0.1:18765/", timeout=1); break
    except Exception: time.sleep(0.5)
base = dict(language="ko", response_format="verbose_json", temperature="0.0", temperature_inc="0.2", no_timestamps="true")
infer(pcm[:16000*3], **base)  # warm-up
RUNS = [
    ("20s greedy full", pcm, {}),
    ("20s beam5 full", pcm, {"beam_size": "5"}),
    ("5s greedy full", pcm[:16000*5], {}),
    ("5s greedy ac=384", pcm[:16000*5], {"audio_ctx": "384"}),
    ("10s greedy ac=640", pcm[:16000*10], {"audio_ctx": "640"}),
    ("10s greedy full", pcm[:16000*10], {}),
]:
    dt, res = infer(clip, **base, **extra)
    segs = res.get("segments", [])
    text = "".join(s["text"] for s in segs).strip()
    nsp = [round(s.get("no_speech_prob", -1), 3) for s in segs]
    lp = [round(s.get("avg_logprob", 0), 2) for s in segs]
    print(f"{label:22s} {dt*1000:6.0f} ms | nsp={nsp} lp={lp} | {text}")
