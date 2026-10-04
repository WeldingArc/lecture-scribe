#!/usr/bin/env python3
"""강의 받아쓰기 — transcription backend.

Pipeline: bin/lecture-tap (Mac system audio, 16 kHz mono float32)
          → Silero VAD segmenter (cuts at natural pauses)
          → whisper.cpp server (large-v3-turbo, Metal GPU)
          → transcript events for the app window + files in ~/강의기록

The native app shell talks to this process over stdio, one JSON object per line:
  stdin  ← {"cmd": "start"} | {"cmd": "stop"} | {"cmd": "file", "path": "..."} | {"cmd": "shutdown"}
  stdout → {"ev": "engine", "state": "loading" | "ready" | "error", "msg": "..."}
           {"ev": "rec", "state": "recording" | "finishing" | "idle", "mode": "live" | "file", ...}
           {"ev": "level", "v": 0..1}
           {"ev": "seg", "id": 7, "t": 83.2, "text": "...", "final": true}
           {"ev": "progress", "pending": 2, "done": 0.42}
           {"ev": "saved", "txt": "...", "audio": "...", "seconds": 3021.5, "count": 412}
           {"ev": "notice", "code": "...", "msg": "..."}
Diagnostics go to stderr (the app shell appends them to logs/backend.log).
"""
import io
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from collections import deque
from datetime import datetime
from pathlib import Path

import faulthandler
import hashlib

import numpy as np

ROOT = Path(__file__).resolve().parent          # engine: backend.py + bin/ + models/silero (app or checkout)
DATA = Path(os.environ.get("LECTURE_DATA_DIR") or ROOT)   # downloaded model, settings, logs
MODEL_NAME = "ggml-large-v3-turbo-q5_0.bin"
MODEL = DATA / "models" / MODEL_NAME
MODEL_URL = (os.environ.get("LECTURE_MODEL_URL")
             or f"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{MODEL_NAME}")
MODEL_SHA256 = (os.environ.get("LECTURE_MODEL_SHA256")
                or "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
MODEL_SIZE = int(os.environ.get("LECTURE_MODEL_SIZE") or 574041195)
VAD_MODEL = ROOT / "models" / "silero_vad_16k.npz"   # Silero VAD v5 weights (tools/export_silero.py)
SERVER_BIN = ROOT / "bin" / "whisper-server"
TAP_BIN = Path(os.environ.get("LECTURE_TAP_BIN") or ROOT / "bin" / "lecture-tap")  # override: tests only
OUT_DIR = Path(os.environ.get("LECTURE_OUT_DIR", Path.home() / "강의기록"))
LOG_DIR = DATA / "logs"
SETTINGS = DATA / "settings.json"
DEBUG = os.environ.get("LECTURE_DEBUG") == "1"      # only then do logs contain transcript text
DEFAULT_KEYWORDS = ["출석", "시험", "과제", "퀴즈", "키워드", "암호", "비밀번호", "오늘의 단어", "확인 단어",
                    "attendance", "exam", "quiz", "assignment", "keyword", "password"]
# Test hooks (never set in normal use): start/stop recording without touching the UI.
AUTOSTART = os.environ.get("LECTURE_AUTOSTART") == "1"
_ONCE = os.environ.get("LECTURE_AUTOSTART_ONCE")      # flag file: autostart only the first backend
if _ONCE and Path(_ONCE).exists():
    AUTOSTART = True
    Path(_ONCE).unlink()
AUTOSTOP = float(os.environ.get("LECTURE_AUTOSTOP", "0") or 0)

SR = 16000
FRAME = 512                    # Silero VAD frame at 16 kHz = 32 ms
FRAME_SEC = FRAME / SR

# ---------------------------------------------------------------- stdio events

# Keep the real stdout for protocol events only; anything else printed goes to the log.
_events = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr
_ev_lock = threading.Lock()


def emit(ev, **kw):
    kw["ev"] = ev
    line = json.dumps(kw, ensure_ascii=False)
    with _ev_lock:
        try:
            _events.write(line + "\n")
            _events.flush()
        except (BrokenPipeError, ValueError, OSError):
            pass


_HOME = str(Path.home())


def log(*a):
    msg = " ".join(str(x) for x in a).replace(_HOME, "~")    # no user names in logs people share
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


def _t(text, n=50):
    """Transcript text in logs only when debugging; otherwise just its length."""
    return text[:n] if DEBUG else f"({len(text)}자)"


def fmt_ts(sec):
    sec = int(sec)
    h, m, s = sec // 3600, sec % 3600 // 60, sec % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


# ---------------------------------------------------------------- VAD

class SileroVAD:
    """Silero VAD v5 (16 kHz) in pure NumPy: the same math as the official ONNX graph, without a
    runtime library (and its telemetry). Returns the speech probability of each 512-sample frame."""

    def __init__(self, path):
        w = np.load(path)
        self.basis = w["stft_basis"]                                   # (258, 256)
        self.convs = [(w[f"enc{i}_w"], w[f"enc{i}_b"], st) for i, st in enumerate((1, 2, 2, 1))]
        self.w_ih, self.w_hh = w["lstm_w_ih"], w["lstm_w_hh"]
        self.b = w["lstm_b_ih"] + w["lstm_b_hh"]
        self.out_w, self.out_b = w["out_w"][0, :, 0], float(w["out_b"][0])
        self.reset()

    def reset(self):
        self.h = np.zeros(128, np.float32)
        self.c = np.zeros(128, np.float32)
        self.ctx = np.zeros(64, np.float32)

    @staticmethod
    def _conv(x, w, b, stride):                                        # 1-D conv, kernel 3, pad 1
        xp = np.pad(x, ((0, 0), (1, 1)))
        n = (x.shape[1] - 1) // stride + 1
        cols = np.stack([xp[:, j * stride:j * stride + 3] for j in range(n)])
        return np.einsum("oik,tik->ot", w, cols) + b[:, None]

    def __call__(self, frame):
        x = np.concatenate([self.ctx, frame.astype(np.float32)])        # 64 context + 512
        self.ctx = x[-64:]
        x = np.concatenate([x, x[-2:-66:-1]])                          # reflect-pad 64 → 640
        frames = np.lib.stride_tricks.sliding_window_view(x, 256)[::128]
        spec = frames @ self.basis.T                                   # STFT as in the model
        h = np.sqrt(spec[:, :129] ** 2 + spec[:, 129:] ** 2).T
        for w, b, st in self.convs:
            h = np.maximum(self._conv(h, w, b, st), 0)
        i, f, g, o = np.split(self.w_ih @ h[:, 0] + self.w_hh @ self.h + self.b, 4)
        sig = lambda z: 1 / (1 + np.exp(-z))
        self.c = sig(f) * self.c + sig(i) * np.tanh(g)
        self.h = sig(o) * np.tanh(self.c)
        return float(sig(self.out_w @ np.maximum(self.h, 0) + self.out_b))


# ---------------------------------------------------------------- whisper.cpp server

def wav_bytes(pcm):
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())
    return b.getvalue()


