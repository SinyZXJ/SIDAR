"""Validation for phone scene packages."""

from __future__ import annotations

import json
from collections import Counter
from collections.abc import Sequence
from pathlib import Path

import numpy as np
from PIL import Image

from .coordinates import arkit_cam_to_world_to_ros_optical
from .io import load_phone_scene, read_confidence_u8, read_depth_f32


def _warn(warnings: list[dict], code: str, message: str, **details: object) -> None:
    payload = {"code": code, "message": message}
    payload.update(details)
    warnings.append(payload)


def _rgb_size(path: Path) -> tuple[int, int]:
    with Image.open(path) as image:
        return image.size


def _rotation_quality(rotation: np.ndarray) -> tuple[float, float]:
    identity_error = float(np.linalg.norm(rotation.T @ rotation - np.eye(3)))
    determinant = float(np.linalg.det(rotation))
    return identity_error, determinant


def _point_in_polygon_xy(point: Sequence[float], polygon: Sequence[Sequence[float]]) -> bool:
    if len(polygon) < 3:
        return False

    x = float(point[0])
    y = float(point[1])
    inside = False
    previous = polygon[-1]
    for current in polygon:
        current_y = float(current[1])
        previous_y = float(previous[1])
        crosses = (current_y > y) != (previous_y > y)
        if crosses:
            denominator = previous_y - current_y
            if abs(denominator) > np.finfo(float).eps:
                x_intersection = (
                    (float(previous[0]) - float(current[0])) * (y - current_y) / denominator
                    + float(current[0])
                )
                if x < x_intersection:
                    inside = not inside
        previous = current
    return inside


