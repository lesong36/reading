#!/usr/bin/env python3

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import mimetypes
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse, unquote
from urllib.request import Request, urlopen
import ast
import socket
import subprocess
import tempfile


ROOT_DIR = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
TTS_SUBMIT_URL = "https://openspeech.bytedance.com/api/v1/tts_async/submit"
TTS_QUERY_URL = "https://openspeech.bytedance.com/api/v1/tts_async/query"
TTS_RESOURCE_ID = "volc.tts_async.default"
DOUBAO_SPEECH_BIN = Path("/Users/coty/.venvs/doubao-speech/bin/doubao-speech")
DOUBAO_TTS_MAX_RETRIES = 3
DOUBAO_TTS_RETRY_DELAY_SECONDS = 1.2
# 临时关闭豆包云端 TTS（按量计费）；恢复时改为 False
DOUBAO_TTS_DISABLED = True
EDGE_TTS_VOICES = {"en-US-AriaNeural", "en-US-GuyNeural"}
EDGE_TTS_MIN_SPEED = 0.6
EDGE_TTS_MAX_SPEED = 1.8
EDGE_TTS_MAX_TEXT_LENGTH = 10_000

# ── CosyVoice sidecar ─────────────────────────────────────────────────────────
COSYVOICE_PORT       = 8766
COSYVOICE_PYTHON     = Path("/Users/coty/miniconda3/envs/cosyvoice/bin/python")
COSYVOICE_SERVER_SCRIPT = Path(__file__).parent / "cosyvoice_server.py"
_cosyvoice_proc: subprocess.Popen | None = None  # module-level handle
ESM_PROXY_ORIGIN = "https://esm.sh"
ESM_PROXY_PREFIXES = (
    "/esm/",
    "/react@",
    "/react-dom@",
    "/lucide-react@",
    "/text-readability@",
    "/firebase@",
    "/scheduler@",
    "/node/",
    "/normalize-strings/",
    "/syllable@",
)
ESM_PROXY_QUERY_OVERRIDES = {
    "/lucide-react@0.292.0": "bundle&deps=react@18.2.0",
}


def load_local_config() -> dict:
    config_path = ROOT_DIR / "local-config.js"
    if not config_path.exists():
      return {}

    content = config_path.read_text(encoding="utf-8")
    start = content.find("{")
    end = content.rfind("}")
    if start == -1 or end == -1 or end <= start:
      return {}

    object_like = content[start:end + 1]
    object_like = object_like.replace("volcengineAppId", '"volcengineAppId"')
    object_like = object_like.replace("volcengineAccessToken", '"volcengineAccessToken"')
    try:
        return ast.literal_eval(object_like)
    except Exception:
        try:
            return json.loads(object_like)
        except json.JSONDecodeError:
            return {}


LOCAL_CONFIG = load_local_config()


def _synthesize_edge_tts(*, text: str, voice: str, speed: float) -> tuple[bytes | None, str | None]:
    """Generate a short English passage with Microsoft's Edge neural voices."""
    try:
        import edge_tts
    except ImportError:
        return None, "未安装 edge-tts。请重新打开桌面 App，或在本地服务的 Python 环境中安装 requirements.txt。"

    rate_percent = round((speed - 1) * 100)
    rate = f"{rate_percent:+d}%"
    try:
        with tempfile.TemporaryDirectory(prefix="reader-edge-tts-") as temp_dir:
            output_path = Path(temp_dir) / "paragraph.mp3"
            communicate = edge_tts.Communicate(text=text, voice=voice, rate=rate)
            asyncio.run(communicate.save(str(output_path)))
            if not output_path.exists() or output_path.stat().st_size == 0:
                return None, "Edge TTS 未返回音频。"
            return output_path.read_bytes(), None
    except Exception as error:
        return None, f"Edge TTS 合成失败：{error}"


# ── CosyVoice helpers ─────────────────────────────────────────────────────────

def _cosyvoice_is_alive() -> bool:
    """Return True if the CosyVoice sidecar is responding on its port."""
    import socket
    try:
        with socket.create_connection(("127.0.0.1", COSYVOICE_PORT), timeout=1):
            return True
    except OSError:
        return False


