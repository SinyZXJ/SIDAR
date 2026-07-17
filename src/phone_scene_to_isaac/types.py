"""Shared dataclasses for phone scene and rendered frame packages."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np


@dataclass(frozen=True)
class PhoneFrame:
    frame_id: int
    timestamp: float
    rgb: Path
    depth: Path
    confidence: Path | None
    smoothed_depth: Path | None
    smoothed_confidence: Path | None
    image_width: int
    image_height: int
    depth_width: int
    depth_height: int
    intrinsics: np.ndarray
    camera_to_world_arkit: np.ndarray
    tracking_state: str
    raw: dict[str, Any]


@dataclass(frozen=True)
class PhoneScene:
    root: Path
    metadata: dict[str, Any]
    frames: list[PhoneFrame]
    mesh_path: Path | None
    mesh_anchor_metadata_path: Path | None


@dataclass(frozen=True)
class RenderFrame:
    frame_id: int
    timestamp: float
    rgb: Path
    depth: Path
    width: int
    height: int
    intrinsics: np.ndarray
    camera_to_world_ros: np.ndarray
    raw: dict[str, Any]
