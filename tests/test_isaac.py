from __future__ import annotations

from pathlib import Path

import pytest

from phone_scene_to_isaac.isaac import make_isaac_script

from scene_fixtures import write_phone_scene


def test_make_isaac_script_rejects_missing_usd(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")

    with pytest.raises(FileNotFoundError):
        make_isaac_script(scene, tmp_path / "missing.usda", tmp_path / "render.py", tmp_path / "renders")


def test_make_isaac_script_rejects_invalid_render_options(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")
    usd = tmp_path / "scene.usda"
    usd.write_text("#usda 1.0\n", encoding="utf-8")

    with pytest.raises(ValueError, match="frame_stride"):
        make_isaac_script(
            scene,
            usd,
            tmp_path / "render.py",
            tmp_path / "renders",
            frame_stride=0,
        )