def _ensure_cosyvoice_server() -> str | None:
    """Start the CosyVoice sidecar if not already running.
    Returns None on success, or an error string on failure."""
    global _cosyvoice_proc

    if _cosyvoice_is_alive():
        return None

    if not COSYVOICE_PYTHON.exists():
        return f"CosyVoice Python not found: {COSYVOICE_PYTHON}"
    if not COSYVOICE_SERVER_SCRIPT.exists():
        return f"CosyVoice server script not found: {COSYVOICE_SERVER_SCRIPT}"

    print("[ReaderAppServer] Starting CosyVoice sidecar...", file=sys.stderr, flush=True)
    log_path = ROOT_DIR / ".cosyvoice_server.log"
    log_file = open(log_path, "a")
    _cosyvoice_proc = subprocess.Popen(
        [str(COSYVOICE_PYTHON), str(COSYVOICE_SERVER_SCRIPT)],
        stdout=log_file, stderr=log_file,
        start_new_session=True,
    )

    # Wait up to 60 s for the model to load and the port to open
    for _ in range(60):
        time.sleep(1)
        if _cosyvoice_is_alive():
            print("[ReaderAppServer] CosyVoice sidecar is up.", file=sys.stderr, flush=True)
            return None
        if _cosyvoice_proc.poll() is not None:
            return "CosyVoice server process exited unexpectedly."

    return "CosyVoice server did not start within 60 s."