def multipart(fields, wav):
    boundary = uuid.uuid4().hex
    out = []
    for k, v in fields.items():
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
               f'Content-Type: audio/wav\r\n\r\n'.encode() + wav + b"\r\n")
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


class WhisperServer:
    def __init__(self):
        self.proc = None
        self.port = None
        self.pid = 0

    def start(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        args = [str(SERVER_BIN), "-m", MODEL.name, "-l", "ko", "-t", "4", "-nlp",   # relative: no paths in its log
                "--host", "127.0.0.1", "--port", str(self.port)]
        # The wrapper exits when the server exits (so a dead server is noticed) and kills the
        # server as soon as our stdin pipe closes (so it never outlives this process).
        # (Background jobs get /dev/null as stdin, so the watcher reads our pipe through fd 3.)
        wrapper = ('"$0" "$@" >>"$WLOG" 2>&1 </dev/null & pid=$!; echo $pid; exec 3<&0; '
                   '(cat <&3 >/dev/null; kill $pid 2>/dev/null) & wait $pid')
        LOG_DIR.mkdir(exist_ok=True)
        wlog = LOG_DIR / "whisper-server.log"
        wlog.write_text("")
        self.proc = subprocess.Popen(["/bin/sh", "-c", wrapper] + args, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     cwd=str(MODEL.parent), env={**os.environ, "WLOG": str(wlog)})
        try:
            self.pid = int(self.proc.stdout.readline().strip() or 0)
        except ValueError:
            self.pid = 0
        log("whisper-server starting on port", self.port, "pid", self.pid)

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def healthy(self, timeout=3):
        if not self.alive():
            return False
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=timeout).read()
            return True
        except urllib.error.HTTPError:
            return True
        except Exception:
            return False

    def wait_ready(self, timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if not self.alive():
                return False
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=1).read()
                return True
            except urllib.error.HTTPError:
                return True
            except Exception:
                time.sleep(0.3)
        return False

    def transcribe(self, pcm, beam=1, language="ko", temperature="0.0"):
        fields = {
            "language": language,
            "response_format": "verbose_json",
            "temperature": temperature,
            "temperature_inc": "0.2",
            "no_timestamps": "true",
            "no_language_probabilities": "true",
            "suppress_nst": "true",
        }
        if beam > 1:
            fields["beam_size"] = str(beam)
        body, ctype = multipart(fields, wav_bytes(pcm))
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/inference", data=body,
                                     headers={"Content-Type": ctype})
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read().decode("utf-8", "replace"))

    def stop(self):
        if self.proc:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGKILL)   # no-op if it already exited
            except OSError:
                pass
        self.proc = None
        self.pid = 0


# Phrases Whisper is known to invent on silence/noise (YouTube outro boilerplate).
# Only dropped when they are the entire segment.
_HALLUCINATIONS = [re.sub(r"\s+", "", s) for s in (
    "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요 부탁드립니다",
    "구독 좋아요 알림설정", "구독과 좋아요", "MBC 뉴스", "KBS 뉴스", "SBS 뉴스", "YTN 뉴스",
    "자막 제공", "한글자막", "자막 by", "Thank you for watching", "다음 영상에서 만나요",
)]


def clean_text(res):
    keep = []
    for s in res.get("segments") or []:
        t = (s.get("text") or "").strip()
        if not t:
            continue
        nsp, lp = s.get("no_speech_prob", 0.0), s.get("avg_logprob", 0.0)
        if nsp > 0.6 and lp < -1.0:
            log("drop (no speech):", _t(t))
            continue
        keep.append(t)
    text = re.sub(r"\s+", " ", " ".join(keep)).strip()
    norm = re.sub(r"[\s.,!?…·\-~]+", "", text)
    if not norm:
        return ""
    for h in _HALLUCINATIONS:
        if norm.startswith(h) and len(norm) <= len(h) + 8:
            log("drop (known hallucination):", _t(text))
            return ""
    return text


