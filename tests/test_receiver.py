from __future__ import annotations

import json
import threading
from io import BytesIO
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import pytest

from phone_scene_to_isaac.receiver import (
    ReceiverError,
    SidarUploadHandler,
    UploadRegistry,
    safe_relative_path,
    sanitize_scene_name,
)

from scene_fixtures import write_phone_scene


def test_sanitize_scene_name_keeps_phonescene_suffix() -> None:
    assert sanitize_scene_name("office demo.phonescene") == "office_demo.phonescene"
    assert sanitize_scene_name("../bad/name") == "name.phonescene"


@pytest.mark.parametrize(
    "path",
    ["../metadata.json", "/tmp/file", "rgb/../metadata.json", "rgb//000000.png", ""],
)
def test_safe_relative_path_rejects_unsafe_paths(path: str) -> None:
    with pytest.raises(ReceiverError):
        safe_relative_path(path)


def test_upload_registry_writes_and_finishes_scene(tmp_path: Path) -> None:
    source = write_phone_scene(tmp_path / "source.phonescene")
    output = tmp_path / "received"
    registry = UploadRegistry(output, validate=True)

    files = [path for path in source.rglob("*") if path.is_file()]
    total_bytes = sum(path.stat().st_size for path in files)
    session = registry.start("lab capture.phonescene", len(files), total_bytes)

    for path in files:
        relative = path.relative_to(source).as_posix()
        registry.write_file(session.upload_id, relative, BytesIO(path.read_bytes()), path.stat().st_size)

    result = registry.finish(session.upload_id)

    target = output / "lab_capture.phonescene"
    assert result["status"] == "ok"
    assert Path(result["scene_path"]) == target
    assert target.is_dir()
    assert (target / "metadata.json").exists()
    assert result["received_files"] == len(files)
    assert result["validation"]["status"] in {"ok", "warning"}


class ReceiverTestServer:
    def __init__(self, output_dir: Path, *, token: str | None = "secret-token") -> None:
        registry = UploadRegistry(output_dir, validate=False)

        class Handler(SidarUploadHandler):
            upload_registry = registry
            upload_token = token

        self.registry = registry
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        host, port = self.server.server_address
        self.base_url = f"http://{host}:{port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "ReceiverTestServer":
        self.thread.start()
        return self

    def __exit__(self, *args: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)


def request_json(
    method: str,
    url: str,
    *,
    token: str | None = None,
    payload: dict | None = None,
    body: bytes | None = None,
) -> tuple[int, dict]:
    data: bytes | None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    else:
        data = body
    request = Request(url, data=data, method=method)
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    if token is not None:
        request.add_header("X-SIDAR-Token", token)
    try:
        with urlopen(request, timeout=5) as response:
            return int(response.status), json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        return int(exc.code), json.loads(exc.read().decode("utf-8"))


def test_health_does_not_require_token(tmp_path: Path) -> None:
    with ReceiverTestServer(tmp_path / "received", token="secret-token") as server:
        status, payload = request_json("GET", f"{server.base_url}/health")

    assert status == 200
    assert payload["status"] == "ok"


def test_auth_check_requires_correct_token(tmp_path: Path) -> None:
    with ReceiverTestServer(tmp_path / "received", token="secret-token") as server:
        missing_status, missing_payload = request_json(
            "GET",
            f"{server.base_url}/api/uploads/auth-check",
        )
        wrong_status, wrong_payload = request_json(
            "GET",
            f"{server.base_url}/api/uploads/auth-check",
            token="wrong-token",
        )
        ok_status, ok_payload = request_json(
            "GET",
            f"{server.base_url}/api/uploads/auth-check",
            token="secret-token",
        )

    assert missing_status == 400
    assert missing_payload["error"] == "invalid upload token"
    assert wrong_status == 400
    assert wrong_payload["error"] == "invalid upload token"
    assert ok_status == 200
    assert ok_payload["status"] == "ok"


def test_http_upload_writes_staging_then_finishes_to_output(tmp_path: Path) -> None:
    output = tmp_path / "received"
    with ReceiverTestServer(output, token="secret-token") as server:
        start_status, start_payload = request_json(
            "POST",
            f"{server.base_url}/api/uploads/start",
            token="secret-token",
            payload={
                "scene_name": "field test.phonescene",
                "file_count": 1,
                "total_bytes": 13,
            },
        )
        assert start_status == 200
        upload_id = start_payload["upload_id"]

        staging_file = output / ".sidar_uploads" / upload_id / "field_test.phonescene" / "notes.txt"
        assert not staging_file.exists()

        query = urlencode({"upload_id": upload_id, "path": "notes.txt"})
        file_status, file_payload = request_json(
            "PUT",
            f"{server.base_url}/api/uploads/file?{query}",
            token="secret-token",
            body=b"hello, sidar!",
        )

        assert file_status == 200
        assert file_payload["received_files"] == 1
        assert staging_file.read_bytes() == b"hello, sidar!"

        finish_status, finish_payload = request_json(
            "POST",
            f"{server.base_url}/api/uploads/finish",
            token="secret-token",
            payload={"upload_id": upload_id},
        )

    target = output / "field_test.phonescene"
    assert finish_status == 200
    assert finish_payload["status"] == "ok"
    assert target.joinpath("notes.txt").read_bytes() == b"hello, sidar!"
    assert not (output / ".sidar_uploads" / upload_id).exists()
