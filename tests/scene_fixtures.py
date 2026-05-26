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
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "rgb").mkdir()
    (root / "depth").mkdir()
    (root / "confidence").mkdir()
    (root / "mesh").mkdir()

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

    metadata = {
        "format": "phonescene",
        "format_version": 1,
        "depth_units": "meters",
        "pose": {"convention": "arkit_cam_to_world", "matrix_order": "row_major_4x4"},
    }
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
    (root / "manifest.jsonl").write_text(json.dumps(manifest) + "\n", encoding="utf-8")
    return root
