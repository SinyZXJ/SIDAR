"""I/O helpers for `.phonescene` and Isaac render packages."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

import numpy as np
from PIL import Image

from .types import PhoneFrame, PhoneScene, RenderFrame


def _read_jsonl(path: Path) -> Iterable[dict]:
    with path.open("r", encoding="utf-8") as stream:
        for line_no, line in enumerate(stream, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                yield json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSONL at {path}:{line_no}: {exc}") from exc


def load_phone_scene(root: Path | str) -> PhoneScene:
    root = Path(root).expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(root)
    metadata_path = root / "metadata.json"
    manifest_path = root / "manifest.jsonl"
    if not metadata_path.exists():
        raise FileNotFoundError(metadata_path)
    if not manifest_path.exists():
        raise FileNotFoundError(manifest_path)

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    frames: list[PhoneFrame] = []
    for entry in _read_jsonl(manifest_path):
        rgb = root / entry["rgb"]
        depth = root / entry["depth"]
        confidence_value = entry.get("confidence")
        confidence = root / confidence_value if confidence_value else None
        frame = PhoneFrame(
            frame_id=int(entry["frame_id"]),
            timestamp=float(entry["timestamp"]),
            rgb=rgb,
            depth=depth,
            confidence=confidence,
            image_width=int(entry["image_width"]),
            image_height=int(entry["image_height"]),
            depth_width=int(entry["depth_width"]),
            depth_height=int(entry["depth_height"]),
            intrinsics=np.asarray(entry["intrinsics"], dtype=np.float64).reshape(3, 3),
            camera_to_world_arkit=np.asarray(entry["camera_to_world"], dtype=np.float64).reshape(4, 4),
            tracking_state=str(entry.get("tracking_state", "unknown")),
            raw=entry,
        )
        frames.append(frame)

    mesh_path = root / "mesh" / "arkit_mesh_world.ply"
    return PhoneScene(root=root, metadata=metadata, frames=frames, mesh_path=mesh_path if mesh_path.exists() else None)


def read_rgb(path: Path) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    return np.asarray(image, dtype=np.uint8)


def read_depth_f32(path: Path, width: int, height: int) -> np.ndarray:
    data = np.fromfile(path, dtype="<f4")
    expected = int(width) * int(height)
    if data.size != expected:
        raise ValueError(f"{path} has {data.size} float32 values, expected {expected}")
    return data.reshape((height, width)).astype(np.float32, copy=False)


def read_confidence_u8(path: Path, width: int, height: int) -> np.ndarray:
    data = np.fromfile(path, dtype=np.uint8)
    expected = int(width) * int(height)
    if data.size != expected:
        raise ValueError(f"{path} has {data.size} uint8 values, expected {expected}")
    return data.reshape((height, width))


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, entries: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        for entry in entries:
            stream.write(json.dumps(entry, sort_keys=True))
            stream.write("\n")


def load_render_package(root: Path | str) -> list[RenderFrame]:
    root = Path(root).expanduser().resolve()
    manifest_path = root / "manifest.jsonl"
    if not manifest_path.exists():
        raise FileNotFoundError(manifest_path)

    frames: list[RenderFrame] = []
    for entry in _read_jsonl(manifest_path):
        frame = RenderFrame(
            frame_id=int(entry["frame_id"]),
            timestamp=float(entry["timestamp"]),
            rgb=root / entry["rgb"],
            depth=root / entry["depth"],
            width=int(entry["width"]),
            height=int(entry["height"]),
            intrinsics=np.asarray(entry["intrinsics"], dtype=np.float64).reshape(3, 3),
            camera_to_world_ros=np.asarray(entry["camera_to_world_ros"], dtype=np.float64).reshape(4, 4),
            raw=entry,
        )
        frames.append(frame)
    return frames


def read_render_depth(path: Path) -> np.ndarray:
    if path.suffix == ".npy":
        depth = np.load(path)
    else:
        depth = np.fromfile(path, dtype="<f4")
    if depth.ndim != 2:
        raise ValueError(f"Render depth must be a 2-D array: {path}")
    return depth.astype(np.float32, copy=False)
