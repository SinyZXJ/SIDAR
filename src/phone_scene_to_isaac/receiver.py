"""HTTP receiver for SIDAR .phonescene uploads."""

from __future__ import annotations

import json
import shutil
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

from .validation import validate_phone_scene


class ReceiverError(Exception):
    """User-facing upload receiver error."""


@dataclass
class UploadSession:
    upload_id: str
    scene_name: str
    root: Path
    file_count: int
    total_bytes: int
    received_files: int = 0
    received_bytes: int = 0


class UploadRegistry:
    def __init__(self, output_dir: Path, *, validate: bool = False, overwrite: bool = False):
        self.output_dir = output_dir.expanduser().resolve()
        self.validate = validate
        self.overwrite = overwrite
        self.staging_dir = self.output_dir / ".sidar_uploads"
        self.sessions: dict[str, UploadSession] = {}
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.staging_dir.mkdir(parents=True, exist_ok=True)

    def start(self, scene_name: str, file_count: int, total_bytes: int) -> UploadSession:
        scene_name = sanitize_scene_name(scene_name)
        upload_id = uuid.uuid4().hex
        root = self.staging_dir / upload_id / scene_name
        root.mkdir(parents=True, exist_ok=False)
        session = UploadSession(
            upload_id=upload_id,
            scene_name=scene_name,
            root=root,
            file_count=max(0, int(file_count)),
            total_bytes=max(0, int(total_bytes)),
        )
        self.sessions[upload_id] = session
        return session

    def write_file(self, upload_id: str, relative_path: str, source, length: int) -> UploadSession:
        session = self._session(upload_id)
        safe_path = safe_relative_path(relative_path)
        target = session.root / safe_path
        target.parent.mkdir(parents=True, exist_ok=True)
        remaining = max(0, int(length))
        with target.open("wb") as stream:
            while remaining > 0:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ReceiverError(f"incomplete upload for {relative_path}")
                stream.write(chunk)
                remaining -= len(chunk)
        session.received_files += 1
        session.received_bytes += max(0, int(length))
        return session

    def finish(self, upload_id: str) -> dict[str, Any]:
        session = self._session(upload_id)
        target = self.output_dir / session.scene_name
        if target.exists():
            if self.overwrite:
                shutil.rmtree(target)
            else:
                target = unique_scene_path(target)

        validation_report: dict[str, Any] | None = None
        if self.validate:
            validation_report = validate_phone_scene(session.root)

        shutil.move(str(session.root), str(target))
        parent = session.root.parent
        if parent.exists():
            shutil.rmtree(parent, ignore_errors=True)
        self.sessions.pop(upload_id, None)

        return {
            "status": "ok",
            "scene_name": target.name,
            "scene_path": str(target),
            "received_files": session.received_files,
            "received_bytes": session.received_bytes,
            "validation": validation_report,
        }

    def cancel(self, upload_id: str) -> None:
        session = self.sessions.pop(upload_id, None)
        if session is None:
            return
        parent = session.root.parent
        if parent.exists():
            shutil.rmtree(parent, ignore_errors=True)

    def _session(self, upload_id: str) -> UploadSession:
        try:
            return self.sessions[upload_id]
        except KeyError as exc:
            raise ReceiverError(f"unknown upload_id: {upload_id}") from exc


def sanitize_scene_name(scene_name: str) -> str:
    name = Path(scene_name).name.strip()
    if name.endswith(".phonescene"):
        stem = name[: -len(".phonescene")]
    else:
        stem = name
    allowed = []
    for char in stem:
        if char.isalnum() or char in {"_", "-", " "}:
            allowed.append(char)
        else:
            allowed.append("_")
    normalized = "".join(allowed).replace(" ", "_").strip("_-.")
    if not normalized:
        raise ReceiverError("scene_name is empty")
    return f"{normalized}.phonescene"


def safe_relative_path(relative_path: str) -> Path:
    raw = unquote(relative_path).replace("\\", "/")
    path = Path(raw)
    if path.is_absolute():
        raise ReceiverError("absolute upload paths are not allowed")
    parts = path.parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise ReceiverError(f"unsafe upload path: {relative_path}")
    return Path(*parts)


def unique_scene_path(path: Path) -> Path:
    stem = path.name[: -len(".phonescene")] if path.name.endswith(".phonescene") else path.stem
    for index in range(2, 10_000):
        candidate = path.with_name(f"{stem}_{index}.phonescene")
        if not candidate.exists():
            return candidate
    raise ReceiverError(f"could not choose a unique path for {path}")


def format_bytes(size: int) -> str:
    value = float(max(0, int(size)))
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024.0 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{value:.1f} GB"