def avg_logprob(res):
    segs = res.get("segments") or []
    total = sum(len(x.get("tokens") or [1]) for x in segs)
    if not total:
        return 0.0
    return sum(x.get("avg_logprob", 0.0) * len(x.get("tokens") or [1]) for x in segs) / total


def find_loop(text):
    """Whisper's failure mode: the same phrase over and over. Returns (start, n, repeats) or None."""
    w = text.split()
    for n in range(1, 7):
        need = 6 if n == 1 else 4
        for i in range(0, len(w) - n * need + 1):
            k = 1
            while w[i + k * n:i + (k + 1) * n] == w[i:i + n]:
                k += 1
            if k >= need:
                return i, n, k
    return None


def collapse_loops(text):
    w = text.split()
    for _ in range(20):
        hit = find_loop(" ".join(w))
        if not hit:
            break
        i, n, k = hit
        w = w[:i + 2 * n] + ["…"] + w[i + k * n:]
    return " ".join(w)


class ModelError(Exception):
    pass


def ensure_model():
    """First launch only: download the Whisper model (~574 MB) with progress, then verify it."""
    if MODEL.exists() and MODEL.stat().st_size == MODEL_SIZE:
        return
    MODEL.parent.mkdir(parents=True, exist_ok=True)
    # Only one engine downloads at a time (a second app instance waits here).
    import fcntl
    lock = open(MODEL.with_name(MODEL.name + ".lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    if MODEL.exists() and MODEL.stat().st_size == MODEL_SIZE:
        return
    part = MODEL.with_name(MODEL.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    if have > MODEL_SIZE:
        part.unlink()
        have = 0
    if shutil.disk_usage(MODEL.parent).free < (MODEL_SIZE - have) + 300_000_000:
        raise ModelError("저장 공간이 부족해요. AI 모델을 받으려면 약 900MB의 여유 공간이 필요해요.")
    if have < MODEL_SIZE:
        # A curl left over from an earlier, crashed run would write into the same file.
        subprocess.run(["/usr/bin/pkill", "-f", f"curl .*{re.escape(str(part))}"], capture_output=True)
        log("downloading model:", MODEL_URL, f"(resume at {have})" if have else "")
        # Same wrapper as whisper-server: curl is killed as soon as this process goes away.
        # (The watcher must not inherit our stderr pipe, or reading curl's error would block forever.)
        wrapper = ('"$0" "$@" & pid=$!; exec 3<&0; '
                   '(cat <&3 >/dev/null 2>&1; kill $pid 2>/dev/null) >/dev/null 2>&1 & wait $pid')
        proc = subprocess.Popen(["/bin/sh", "-c", wrapper, "/usr/bin/curl", "-fsSL", "--retry", "3",
                                 "--connect-timeout", "20", "--speed-limit", "2000", "--speed-time", "60",
                                 "-C", "-", "-o", str(part), MODEL_URL],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        while proc.poll() is None:
            time.sleep(0.5)
            done = part.stat().st_size if part.exists() else 0
            emit("engine", state="downloading", done=done, total=MODEL_SIZE)
        proc.stdin.close()                      # let the watcher exit too
        if proc.returncode != 0:
            log("model download failed:", proc.returncode, proc.stderr.read().decode("utf-8", "replace").strip())
            raise ModelError("AI 모델을 내려받지 못했어요. 인터넷 연결을 확인하고 다시 시도해 주세요.")
    emit("engine", state="downloading", done=MODEL_SIZE, total=MODEL_SIZE, verifying=True)
    h = hashlib.sha256()
    with open(part, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != MODEL_SHA256:
        part.unlink(missing_ok=True)
        log("model checksum mismatch")
        raise ModelError("내려받은 모델 파일이 손상됐어요. 다시 시도해 주세요.")
    part.rename(MODEL)
    log("model ready:", MODEL)


# ---------------------------------------------------------------- transcriber

class Transcriber:
    """Single GPU worker. Finals are queued in order; an interim preview runs only when idle."""

    def __init__(self, engine):
        self.engine = engine
        self.cv = threading.Condition()
        self.finals = deque()
        self.interim = None
        self.busy = False
        self.last_cost = 1.6
        self.lang = "ko"                 # majority language of recent long finals
        self.recent = deque(maxlen=7)
        threading.Thread(target=self._run, daemon=True, name="asr").start()

    def reset_language(self):
        self.lang = "ko"
        self.recent.clear()

    def drop_interim(self):
        with self.cv:
            self.interim = None

    def final(self, job):
        with self.cv:
            self.finals.append(job)
            self.cv.notify_all()

    def offer_interim(self, job):
        with self.cv:
            if self.busy or self.finals:
                return False
            self.interim = job
            self.cv.notify_all()
            return True

    def pending(self):
        with self.cv:
            return len(self.finals) + (1 if self.busy else 0)

    def wait_idle(self, timeout, tick=None):
        deadline = time.time() + timeout
        with self.cv:
            while (self.finals or self.busy) and time.time() < deadline:
                if tick:
                    tick(len(self.finals) + (1 if self.busy else 0))
                self.cv.wait(0.5)
            return not (self.finals or self.busy)

    def _decode(self, pcm, final):
        """Korean or English, written down as spoken (never translated).

        Long finals (≥ 2.5 s) detect their language; if that differs from the lecture's majority
        language the sentence is decoded both ways and the more confident reading wins — so an
        English quote stays English, and a misdetected Korean sentence can't turn into an English
        translation. Short finals and live previews use the majority language.
        """
        srv = self.engine.server
        seconds = len(pcm) / SR
        major = "english" if self.lang == "en" else "korean"
        if final and seconds >= 2.5:
            res = srv.transcribe(pcm, beam=5, language="auto")
            lang = res.get("language")
            if lang not in ("korean", "english"):
                res, lang = srv.transcribe(pcm, beam=5, language=self.lang), major
            elif lang != major:
                res_m = srv.transcribe(pcm, beam=5, language=self.lang)
                if avg_logprob(res_m) >= avg_logprob(res):
                    log(f"kept {major} over detected {lang}: "
                        f"{avg_logprob(res_m):.2f} ≥ {avg_logprob(res):.2f}")
                    res, lang = res_m, major
        else:
            lang = major
            res = srv.transcribe(pcm, beam=5 if final else 1, language=self.lang)
        text, conf = clean_text(res), avg_logprob(res)
        if final and text and find_loop(text):
            # Whisper's repetition failure: one more try in the other language.
            other = "en" if lang == "korean" else "ko"
            try:
                res2 = srv.transcribe(pcm, beam=5, language=other)
                text2, conf2 = clean_text(res2), avg_logprob(res2)
                log(f"loop retry: {lang} {conf:.2f} → {other} {conf2:.2f}: {_t(text2)}")
                if text2 and not find_loop(text2) and conf2 > conf:
                    text, conf, lang = text2, conf2, ("english" if other == "en" else "korean")
            except Exception as e:
                log("loop retry failed:", repr(e))
        if text and find_loop(text):
            log("collapsing repeated phrase:", _t(text))
            text = collapse_loops(text)
        if final:
            if text and seconds >= 2.5:
                self.recent.append("en" if lang == "english" else "ko")
                self.lang = "en" if self.recent.count("en") * 2 > len(self.recent) else "ko"
            log(f"final {lang} {conf:6.2f} {seconds:4.1f}s: {_t(text)}")
        return text

    def _run(self):
        while True:
            with self.cv:
                while not self.finals and self.interim is None:
                    self.cv.wait()
                if self.finals:
                    job, final = self.finals.popleft(), True
                    self.interim = None
                else:
                    job, final = self.interim, False
                    self.interim = None
                self.busy = True
            text = None
            t = time.time()
            for attempt in range(4):
                try:
                    self.engine.ensure_server()      # wakes the model if it was unloaded while idle
                    text = self._decode(job["pcm"], final)
                    break
                except Exception as e:
                    log(f"transcribe error (attempt {attempt + 1}):", repr(e))
                    if not final:
                        break
                    try:
                        self.engine.recover_server()  # restarts a dead or hung server
                    except Exception as e2:
                        log("server recovery failed:", repr(e2))
                        time.sleep(2)
            self.last_cost = time.time() - t
            try:
                job["done"](job, text, final)
            except Exception as e:
                log("result handler error:", repr(e))
            finally:
                with self.cv:
                    self.busy = False
                    self.cv.notify_all()


# ---------------------------------------------------------------- segmenter

class Segmenter:
    """Groups VAD frames into utterances, cutting at pauses.

    Short phrases wait for a longer pause (more context = better accuracy);
    long ones cut at shorter pauses; anything reaching MAX_SEC is cut at the
    quietest moment of its last 5 seconds.
    """
    START_P = 0.5
    END_P = 0.35
    PRE_SEC = 0.5
    TAIL_SEC = 0.3
    MAX_SEC = 22.0
    MIN_SPEECH_SEC = 0.25

    def __init__(self, vad, on_final, on_interim=None, on_drop=None):
        self.vad = vad
        self.on_final = on_final
        self.on_interim = on_interim
        self.on_drop = on_drop
        self.pre = deque(maxlen=int(self.PRE_SEC / FRAME_SEC))
        self.pos = 0                 # frames seen so far
        self.active = False
        self.frames, self.probs = [], []
        self.start = 0               # frame index where the current segment starts
        self.silence = self.speech = 0
        self.last_interim_len = 0.0
        self.interim_gap = 4.0
        self.next_id = 1
        self.cur_id = 0

    def _audio(self, frames):
        return np.concatenate(frames) if frames else np.zeros(0, np.float32)

    def feed(self, frame):
        p = self.vad(frame)
        if not self.active:
            self.pre.append(frame)
            if p >= self.START_P:
                self.active = True
                self.frames = list(self.pre)
                self.probs = [0.0] * (len(self.frames) - 1) + [p]
                self.start = self.pos - len(self.frames) + 1
                self.silence, self.speech = 0, 1
                self.last_interim_len = 0.0
                self.cur_id, self.next_id = self.next_id, self.next_id + 1
                self.pre.clear()
        else:
            self.frames.append(frame)
            self.probs.append(p)
            self.silence = self.silence + 1 if p < self.END_P else 0
            if p >= self.START_P:
                self.speech += 1
            length = len(self.frames) * FRAME_SEC
            need = 1.2 if length < 4 else (0.6 if length < 12 else 0.3)
            if self.silence * FRAME_SEC >= need:
                tail = int(self.TAIL_SEC / FRAME_SEC)
                cut = len(self.frames) - self.silence + min(self.silence, tail)
                after = self.frames[cut:]
                self._close(cut)
                self.active = False
                self.frames, self.probs = [], []
                self.pre.extend(after)   # pure silence: safe pre-roll for the next utterance
            elif length >= self.MAX_SEC:
                look = int(5.0 / FRAME_SEC)
                k = len(self.probs) - look + int(np.argmin(self.probs[-look:]))
                k = max(k, 1)
                rest_f, rest_p = self.frames[k:], self.probs[k:]
                self._close(k)
                self.frames, self.probs = rest_f, rest_p
                self.start += k
                self.silence = 0
                self.speech = sum(1 for q in rest_p if q >= self.START_P)
                self.last_interim_len = 0.0
                self.cur_id, self.next_id = self.next_id, self.next_id + 1
            elif (self.on_interim and length >= 3.0
                  and length - self.last_interim_len >= self.interim_gap):
                if self.on_interim(self.cur_id, self.start * FRAME_SEC, self._audio(self.frames)):
                    self.last_interim_len = length
        self.pos += 1

    def _close(self, cut):
        speech = sum(1 for q in self.probs[:cut] if q >= self.START_P)
        if speech * FRAME_SEC >= self.MIN_SPEECH_SEC:
            self.on_final(self.cur_id, self.start * FRAME_SEC, self._audio(self.frames[:cut]))
        elif self.on_drop:
            self.on_drop(self.cur_id)

    def flush(self):
        if self.active and self.frames:
            self._close(len(self.frames))
        self.active = False
        self.frames, self.probs = [], []


# ---------------------------------------------------------------- files

class WavWriter:
    """16-bit mono WAV whose header is patched every few seconds, so a crash never loses audio."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, "wb")
        self.n = 0
        self.f.write(b"RIFF" + struct.pack("<I", 36) + b"WAVE" + b"fmt " +
                     struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16) + b"data" + struct.pack("<I", 0))
        self.last_patch = time.time()

    def write(self, x):
        b = (np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()
        self.f.write(b)
        self.n += len(b)
        if time.time() - self.last_patch > 5:
            self.patch()

    def patch(self):
        pos = self.f.tell()
        self.f.seek(4)
        self.f.write(struct.pack("<I", 36 + self.n))
        self.f.seek(40)
        self.f.write(struct.pack("<I", self.n))
        self.f.seek(pos)
        self.f.flush()
        self.last_patch = time.time()

    def close(self):
        self.patch()
        self.f.close()

    @property
    def seconds(self):
        return self.n / 2 / SR


def audio_duration(path):
    try:
        out = subprocess.run(["/usr/bin/afinfo", str(path)], capture_output=True, text=True, timeout=30).stdout
        m = re.search(r"estimated duration:\s*([\d.]+)", out)
        return float(m.group(1)) if m else None
    except Exception:
        return None


def compress_wav(wav_path, seconds):
    """WAV → AAC .m4a (≈15 MB per hour). The WAV is removed only after the m4a checks out."""
    m4a = wav_path.with_suffix(".m4a")
    try:
        r = subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "32000",
                            str(wav_path), str(m4a)], capture_output=True, text=True, timeout=900)
        dur = audio_duration(m4a) if r.returncode == 0 else None
        if dur is not None and abs(dur - seconds) < 1.0:
            wav_path.unlink()
            return m4a
        log("compress check failed:", r.returncode, r.stderr.strip(), dur, seconds)
    except Exception as e:
        log("compress error:", repr(e))
    if m4a.exists():
        m4a.unlink()
    return wav_path


def recover_orphans(skip=()):
    """A crash leaves the half-written WAV behind: repair its header and compress it."""
    for wav in sorted(OUT_DIR.glob("*.wav")) if OUT_DIR.exists() else []:
        if wav in skip or wav.with_suffix(".m4a").exists() or time.time() - wav.stat().st_mtime < 15:
            continue
        # Only our own recordings: our file name pattern and our exact 44-byte header layout.
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}시\d{2}분 강의( \(\d+\))?\.wav", wav.name):
            continue
        with open(wav, "rb") as f:
            head = f.read(44)
        if len(head) < 44 or head[:4] != b"RIFF" or head[12:16] != b"fmt " or head[36:40] != b"data":
            continue
        try:
            n = wav.stat().st_size - 44
            if n <= 0:
                continue
            n -= n % 2
            with open(wav, "r+b") as f:
                f.seek(4); f.write(struct.pack("<I", 36 + n))
                f.seek(40); f.write(struct.pack("<I", n))
            out = compress_wav(wav, n / 2 / SR)
            log("recovered recording from an earlier crash:", out.name)
        except Exception as e:
            log("could not recover", wav.name, repr(e))


def unique_path(p):
    if not p.exists() and not p.with_suffix(".wav").exists() and not p.with_suffix(".m4a").exists():
        return p
    i = 2
    while True:
        q = p.with_name(f"{p.stem} ({i}){p.suffix}")
        if not q.exists() and not q.with_suffix(".wav").exists() and not q.with_suffix(".m4a").exists():
            return q
        i += 1


_WEEKDAYS = "월화수목금토일"

def load_settings():
    try:
        st = json.loads(SETTINGS.read_text(encoding="utf-8"))
    except Exception:
        st = {}
    if not isinstance(st, dict):
        st = {}
    words = st.get("keywords")
    if not isinstance(words, list):
        words = DEFAULT_KEYWORDS
    return {"keywords": [str(w).strip() for w in words if str(w).strip()][:60],
            "timestamps": bool(st.get("timestamps", True))}


def save_settings(st):
    try:
        SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        tmp = SETTINGS.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, SETTINGS)
    except OSError as e:
        log("could not save settings:", repr(e))


def keyword_regex(words):
    """Korean keywords match inside words (출석을, 출석은) and ignore Whisper's spacing
    ('오늘의단어'); Latin-script keywords match whole words, plurals included ('exams' ≠ 'example')."""
    parts = []
    for w in words:
        w = w.strip()
        if not w:
            continue
        body = r"\s?".join(re.escape(p) for p in w.split())
        parts.append(rf"(?<![A-Za-z0-9]){body}(?:s|es)?(?![A-Za-z0-9])"
                     if re.fullmatch(r"[A-Za-z0-9 .'-]+", w) else body)
    return re.compile("|".join(parts), re.I) if parts else None


# ---------------------------------------------------------------- sessions

class Session:
    """One recording (live) or one imported file. Owns the transcript file."""

    def __init__(self, engine, mode, title, source_path=None):
        self.engine = engine
        self.mode = mode
        self.source_path = source_path
        self.token = uuid.uuid4().hex
        self.lines = []                  # (t0, text) in order
        self.stopping = False
        self.proc = None
        self.wav = None
        self.samples = 0
        self.nonzero = False
        self.notified_silence = False
        self.restarts = 0
        self.last_restart = 0.0
        self.closed = False
        self.write_failed = False
        self.wav_failed = False
        self.total_sec = None
        self.started_at = datetime.now()
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        self.txt_path = unique_path(OUT_DIR / f"{title}.txt")
        d = self.started_at
        if mode == "live":
            self.header = (f"강의 녹취 · {d:%Y-%m-%d} ({_WEEKDAYS[d.weekday()]}) {d:%H:%M} 시작")
            self.wav = WavWriter(self.txt_path.with_suffix(".wav"))
        else:
            self.header = f"파일 받아쓰기 · {Path(source_path).name} · {d:%Y-%m-%d %H:%M}"
        self.txt = open(self.txt_path, "w", encoding="utf-8")
        self.txt.write(self.header + "\n\n")
        self.txt.flush()
        engine.vad.reset()
        engine.transcriber.reset_language()
        self.seg = Segmenter(engine.vad, self._on_final,
                             self._on_interim if mode == "live" else None, self._on_drop)
        self._level_acc = 0.0
        self._level_t = 0.0

    # --- segmenter callbacks (audio reader thread)
    def _job(self, seg_id, t0, pcm):
        return {"token": self.token, "id": seg_id, "t": t0, "pcm": pcm, "done": self._on_result}

    def _on_final(self, seg_id, t0, pcm):
        self.engine.transcriber.final(self._job(seg_id, t0, pcm))

    def _on_interim(self, seg_id, t0, pcm):
        self.seg.interim_gap = max(4.0, 2.5 * self.engine.transcriber.last_cost)
        return self.engine.transcriber.offer_interim(self._job(seg_id, t0, pcm))

    def _on_drop(self, seg_id):
        emit("seg", id=seg_id, t=0, text="", final=True)

    # --- transcriber callback (asr thread)
    def _on_result(self, job, text, final):
        if self.closed or (not final and self.stopping):
            return                       # late preview after the save: nothing to show
        if final:
            if text is None:
                log("segment lost after retries at", fmt_ts(job["t"]))
                text = "⟨이 부분은 받아 적지 못했어요 — 녹음 파일에서 확인하세요⟩"
                emit("notice", code="seg_lost",
                     msg=f"{fmt_ts(job['t'])} 부분을 받아 적지 못했어요. 녹음 파일에는 남아 있어요.")
            if text:
                self.lines.append((job["t"], text))
                try:
                    self.txt.write(f"[{fmt_ts(job['t'])}] {text}\n")
                    self.txt.flush()
                except OSError as e:
                    self._write_problem(e)
            emit("seg", id=job["id"], t=round(job["t"], 2), text=text or "", final=True)
        elif text:
            emit("seg", id=job["id"], t=round(job["t"], 2), text=text, final=False)

    def _write_problem(self, e):
        log("write failed:", repr(e))
        if not self.write_failed:
            self.write_failed = True
            emit("notice", code="disk",
                 msg="파일을 저장하지 못하고 있어요 (디스크 공간 부족?). 받아 적기는 계속돼요.")

    # --- audio input
    def start(self):
        try:
            if shutil.disk_usage(OUT_DIR).free < 1_000_000_000:
                emit("notice", code="disk_low",
                     msg="디스크 여유 공간이 1GB보다 적어요. 녹음에는 1시간에 약 120MB가 필요해요.")
        except OSError:
            pass
        self._spawn()
        self.t_start = time.time()
        self.last_data = 0.0
        threading.Thread(target=self._reader, daemon=True, name="reader").start()
        if self.mode == "live":
            threading.Thread(target=self._watchdog, daemon=True, name="watchdog").start()
        emit("rec", state="recording", mode=self.mode, started=time.time(),
             txt=str(self.txt_path), title=self.txt_path.stem, header=self.header)

    def _spawn(self):
        cmd = [str(TAP_BIN)] + (["--file", str(self.source_path)] if self.mode == "file" else [])
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        threading.Thread(target=self._tap_status, args=(self.proc,), daemon=True, name="tap-status").start()

    def _tap_status(self, proc):
        for raw in proc.stderr:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            log("tap:", line)
            try:
                st = json.loads(line)
            except ValueError:
                continue
            if st.get("event") == "error":
                emit("notice", code="tap_error", msg=st.get("message", ""))
            elif st.get("event") == "duration":
                self.total_sec = st.get("seconds")

    def _reader(self):
        buf = np.zeros(0, np.float32)
        leftover = b""
        while True:
            fd = self.proc.stdout.fileno()
            try:
                chunk = os.read(fd, 32768)
            except OSError:
                chunk = b""
            if not chunk:
                if time.time() - self.last_restart > 60:
                    self.restarts = 0            # it ran fine for a while: allow fresh retries
                if self.mode == "live" and not self.stopping and self.restarts >= 5:
                    emit("notice", code="tap_gave_up",
                         msg="소리 입력이 계속 끊겨요. 정지 후 다시 시작해 주세요.")
                if self.mode == "live" and not self.stopping and self.restarts < 5:
                    self.restarts += 1
                    self.last_restart = time.time()
                    log("audio helper exited unexpectedly; restarting", self.restarts)
                    emit("notice", code="tap_restart", msg="소리 입력을 다시 연결했어요.")
                    time.sleep(0.5)
                    self._spawn()
                    continue
                break
            data = leftover + chunk
            n = len(data) - len(data) % 4
            leftover = data[n:]
            x = np.frombuffer(data[:n], dtype="<f4")
            if not len(x):
                continue
            if self.wav and not self.wav_failed:
                try:
                    self.wav.write(x)
                except OSError as e:
                    self.wav_failed = True
                    self._write_problem(e)
            self.samples += len(x)
            self.last_data = time.time()
            if not self.nonzero and np.any(np.abs(x) > 1e-7):
                self.nonzero = True
            self._levels(x)
            buf = np.concatenate([buf, x])
            while len(buf) >= FRAME:
                self.seg.feed(buf[:FRAME].copy())
                buf = buf[FRAME:]
            if self.mode == "file":
                # Backpressure: decode no faster than the GPU can transcribe.
                while self.engine.transcriber.pending() > 3 and not self.stopping:
                    time.sleep(0.05)
                if self.total_sec:
                    emit("progress", done=min(1.0, self.samples / SR / self.total_sec),
                         pending=self.engine.transcriber.pending())
            if self.stopping and self.mode == "file":
                break
        self.reader_done = True

    def _levels(self, x):
        self._level_acc = max(self._level_acc, float(np.sqrt(np.mean(x * x))))
        now = time.time()
        if now - self._level_t >= 0.1:
            db = 20 * np.log10(self._level_acc + 1e-9)
            emit("level", v=round(float(np.clip((db + 60) / 60, 0, 1)), 3))
            self._level_acc = 0.0
            self._level_t = now

    def _watchdog(self):
        """Wall-clock checks: before the permission is granted macOS delivers no audio at all."""
        while not self.stopping:
            time.sleep(1)
            now = time.time()
            if now - self.last_data > 0.6:
                emit("level", v=0)
            if self.notified_silence:
                continue
            if self.samples == 0 and now - self.t_start > 20:
                self.notified_silence = True
                emit("notice", code="no_input",
                     msg="아직 소리가 들어오지 않아요.")
            elif self.samples and not self.nonzero and now - self.t_start > 20:
                self.notified_silence = True
                emit("notice", code="no_audio",
                     msg="20초째 소리가 들어오지 않아요.")

    # --- finish
    def finish(self):
        self.stopping = True
        emit("rec", state="finishing", mode=self.mode)
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=3)
            except Exception:
                self.proc.terminate()
        for _ in range(100):
            if getattr(self, "reader_done", False):
                break
            time.sleep(0.05)
        self.seg.flush()
        self.engine.transcriber.drop_interim()
        self.engine.transcriber.wait_idle(600, tick=lambda n: emit("progress", pending=n))
        kw = self.engine.keyword_re
        cues = [(t, x) for t, x in self.lines if kw and kw.search(x)]
        tail = ("\n── 중요 문장 ──\n" + "".join(f"[{fmt_ts(t)}] {x}\n" for t, x in cues)) if cues else ""
        try:
            if self.write_failed:            # rewrite everything in one go (space may be back)
                self.txt.close()
                body = "".join(f"[{fmt_ts(t)}] {x}\n" for t, x in self.lines)
                self.txt_path.write_text(self.header + "\n\n" + body + tail, encoding="utf-8")
            else:
                self.txt.write(tail)
                self.txt.close()
        except OSError as e:
            log("final transcript write failed:", repr(e))
        audio = None
        seconds = self.samples / SR
        if self.wav:
            self.wav.close()
            audio = compress_wav(self.wav.path, self.wav.seconds) if self.wav.n else None
            if audio is None and self.wav.path.exists():
                self.wav.path.unlink()           # empty recording: nothing to keep
        if not self.lines and self.mode == "live" and seconds < 3:
            # accidental start/stop: leave no clutter (text and audio)
            self.txt_path.unlink(missing_ok=True)
            if audio:
                Path(audio).unlink(missing_ok=True)
            emit("saved", txt="", audio="", seconds=seconds, count=0)
        else:
            emit("saved", txt=str(self.txt_path), audio=str(audio) if audio else "",
                 seconds=round(seconds, 1), count=len(self.lines))
        self.closed = True
        emit("rec", state="idle", mode=self.mode)
        log(f"session saved: {self.txt_path.name} · {len(self.lines)} lines · {fmt_ts(seconds)}")


# ---------------------------------------------------------------- engine

class Engine:
    def __init__(self):
        self.server = WhisperServer()
        self.vad = SileroVAD(VAD_MODEL)
        self.transcriber = Transcriber(self)
        self.session = None
        self.lock = threading.Lock()
        self.ready = False
        self.booting = False
        self.settings = load_settings()
        self.keyword_re = keyword_regex(self.settings["keywords"])
        self._server_lock = threading.Lock()
        self.last_active = time.time()
        self.saving = []                 # one Event per save in progress
        threading.Thread(target=self._idle_unload, daemon=True, name="idle").start()

    IDLE_UNLOAD_SEC = float(os.environ.get("LECTURE_IDLE_UNLOAD", "600"))

    def _idle_unload(self):
        """Free ~1 GB of memory: unload the model after 10 idle minutes (reloads in ~2 s on 시작)."""
        while True:
            time.sleep(15)
            if (self.session is None and self.server.alive() and self.transcriber.pending() == 0
                    and time.time() - self.last_active > self.IDLE_UNLOAD_SEC):
                with self._server_lock:
                    if self.session is None:
                        log("idle: unloading model")
                        self.server.stop()

    def update_settings(self, msg):
        if isinstance(msg.get("keywords"), list):
            self.settings["keywords"] = [str(w).strip() for w in msg["keywords"] if str(w).strip()][:60]
            self.keyword_re = keyword_regex(self.settings["keywords"])
        if "timestamps" in msg:
            self.settings["timestamps"] = bool(msg["timestamps"])
        save_settings(self.settings)
        emit("settings", **self.settings)

    def boot(self):
        if self.booting or self.ready:
            return
        self.booting = True
        emit("settings", **self.settings)
        emit("engine", state="loading", msg="엔진 준비 중")
        try:
            ensure_model()
            emit("engine", state="loading", msg="엔진 준비 중")
            self.ensure_server()
            # Warm-up pass compiles GPU kernels before the first real sentence.
            self.server.transcribe(np.zeros(SR, np.float32))
            self.ready = True
            emit("engine", state="ready", msg="준비됨")
            threading.Thread(target=recover_orphans, daemon=True, name="recover").start()
            if AUTOSTART:
                log("test hook: autostart", f"autostop={AUTOSTOP}s" if AUTOSTOP else "")
                threading.Timer(0.5, self.start, args=("live",)).start()
                if AUTOSTOP:
                    threading.Timer(AUTOSTOP + 0.5, self.stop).start()
        except ModelError as e:
            emit("engine", state="error", msg=str(e), retry=True)
        except Exception as e:
            log("engine boot failed:", repr(e))
            emit("engine", state="error", msg="엔진을 시작하지 못했어요. 다시 시도해 주세요.", retry=True)
        finally:
            self.booting = False

    def ensure_server(self):
        with self._server_lock:
            if self.server.alive():
                return
            self.server.stop()
            self.server.start()
            if not self.server.wait_ready():
                raise RuntimeError("whisper-server did not start")
            log("whisper-server ready")

    def recover_server(self):
        with self._server_lock:
            if self.server.healthy():
                return
            log("whisper-server dead or unresponsive: restarting")
            self.server.stop()
            self.server.start()
            if not self.server.wait_ready():
                raise RuntimeError("whisper-server did not restart")
            log("whisper-server restarted")

    def start(self, mode, path=None):
        with self.lock:
            if self.session:
                return
            if not self.ready:
                emit("notice", code="not_ready", msg="엔진이 아직 준비 중이에요. 준비되면 다시 시도해 주세요.")
                return
            if mode == "live":
                d = datetime.now()
                title = f"{d:%Y-%m-%d %H시%M분} 강의"
            else:
                if not path or not Path(path).exists():
                    emit("notice", code="file_missing", msg="파일을 찾을 수 없어요.")
                    return
                title = f"{Path(path).stem} 받아쓰기"
            self.last_active = time.time()
            self.session = Session(self, mode, title, path)
            self.session.start()
        threading.Thread(target=self._wake, daemon=True).start()
        if mode == "file":
            threading.Thread(target=self._file_watch, args=(self.session,), daemon=True).start()

    def _wake(self):
        try:
            self.ensure_server()
        except Exception as e:
            log("wake failed:", repr(e))
            emit("notice", code="engine_wake", msg="엔진을 다시 켜지 못했어요. 앱을 다시 열어 주세요.")

    def _file_watch(self, sess):
        while not getattr(sess, "reader_done", False):
            time.sleep(0.2)
        if self.session is sess and not sess.stopping:
            self.stop()

    def stop(self):
        with self.lock:
            sess, self.session = self.session, None
            done = threading.Event()
            if sess:
                self.saving.append(done)
        if sess:
            try:
                sess.finish()
            finally:
                done.set()
        self.last_active = time.time()

    def shutdown(self):
        try:
            self.stop()
            for done in list(self.saving):   # a save started by 정지 may still be running
                done.wait(600)
        finally:
            self.server.stop()


def main():
    faulthandler.register(signal.SIGUSR1, all_threads=True)   # kill -USR1 <pid> → stacks in the log
    engine = Engine()
    threading.Thread(target=engine.boot, daemon=True, name="boot").start()

    def on_term(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, on_term)
    try:
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            cmd = msg.get("cmd")
            log("cmd:", cmd)
            if cmd == "start":
                threading.Thread(target=engine.start, args=("live",), daemon=True).start()
            elif cmd == "file":
                threading.Thread(target=engine.start, args=("file", msg.get("path")), daemon=True).start()
            elif cmd == "stop":
                threading.Thread(target=engine.stop, daemon=True).start()
            elif cmd == "settings":
                engine.update_settings(msg)
            elif cmd == "retry":
                threading.Thread(target=engine.boot, daemon=True, name="boot").start()
            elif cmd == "shutdown":
                break
    except (SystemExit, KeyboardInterrupt):
        pass
    finally:
        # stdin closed (app quit or crashed) or shutdown requested: save everything first.
        engine.shutdown()
        emit("bye")
        os._exit(0)


if __name__ == "__main__":
    main()
