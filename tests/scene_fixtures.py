from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image


def write_phone_scene(
    root: Path,
    *,
    image_size: tuple[int, int] = (4, 4),
    depth_size: tuple[int, int] = (4, 4),
    depth: np.ndarray | None = None,
    tracking_state: str = "normal",
    format_version: int = 1,
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "rgb").mkdir()
    (root / "depth").mkdir()
    (root / "confidence").mkdir()
    (root / "mesh").mkdir()
    if format_version == 2:
        (root / "depth_smoothed").mkdir()
        (root / "confidence_smoothed").mkdir()
        (root / "annotation").mkdir()

    width, height = image_size
    depth_width, depth_height = depth_size
    if depth is None:
        depth = np.ones((depth_height, depth_width), dtype=np.float32)
    depth = np.asarray(depth, dtype="<f4").reshape((depth_height, depth_width))

    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    rgb[:, :, 0] = np.linspace(0, 255, width, dtype=np.uint8)[None, :]
    rgb[:, :, 1] = np.linspace(0, 255, height, dtype=np.uint8)[:, None]
    Image.fromarray(rgb).save(root / "rgb" / "000000.png")
    depth.tofile(root / "depth" / "000000.f32")
    np.full((depth_height, depth_width), 2, dtype=np.uint8).tofile(
        root / "confidence" / "000000.u8"
    )
    if format_version == 2:
        depth.tofile(root / "depth_smoothed" / "000000.f32")
        np.full((depth_height, depth_width), 2, dtype=np.uint8).tofile(
            root / "confidence_smoothed" / "000000.u8"
        )

    metadata = {
        "format": "phonescene",
        "format_version": format_version,
        "depth_units": "meters",
        "pose": {"convention": "arkit_cam_to_world", "matrix_order": "row_major_4x4"},
    }
    if format_version == 2:
        metadata.update(
            {
                "capture_id": "fixture-capture-id",
                "primary_depth_stream": "scene_depth_raw",
                "world_alignment": "gravity",
                "rgb_orientation": "native_sensor",
                "camera_model": "arkit_lidar",
                "device_info": {"hardware_identifier": "fixture-iphone"},
                "app": {
                    "name": "SIDAR",
                    "version": "2.0",
                    "build": "2",
                    "git_commit": "fixture",
                },
                "capture": {
                    "requested_fps": 10,
                    "raw_scene_depth_enabled": True,
                    "smoothed_scene_depth_enabled": True,
                    "mesh_expected": False,
                    "scene_reconstruction_mode": "none",
                },
            }
        )
    (root / "metadata.json").write_text(json.dumps(metadata) + "\n", encoding="utf-8")
    intrinsics = [
        [float(width), 0.0, (width - 1.0) * 0.5],
        [0.0, float(height), (height - 1.0) * 0.5],
        [0.0, 0.0, 1.0],
    ]
    manifest = {
        "frame_id": 0,
        "timestamp": 0.0,
        "rgb": "rgb/000000.png",
        "depth": "depth/000000.f32",
        "confidence": "confidence/000000.u8",
        "image_width": width,
        "image_height": height,
        "depth_width": depth_width,
        "depth_height": depth_height,
        "confidence_width": depth_width,
        "confidence_height": depth_height,
        "intrinsics": intrinsics,
        "camera_to_world": np.eye(4, dtype=np.float64).tolist(),
        "tracking_state": tracking_state,
    }
    if format_version == 2:
        manifest.update(
            {
                "depth_source": "scene_depth_raw",
                "image_pixel_format": "420f",
                "depth_pixel_format": "fdep",
                "confidence_pixel_format": "L008",
                "smoothed_depth": "depth_smoothed/000000.f32",
                "smoothed_confidence": "confidence_smoothed/000000.u8",
                "smoothed_depth_width": depth_width,
                "smoothed_depth_height": depth_height,
                "smoothed_confidence_width": depth_width,
                "smoothed_confidence_height": depth_height,
                "smoothed_depth_pixel_format": "fdep",
                "smoothed_confidence_pixel_format": "L008",
            }
        )
    (root / "manifest.jsonl").write_text(json.dumps(manifest) + "\n", encoding="utf-8")
    if format_version == 2:
        (root / "capture_stats.json").write_text(
            json.dumps(
                {
                    "capture_id": "fixture-capture-id",
                    "format_version": 2,
                    "accepted_frames": 1,
                    "written_frames": 1,
                    "pending_writes_at_finish": 0,
                    "dropped_writes": 0,
                    "rejected_after_stop": 0,
                    "failed_writes": 0,
                    "requested_sign_bookmarks": 0,
                    "written_sign_bookmarks": 0,
                    "failed_sign_bookmarks": 0,
                    "failed_session_events": 0,
                    "base_capture_complete": True,
                    "integrity_failures": [],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (root / "annotation" / "sign_bookmarks.jsonl").write_text("", encoding="utf-8")
        events = [
            {
                "event_id": "event-start",
                "event_type": "recording_started",
                "wall_time_utc": "2026-01-01T00:00:00Z",
                "details": {},
            },
            {
                "event_id": "event-stop",
                "event_type": "recording_stop_requested",
                "wall_time_utc": "2026-01-01T00:00:01Z",
                "details": {},
            },
        ]
        (root / "session_events.jsonl").write_text(
            "".join(json.dumps(event) + "\n" for event in events),
            encoding="utf-8",
        )
    return root