def serve_receiver(
    output_dir: Path,
    *,
    host: str = "0.0.0.0",
    port: int = 8765,
    token: str | None = None,
    validate: bool = False,
    overwrite: bool = False,
) -> None:
    registry = UploadRegistry(output_dir, validate=validate, overwrite=overwrite)

    class Handler(SidarUploadHandler):
        upload_registry = registry
        upload_token = token

    server = ThreadingHTTPServer((host, int(port)), Handler)
    token_text = "token required" if token else "no token"
    print(f"SIDAR receiver listening on http://{host}:{port} ({token_text})")
    print(f"Writing uploads to {registry.output_dir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nSIDAR receiver stopped")
    finally:
        server.server_close()


class SidarUploadHandler(BaseHTTPRequestHandler):
    server_version = "SIDARReceiver/0.1"
    upload_registry: UploadRegistry
    upload_token: str | None

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._write_json({"status": "ok", "service": "sidar-receiver"})
            return
        self._write_json({"error": "not found"}, status=404)

    def do_POST(self) -> None:  # noqa: N802
        try:
            self._require_token()
            parsed = urlparse(self.path)
            if parsed.path == "/api/uploads/start":
                payload = self._read_json()
                session = self.upload_registry.start(
                    str(payload.get("scene_name", "")),
                    int(payload.get("file_count", 0)),
                    int(payload.get("total_bytes", 0)),
                )
                print(
                    f"[upload {session.upload_id[:8]}] started {session.scene_name} "
                    f"({session.file_count} files, {format_bytes(session.total_bytes)})",
                    flush=True,
                )
                self._write_json(
                    {
                        "status": "started",
                        "upload_id": session.upload_id,
                        "scene_name": session.scene_name,
                    }
                )
                return
            if parsed.path == "/api/uploads/finish":
                payload = self._read_json()
                upload_id = str(payload.get("upload_id", ""))
                print(f"[upload {upload_id[:8]}] finalizing", flush=True)
                result = self.upload_registry.finish(upload_id)
                print(
                    f"[upload {upload_id[:8]}] complete -> {result['scene_path']} "
                    f"({result['received_files']} files, {format_bytes(result['received_bytes'])})",
                    flush=True,
                )
                self._write_json(result)
                return
            if parsed.path == "/api/uploads/cancel":
                payload = self._read_json()
                upload_id = str(payload.get("upload_id", ""))
                self.upload_registry.cancel(upload_id)
                print(f"[upload {upload_id[:8]}] cancelled", flush=True)
                self._write_json({"status": "cancelled"})
                return
            self._write_json({"error": "not found"}, status=404)
        except Exception as exc:  # pragma: no cover - exercised through CLI/manual use
            self._write_error(exc)

    def do_PUT(self) -> None:  # noqa: N802
        try:
            self._require_token()
            parsed = urlparse(self.path)
            if parsed.path != "/api/uploads/file":
                self._write_json({"error": "not found"}, status=404)
                return
            query = parse_qs(parsed.query)
            upload_id = query.get("upload_id", [""])[0]
            relative_path = query.get("path", [""])[0]
            length = int(self.headers.get("Content-Length", "0"))
            print(
                f"[upload {upload_id[:8]}] receiving {relative_path} "
                f"({format_bytes(length)})",
                flush=True,
            )
            session = self.upload_registry.write_file(
                upload_id,
                relative_path,
                self.rfile,
                length,
            )
            percent = (
                100.0 * float(session.received_bytes) / float(session.total_bytes)
                if session.total_bytes > 0
                else 100.0
            )
            print(
                f"[upload {session.upload_id[:8]}] received "
                f"{session.received_files}/{session.file_count} files, "
                f"{format_bytes(session.received_bytes)} / {format_bytes(session.total_bytes)} "
                f"({percent:.1f}%)",
                flush=True,
            )
            self._write_json(
                {
                    "status": "received",
                    "upload_id": session.upload_id,
                    "received_files": session.received_files,
                    "received_bytes": session.received_bytes,
                }
            )
        except Exception as exc:  # pragma: no cover - exercised through CLI/manual use
            self._write_error(exc)

    def log_message(self, format: str, *args) -> None:
        print(f"{self.address_string()} - {format % args}", flush=True)

    def _require_token(self) -> None:
        if not self.upload_token:
            return
        provided = self.headers.get("X-SIDAR-Token", "")
        if provided != self.upload_token:
            raise ReceiverError("invalid upload token")

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length) if length > 0 else b"{}"
        if not data:
            return {}
        return json.loads(data.decode("utf-8"))

    def _write_error(self, exc: Exception) -> None:
        status = 400 if isinstance(exc, (ReceiverError, ValueError, json.JSONDecodeError)) else 500
        print(f"[receiver error] {exc}", flush=True)
        self._write_json({"status": "error", "error": str(exc)}, status=status)

    def _write_json(self, payload: dict[str, Any], status: int = 200) -> None:
        data = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
