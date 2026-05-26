from __future__ import annotations

from io import BytesIO
from pathlib import Path

import pytest

from phone_scene_to_isaac.receiver import (
    ReceiverError,
    UploadRegistry,
    safe_relative_path,
    sanitize_scene_name,
)

from scene_fixtures import write_phone_scene


def test_sanitize_scene_name_keeps_phonescene_suffix() -> None:
    assert sanitize_scene_name("office demo.phonescene") == "office_demo.phonescene"
    assert sanitize_scene_name("../bad/name") == "name.phonescene"


@pytest.mark.parametrize("path", ["../metadata.json", "/tmp/file", "rgb/../metadata.json", ""])
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