def _validate_gt_room_coverage(
    scene_root: Path,
    camera_positions_ros: np.ndarray,
    warnings: list[dict],
    *,
    low_coverage_threshold: float = 0.20,
) -> dict | None:
    gt_path = scene_root / "annotation" / "gt_rooms.json"
    if not gt_path.exists():
        return None

    try:
        gt = json.loads(gt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        _warn(
            warnings,
            "gt_rooms_unreadable",
            "annotation/gt_rooms.json could not be read; GT coverage was not checked.",
            error=str(exc),
        )
        return None

    rooms = gt.get("rooms")
    if not isinstance(rooms, list):
        _warn(
            warnings,
            "gt_rooms_invalid",
            "annotation/gt_rooms.json does not contain a valid rooms list.",
        )
        return None

    room_reports: list[dict] = []
    covered_mask = np.zeros(len(camera_positions_ros), dtype=bool)

    for index, room in enumerate(rooms):
        if not isinstance(room, dict):
            _warn(warnings, "gt_room_invalid", "GT room entry is not an object.", room_index=index)
            continue

        room_id = int(room.get("room_id", index))
        label = str(room.get("label", "unknown"))
        polygon = room.get("polygon_xy")
        try:
            min_z = float(room.get("min_z", -np.inf))
            max_z = float(room.get("max_z", np.inf))
        except (TypeError, ValueError):
            min_z = -np.inf
            max_z = np.inf
            _warn(
                warnings,
                "gt_room_invalid_z_range",
                "GT room z range is not numeric; coverage check used an unbounded z range.",
                room_id=room_id,
                label=label,
            )

        if not isinstance(polygon, list) or len(polygon) < 3:
            _warn(
                warnings,
                "gt_room_invalid_polygon",
                "GT room polygon_xy is missing or has fewer than 3 points.",
                room_id=room_id,
                label=label,
            )
            room_reports.append(
                {
                    "room_id": room_id,
                    "label": label,
                    "trajectory_frames": 0,
                    "min_z": min_z,
                    "max_z": max_z,
                }
            )
            continue

        if min_z >= max_z:
            _warn(
                warnings,
                "gt_room_invalid_z_range",
                "GT room min_z must be smaller than max_z.",
                room_id=room_id,
                label=label,
                min_z=min_z,
                max_z=max_z,
            )

        inside = np.array(
            [
                _point_in_polygon_xy((position[0], position[1]), polygon)
                and min_z <= float(position[2]) <= max_z
                for position in camera_positions_ros
            ],
            dtype=bool,
        )
        frame_count = int(np.sum(inside))
        covered_mask |= inside
        room_reports.append(
            {
                "room_id": room_id,
                "label": label,
                "trajectory_frames": frame_count,
                "min_z": min_z,
                "max_z": max_z,
            }
        )

        if frame_count == 0:
            _warn(
                warnings,
                "gt_room_zero_trajectory_frames",
                "No camera trajectory frames fall inside this GT room polygon and z range.",
                room_id=room_id,
                label=label,
                min_z=min_z,
                max_z=max_z,
            )

    covered_count = int(np.sum(covered_mask))
    trajectory_count = int(len(camera_positions_ros))
    coverage_ratio = covered_count / max(trajectory_count, 1)
    if rooms and coverage_ratio < low_coverage_threshold:
        _warn(
            warnings,
            "gt_low_trajectory_coverage",
            "Only a small share of camera trajectory frames fall inside GT room polygons.",
            covered_frames=covered_count,
            total_frames=trajectory_count,
            coverage_ratio=coverage_ratio,
        )

    return {
        "path": str(gt_path),
        "room_count": len(room_reports),
        "trajectory_frame_count": trajectory_count,
        "covered_frame_count": covered_count,
        "coverage_ratio": coverage_ratio,
        "rooms": room_reports,
    }


def validate_phone_scene(root: Path | str) -> dict:
    scene = load_phone_scene(root)
    if not scene.frames:
        raise ValueError(f"No frames in {scene.root}")

    missing: list[str] = []
    warnings: list[dict] = []
    finite_ratios: list[float] = []
    pose_steps: list[float] = []
    camera_positions_ros: list[np.ndarray] = []
    tracking_states = Counter()
    previous_translation = None

    for frame in scene.frames:
        frame_missing = False
        for path in (frame.rgb, frame.depth):
            if not path.exists():
                missing.append(str(path))
                frame_missing = True
        if frame.confidence and not frame.confidence.exists():
            missing.append(str(frame.confidence))
            frame_missing = True
        if frame_missing:
            continue
        if frame.intrinsics.shape != (3, 3):
            raise ValueError(f"Invalid intrinsics for frame {frame.frame_id}")
        if frame.camera_to_world_arkit.shape != (4, 4):
            raise ValueError(f"Invalid camera pose for frame {frame.frame_id}")

        if not np.all(np.isfinite(frame.intrinsics)):
            raise ValueError(f"Non-finite intrinsics for frame {frame.frame_id}")
        if frame.intrinsics[0, 0] <= 0.0 or frame.intrinsics[1, 1] <= 0.0:
            raise ValueError(f"Invalid focal length for frame {frame.frame_id}")
        if not np.all(np.isfinite(frame.camera_to_world_arkit)):
            raise ValueError(f"Non-finite camera pose for frame {frame.frame_id}")
        if not np.allclose(frame.camera_to_world_arkit[3], [0.0, 0.0, 0.0, 1.0], atol=1e-4):
            _warn(
                warnings,
                "pose_last_row",
                "Camera pose last row is not close to homogeneous transform convention.",
                frame_id=frame.frame_id,
                last_row=frame.camera_to_world_arkit[3].tolist(),
            )

        rotation_error, rotation_det = _rotation_quality(frame.camera_to_world_arkit[:3, :3])
        if rotation_error > 1e-2 or abs(rotation_det - 1.0) > 1e-2:
            _warn(
                warnings,
                "pose_rotation_quality",
                "Camera pose rotation is not close to orthonormal.",
                frame_id=frame.frame_id,
                orthonormal_error=rotation_error,
                determinant=rotation_det,
            )

        width, height = _rgb_size(frame.rgb)
        if (width, height) != (frame.image_width, frame.image_height):
            raise ValueError(
                f"RGB size mismatch for frame {frame.frame_id}: "
                f"{width}x{height}, expected {frame.image_width}x{frame.image_height}"
            )

        if frame.depth.exists():
            depth = read_depth_f32(frame.depth, frame.depth_width, frame.depth_height)
            finite = np.isfinite(depth) & (depth > 0.05) & (depth < 20.0)
            finite_ratio = float(np.mean(finite))
            finite_ratios.append(finite_ratio)
            if finite_ratio < 0.35:
                _warn(
                    warnings,
                    "low_depth_valid_ratio",
                    "Depth valid-pixel ratio is low; reconstruction may be sparse.",
                    frame_id=frame.frame_id,
                    valid_ratio=finite_ratio,
                )

        confidence_width = int(frame.raw.get("confidence_width", frame.depth_width))
        confidence_height = int(frame.raw.get("confidence_height", frame.depth_height))
        if frame.confidence and frame.confidence.exists():
            if frame.confidence.stat().st_size == 0 or confidence_width == 0 or confidence_height == 0:
                _warn(
                    warnings,
                    "missing_confidence",
                    "Confidence map is empty for this frame.",
                    frame_id=frame.frame_id,
                )
            else:
                confidence = read_confidence_u8(frame.confidence, confidence_width, confidence_height)
                if confidence.shape != (frame.depth_height, frame.depth_width):
                    _warn(
                        warnings,
                        "confidence_depth_size_mismatch",
                        "Confidence map dimensions differ from depth dimensions.",
                        frame_id=frame.frame_id,
                        confidence_width=confidence_width,
                        confidence_height=confidence_height,
                        depth_width=frame.depth_width,
                        depth_height=frame.depth_height,
                    )

        cam_to_world = arkit_cam_to_world_to_ros_optical(frame.camera_to_world_arkit)
        translation = cam_to_world[:3, 3]
        camera_positions_ros.append(translation)
        if previous_translation is not None:
            pose_steps.append(float(np.linalg.norm(translation - previous_translation)))
        previous_translation = translation
        tracking_states[frame.tracking_state] += 1

    if missing:
        raise FileNotFoundError("Missing frame files:\n" + "\n".join(missing[:20]))

    timestamps = np.asarray([frame.timestamp for frame in scene.frames], dtype=np.float64)
    if np.any(np.diff(timestamps) <= 0.0):
        raise ValueError("Frame timestamps must be strictly increasing")
    intervals = np.diff(timestamps)
    if intervals.size:
        median_dt = float(np.median(intervals))
        if median_dt > 0.0:
            fps = 1.0 / median_dt
            slow_intervals = int(np.sum(intervals > median_dt * 2.5))
            if slow_intervals:
                _warn(
                    warnings,
                    "irregular_frame_intervals",
                    "Frame timestamps contain large gaps; capture likely dropped or throttled frames.",
                    estimated_fps=fps,
                    large_gap_count=slow_intervals,
                )

    if pose_steps and float(np.max(pose_steps)) > 1.0:
        _warn(
            warnings,
            "large_pose_step",
            "Adjacent camera poses contain a large translation jump.",
            max_pose_step_m=float(np.max(pose_steps)),
        )

    normal_count = int(tracking_states.get("normal", 0))
    normal_ratio = normal_count / max(len(scene.frames), 1)
    if normal_ratio < 0.7:
        _warn(
            warnings,
            "low_normal_tracking_ratio",
            "ARKit tracking was not normal for a large share of captured frames.",
            normal_ratio=normal_ratio,
        )

    capture_stats_path = scene.root / "capture_stats.json"
    capture_stats = None
    if capture_stats_path.exists():
        capture_stats = json.loads(capture_stats_path.read_text(encoding="utf-8"))
        dropped = int(capture_stats.get("dropped_writes", 0))
        failed = int(capture_stats.get("failed_writes", 0))
        if dropped:
            _warn(
                warnings,
                "dropped_writes",
                "Phone-side writer reported dropped frames during capture.",
                dropped_writes=dropped,
            )
        if failed:
            _warn(
                warnings,
                "failed_writes",
                "Phone-side writer reported failed frame writes.",
                failed_writes=failed,
                last_error=capture_stats.get("last_write_error"),
            )

    gt_rooms = _validate_gt_room_coverage(
        scene.root,
        np.asarray(camera_positions_ros, dtype=np.float64),
        warnings,
    )

    result = {
        "root": str(scene.root),
        "status": "warning" if warnings else "ok",
        "frames": len(scene.frames),
        "duration_s": float(timestamps[-1] - timestamps[0]) if len(timestamps) > 1 else 0.0,
        "mean_depth_valid_ratio": float(np.mean(finite_ratios)) if finite_ratios else 0.0,
        "min_depth_valid_ratio": float(np.min(finite_ratios)) if finite_ratios else 0.0,
        "mean_pose_step_m": float(np.mean(pose_steps)) if pose_steps else 0.0,
        "max_pose_step_m": float(np.max(pose_steps)) if pose_steps else 0.0,
        "tracking_states": dict(tracking_states),
        "has_arkit_mesh": scene.mesh_path is not None,
        "warnings": warnings,
    }
    if capture_stats is not None:
        result["capture_stats"] = capture_stats
    if gt_rooms is not None:
        result["gt_rooms"] = gt_rooms
    return result
