from __future__ import annotations

import json
from pathlib import Path

import pytest
from PIL import Image

from phone_scene_to_isaac.validation import validate_phone_scene

from scene_fixtures import write_phone_scene


def test_validation_reports_quality_warnings_without_failing(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", tracking_state="limited_excessive_motion")
    (scene / "capture_stats.json").write_text(
        json.dumps({"dropped_writes": 3, "failed_writes": 0}) + "\n",
        encoding="utf-8",
    )

    report = validate_phone_scene(scene)

    assert report["status"] == "warning"
    codes = {warning["code"] for warning in report["warnings"]}
    assert "low_normal_tracking_ratio" in codes
    assert "dropped_writes" in codes


def test_validation_hard_fails_on_structural_rgb_size_mismatch(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")
    Image.new("RGB", (2, 2)).save(scene / "rgb" / "000000.png")

    with pytest.raises(ValueError, match="RGB size mismatch"):
        validate_phone_scene(scene)


def test_validation_reports_gt_coverage_warnings_without_failing(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")
    annotation = scene / "annotation"
    annotation.mkdir()
    (annotation / "gt_rooms.json").write_text(
        json.dumps(
            {
                "dataset": "real",
                "scene_id": "scene",
                "frame": "world",
                "rooms": [
                    {
                        "room_id": 0,
                        "label": "office",
                        "polygon_xy": [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]],
                        "min_z": -0.5,
                        "max_z": 0.5,
                    },
                    {
                        "room_id": 1,
                        "label": "staircase",
                        "polygon_xy": [[5.0, 5.0], [6.0, 5.0], [6.0, 6.0], [5.0, 6.0]],
                        "min_z": -0.5,
                        "max_z": 0.5,
                    },
                ],
            }
        )
        + "\n",
        encoding="utf-8",
    )

    report = validate_phone_scene(scene)

    assert report["status"] == "warning"
    assert report["gt_rooms"]["covered_frame_count"] == 1
    assert report["gt_rooms"]["rooms"][0]["trajectory_frames"] == 1
    assert report["gt_rooms"]["rooms"][1]["trajectory_frames"] == 0
    codes = {warning["code"] for warning in report["warnings"]}
    assert "gt_room_zero_trajectory_frames" in codes
