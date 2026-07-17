from __future__ import annotations

import json
from pathlib import Path

from phone_scene_to_isaac.cli import main

from scene_fixtures import write_phone_scene


def test_validate_cli_returns_structured_error_without_traceback(
    tmp_path: Path,
    capsys,
) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")
    (scene / "capture_stats.json").write_text(
        json.dumps({"pending_writes_at_finish": 3}) + "\n",
        encoding="utf-8",
    )

    exit_code = main(["validate", str(scene)])
    captured = capsys.readouterr()
    error = json.loads(captured.err)

    assert exit_code == 1
    assert captured.out == ""
    assert error["status"] == "error"
    assert error["error_type"] == "ValueError"
    assert "3 pending frame writes" in error["error"]
