from __future__ import annotations

import json
from pathlib import Path

import pytest
from PIL import Image

from phone_scene_to_isaac.validation import validate_phone_scene
from phone_scene_to_isaac.io import load_phone_scene

from scene_fixtures import write_phone_scene


def _write_v2_mesh(scene: Path, *, face: str = "3 0 1 2 1") -> None:
    mesh_dir = scene / "mesh"
    mesh_dir.mkdir(exist_ok=True)
    (mesh_dir / "arkit_mesh_world.ply").write_text(
        "\n".join(
            [
                "ply",
                "format ascii 1.0",
                "element vertex 3",
                "property float x",
                "property float y",
                "property float z",
                "property float nx",
                "property float ny",
                "property float nz",
                "element face 1",
                "property list uchar int vertex_indices",
                "property uchar classification",
                "end_header",
                "0 0 0 0 1 0",
                "1 0 0 0 1 0",
                "0 0 1 0 1 0",
                face,
                "",
            ]
        ),
        encoding="utf-8",
    )
    (mesh_dir / "arkit_mesh_anchors.json").write_text(
        json.dumps(
            {
                "format": "phonescene_arkit_mesh_anchors",
                "format_version": 1,
                "coordinate_frame": "arkit_world_meters_y_up",
                "ply": "arkit_mesh_world.ply",
                "vertex_count": 3,
                "face_count": 1,
                "anchors": [
                    {
                        "anchor_id": "anchor-1",
                        "transform": [
                            [1, 0, 0, 0],
                            [0, 1, 0, 0],
                            [0, 0, 1, 0],
                            [0, 0, 0, 1],
                        ],
                        "vertex_offset": 0,
                        "vertex_count": 3,
                        "face_offset": 0,
                        "face_count": 1,
                        "has_normals": True,
                        "has_classification": True,
                    }
                ],
            }
        )
        + "\n",
        encoding="utf-8",
    )


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


def test_v2_capture_with_raw_and_smoothed_depth_passes_integrity(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", format_version=2)

    report = validate_phone_scene(scene)
    loaded = load_phone_scene(scene)

    assert report["format_version"] == 2
    assert report["reconstruction_input_ready"] is True
    assert report["capture_stats"]["base_capture_complete"] is True
    assert report["sign_bookmarks"]["count"] == 0
    assert report["session_events"]["event_types"] == {
        "recording_started": 1,
        "recording_stop_requested": 1,
    }
    assert loaded.frames[0].depth.name == "000000.f32"
    assert loaded.frames[0].depth.parent.name == "depth"
    assert loaded.frames[0].smoothed_depth is not None
    assert loaded.frames[0].smoothed_depth.parent.name == "depth_smoothed"


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("pending_writes_at_finish", 1, "pending frame writes"),
        ("failed_writes", 1, "failed frame writes"),
        ("dropped_writes", 1, "dropped frame writes"),
        ("rejected_after_stop", 1, "post-stop frame attempts"),
        ("base_capture_complete", False, "base_capture_complete=false"),
    ],
)
def test_v2_integrity_counters_are_hard_failures(
    tmp_path: Path,
    field: str,
    value: object,
    message: str,
) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", format_version=2)
    stats_path = scene / "capture_stats.json"
    stats = json.loads(stats_path.read_text(encoding="utf-8"))
    stats[field] = value
    stats_path.write_text(json.dumps(stats) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        validate_phone_scene(scene)


def test_legacy_pending_writes_are_also_rejected(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")
    (scene / "capture_stats.json").write_text(
        json.dumps(
            {
                "pending_writes_at_finish": 3,
                "dropped_writes": 0,
                "failed_writes": 0,
                "base_capture_complete": True,
            }
        )
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="pending frame writes"):
        validate_phone_scene(scene)


def test_v2_rejects_unreferenced_stream_files(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", format_version=2)
    (scene / "depth" / "orphan.f32").write_bytes(b"orphan")

    with pytest.raises(ValueError, match="Unreferenced files in depth"):
        validate_phone_scene(scene)


def test_manifest_path_cannot_escape_scene_root(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene")
    manifest_path = scene / "manifest.jsonl"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["rgb"] = "../outside.png"
    manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="Unsafe rgb path"):
        load_phone_scene(scene)


def test_v2_sign_bookmark_is_bound_to_exact_source_frame(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", format_version=2)
    bookmark = {
        "bookmark_id": "sign-1",
        "frame_id": 0,
        "frame_timestamp": 0.0,
        "created_at_utc": "2026-01-01T00:00:00Z",
        "source_rgb": "rgb/000000.png",
        "cue_type": "directional",
        "camera_to_world": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
        "tracking_state": "normal",
        "review_status": "unreviewed",
    }
    (scene / "annotation" / "sign_bookmarks.jsonl").write_text(
        json.dumps(bookmark) + "\n",
        encoding="utf-8",
    )
    stats_path = scene / "capture_stats.json"
    stats = json.loads(stats_path.read_text(encoding="utf-8"))
    stats["requested_sign_bookmarks"] = 1
    stats["written_sign_bookmarks"] = 1
    stats_path.write_text(json.dumps(stats) + "\n", encoding="utf-8")

    report = validate_phone_scene(scene)

    assert report["sign_bookmarks"]["count"] == 1
    assert report["sign_bookmarks"]["cue_types"] == {"directional": 1}


def test_v2_mesh_body_and_anchor_provenance_are_validated(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", format_version=2)
    _write_v2_mesh(scene)

    report = validate_phone_scene(scene)

    assert report["mesh"]["vertices"] == 3
    assert report["mesh"]["faces"] == 1
    assert report["mesh"]["anchor_count"] == 1
    assert report["mesh"]["classification_counts"] == {"1": 1}


def test_v2_mesh_rejects_out_of_range_face_indices(tmp_path: Path) -> None:
    scene = write_phone_scene(tmp_path / "scene.phonescene", format_version=2)
    _write_v2_mesh(scene, face="3 0 1 9 1")

    with pytest.raises(ValueError, match="invalid vertex"):
        validate_phone_scene(scene)