def _proxy_cosyvoice_tts(text: str, speed: float) -> dict:
    """Forward a TTS request to the CosyVoice sidecar and return its JSON."""
    import urllib.request as _req, urllib.error as _err
    body = json.dumps({"text": text, "speed": speed}).encode("utf-8")
    req = _req.Request(
        f"http://127.0.0.1:{COSYVOICE_PORT}/tts",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with _req.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except _err.HTTPError as e:
        return {"error": e.read().decode("utf-8", errors="ignore") or str(e)}
    except Exception as e:
        return {"error": str(e)}


class ReaderAppHandler(BaseHTTPRequestHandler):
    server_version = "ReaderAppServer/1.0"

    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, payload: bytes, status: int = 200, content_type: str = "application/octet-stream") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _read_json_body(self) -> dict:
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(content_length) if content_length else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def _is_esm_proxy_request(self, path: str) -> bool:
        return path.startswith(ESM_PROXY_PREFIXES)

    def _proxy_esm_asset(self, parsed) -> bool:
        if not self._is_esm_proxy_request(parsed.path):
            return False

        remote_path = parsed.path[4:] if parsed.path.startswith("/esm/") else parsed.path
        remote_url = f"{ESM_PROXY_ORIGIN}{remote_path}"
        query = parsed.query or ESM_PROXY_QUERY_OVERRIDES.get(remote_path, "")
        if query:
            remote_url = f"{remote_url}?{query}"

        req = Request(
            remote_url,
            headers={
                "User-Agent": "ReaderAppServer/1.0",
                "Accept": "*/*"
            },
            method="GET"
        )

        try:
            with urlopen(req, timeout=30) as resp:
                payload = resp.read()
                content_type = resp.headers.get("Content-Type", "application/javascript; charset=utf-8")
                self.send_response(resp.status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                self.wfile.write(payload)
            return True
        except HTTPError as err:
            body = err.read().decode("utf-8", errors="ignore")
            self._send_json({"error": body or str(err), "remoteUrl": remote_url}, status=err.code)
            return True
        except URLError as err:
            self._send_json({"error": str(err), "remoteUrl": remote_url}, status=502)
            return True

    def log_message(self, format: str, *args) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (
            self.client_address[0],
            self.log_date_time_string(),
            format % args,
        ))

    def _run_doubao_tts_with_retries(self, *, text: str, voice: str, speed: float = 1.0, env: dict) -> tuple[Path | None, str | None]:
        last_error = None
        for attempt in range(1, DOUBAO_TTS_MAX_RETRIES + 1):
            with tempfile.TemporaryDirectory(prefix="reader-doubao-") as tmpdir:
                input_path = Path(tmpdir) / "lesson.txt"
                output_path = Path(tmpdir) / "lesson.mp3"
                input_path.write_text(text, encoding="utf-8")
                cmd = [
                    str(DOUBAO_SPEECH_BIN),
                    "say",
                    "--text-file", str(input_path),
                    "--out", str(output_path),
                    "--voice", voice,
                    "--speed", str(speed)
                ]
                completed = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=90)
                stderr = (completed.stderr or "").strip()
                stdout = (completed.stdout or "").strip()

                if completed.returncode == 0 and output_path.exists():
                    persisted_output = Path(tempfile.NamedTemporaryFile(prefix="reader-doubao-audio-", suffix=".mp3", delete=False).name)
                    persisted_output.write_bytes(output_path.read_bytes())
                    return persisted_output, None

                last_error = stderr or stdout or "Hermes Doubao speech failed."
                print(
                    f"[ReaderAppServer] Doubao TTS attempt {attempt}/{DOUBAO_TTS_MAX_RETRIES} failed for voice={voice}: {last_error}",
                    file=sys.stderr,
                    flush=True
                )
                if attempt < DOUBAO_TTS_MAX_RETRIES:
                    time.sleep(DOUBAO_TTS_RETRY_DELAY_SECONDS)

        return None, last_error

    def _serve_static(self, relative_path: str) -> None:
        path = unquote(relative_path.lstrip("/")) or "index.html"
        file_path = (ROOT_DIR / path).resolve()
        if not str(file_path).startswith(str(ROOT_DIR)) or not file_path.exists() or not file_path.is_file():
            self._send_json({"error": "Not found"}, status=404)
            return

        content_type, _ = mimetypes.guess_type(str(file_path))
        self._send_bytes(file_path.read_bytes(), content_type=content_type or "text/html; charset=utf-8")

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if self._proxy_esm_asset(parsed):
            return
        if parsed.path == "/api/tts/query":
            params = parse_qs(parsed.query)
            task_id = (params.get("task_id") or [""])[0]
            app_id = (params.get("appid") or [""])[0] or LOCAL_CONFIG.get("volcengineAppId", "")
            token = LOCAL_CONFIG.get("volcengineAccessToken", "")

            if not task_id or not app_id or not token:
                self._send_json({"error": "Missing task_id, appid, or local token."}, status=400)
                return

            req = Request(
                f"{TTS_QUERY_URL}?appid={app_id}&task_id={task_id}",
                headers={
                    "Authorization": f"Bearer; {token}",
                    "Resource-Id": TTS_RESOURCE_ID
                },
                method="GET"
            )

            try:
                with urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    self._send_json(data)
            except HTTPError as err:
                body = err.read().decode("utf-8", errors="ignore")
                self._send_json({"error": body or str(err)}, status=err.code)
            except URLError as err:
                self._send_json({"error": str(err)}, status=502)
            return

        if parsed.path == "/api/cosyvoice/status":
            alive = _cosyvoice_is_alive()
            self._send_json({"running": alive})
            return

        self._serve_static(parsed.path)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/log/save":
            payload = self._read_json_body()
            sentence_id = payload.get("sentenceId")
            sentence_text = payload.get("sentenceText")
            provider = payload.get("provider")
            model = payload.get("model")
            status = payload.get("status")
            error_msg = payload.get("error", "")
            log_content = payload.get("logContent", "")

            log_dir = ROOT_DIR / "data"
            log_dir.mkdir(parents=True, exist_ok=True)
            log_file = log_dir / "ai_teacher_generation.log"

            timestamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())

            log_entry = {
                "timestamp": timestamp,
                "sentenceId": sentence_id,
                "sentenceText": sentence_text,
                "provider": provider,
                "model": model,
                "status": status,
                "error": error_msg,
                "logContent": log_content
            }

            try:
                with open(log_file, "a", encoding="utf-8") as f:
                    f.write(json.dumps(log_entry, ensure_ascii=False) + "\n")
                self._send_json({"ok": True})
            except Exception as e:
                self._send_json({"error": f"Failed to write log: {str(e)}"}, status=500)
            return

        if parsed.path == "/api/tts/edge":
            payload = self._read_json_body()
            text = " ".join((payload.get("text") or "").split())
            voice = (payload.get("voice") or "en-US-AriaNeural").strip()
            try:
                speed = float(payload.get("speed", 1.0))
            except (TypeError, ValueError):
                speed = 1.0

            if not text:
                self._send_json({"error": "Missing text."}, status=400)
                return
            if len(text) > EDGE_TTS_MAX_TEXT_LENGTH:
                self._send_json({"error": f"Text exceeds the {EDGE_TTS_MAX_TEXT_LENGTH}-character limit."}, status=400)
                return
            if voice not in EDGE_TTS_VOICES:
                self._send_json({"error": "Unsupported Edge voice."}, status=400)
                return

            speed = min(EDGE_TTS_MAX_SPEED, max(EDGE_TTS_MIN_SPEED, speed))
            print(
                f"[ReaderAppServer] TTS edge voice={voice} speed={speed:.1f} chars={len(text)}",
                file=sys.stderr,
                flush=True,
            )
            audio, error = _synthesize_edge_tts(text=text, voice=voice, speed=speed)
            if error or audio is None:
                self._send_json({"error": error or "Edge TTS synthesis failed."}, status=502)
                return
            self._send_json({
                "ok": True,
                "provider": "edge-tts",
                "voice": voice,
                "mimeType": "audio/mpeg",
                "audioBase64": base64.b64encode(audio).decode("ascii"),
            })
            return

        if parsed.path == "/api/tts/hermes":
            if DOUBAO_TTS_DISABLED:
                self._send_json({
                    "error": "豆包语音已临时关闭（避免按量计费），请使用 CosyVoice 本地服务。"
                }, status=403)
                return
            payload = self._read_json_body()
            text = (payload.get("text") or "").strip()
            voice = (payload.get("voice") or "zh-female-warm").strip()
            speed_val = payload.get("speed")
            try:
                speed = float(speed_val) if speed_val is not None else 1.0
            except (ValueError, TypeError):
                speed = 1.0

            if not text:
                self._send_json({"error": "Missing text."}, status=400)
                return
            if not DOUBAO_SPEECH_BIN.exists():
                self._send_json({"error": "Hermes Doubao speech CLI not found."}, status=500)
                return

            env = os.environ.copy()
            if LOCAL_CONFIG.get("volcengineAppId"):
                env["VOLCENGINE_APP_ID"] = str(LOCAL_CONFIG["volcengineAppId"])
            if LOCAL_CONFIG.get("volcengineAccessToken"):
                env["VOLCENGINE_ACCESS_TOKEN"] = str(LOCAL_CONFIG["volcengineAccessToken"])
            print(
                f"[ReaderAppServer] TTS doubao/hermes voice={voice} chars={len(text)}",
                file=sys.stderr,
                flush=True,
            )
            output_path, error_message = self._run_doubao_tts_with_retries(text=text, voice=voice, speed=speed, env=env)
            if not output_path:
                self._send_json({
                    "error": error_message or "Hermes Doubao speech failed after retries."
                }, status=502)
                return

            try:
                audio_b64 = base64.b64encode(output_path.read_bytes()).decode("ascii")
                self._send_json({
                    "ok": True,
                    "provider": "doubao",
                    "mimeType": "audio/mpeg",
                    "audioBase64": audio_b64
                })
            finally:
                with contextlib.suppress(FileNotFoundError):
                    output_path.unlink()
            return

        if parsed.path == "/api/tts/cosyvoice":
            payload = self._read_json_body()
            text  = (payload.get("text") or "").strip()
            speed_val = payload.get("speed")
            try:
                speed = float(speed_val) if speed_val is not None else 1.0
            except (ValueError, TypeError):
                speed = 1.0

            if not text:
                self._send_json({"error": "Missing text."}, status=400)
                return

            print(
                f"[ReaderAppServer] TTS cosyvoice chars={len(text)}",
                file=sys.stderr,
                flush=True,
            )
            err = _ensure_cosyvoice_server()
            if err:
                self._send_json({"error": err}, status=503)
                return

            result = _proxy_cosyvoice_tts(text, speed)
            if result.get("error"):
                self._send_json({"error": result["error"]}, status=502)
            else:
                result["provider"] = "cosyvoice"
                self._send_json(result)
            return

        if parsed.path != "/api/tts/submit":
            self._send_json({"error": "Not found"}, status=404)
            return

        payload = self._read_json_body()
        token = LOCAL_CONFIG.get("volcengineAccessToken", "")
        app_id = payload.get("appid") or LOCAL_CONFIG.get("volcengineAppId", "")

        if not token or not app_id:
            self._send_json({"error": "Missing local Doubao voice credentials."}, status=400)
            return

        payload["appid"] = app_id

        req = Request(
            TTS_SUBMIT_URL,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer; {token}",
                "Resource-Id": TTS_RESOURCE_ID
            },
            data=json.dumps(payload).encode("utf-8"),
            method="POST"
        )

        try:
            with urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                self._send_json(data)
        except HTTPError as err:
            body = err.read().decode("utf-8", errors="ignore")
            self._send_json({"error": body or str(err)}, status=err.code)
        except URLError as err:
            self._send_json({"error": str(err)}, status=502)


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), ReaderAppHandler)
    print(f"Serving reader app from {ROOT_DIR} on http://127.0.0.1:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
