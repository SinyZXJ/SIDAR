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


def _read_jsonl_objects(path: Path) -> list[dict]:
    entries: list[dict] = []
    with path.open("r", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                entry = json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSONL at {path}:{line_number}: {exc}") from exc
            if not isinstance(entry, dict):
                raise ValueError(f"JSONL entry must be an object at {path}:{line_number}")
            entries.append(entry)
    return entries


def _validate_capture_metadata(metadata: dict) -> int:
    if metadata.get("format") != "phonescene":
        raise ValueError("metadata.json format must be 'phonescene'")
    format_version = int(metadata.get("format_version", 0))
    if format_version not in {1, 2}:
        raise ValueError(f"Unsupported PhoneScene format_version: {format_version}")
    if metadata.get("depth_units") != "meters":
        raise ValueError("PhoneScene depth_units must be meters")
    pose = metadata.get("pose")
    if not isinstance(pose, dict):
        raise ValueError("metadata.json pose contract is missing")
    if pose.get("convention") != "arkit_cam_to_world":
        raise ValueError("PhoneScene pose convention must be arkit_cam_to_world")
    if pose.get("matrix_order") != "row_major_4x4":
        raise ValueError("PhoneScene pose matrix_order must be row_major_4x4")
    if format_version == 2:
        capture_id = metadata.get("capture_id")
        if not isinstance(capture_id, str) or not capture_id.strip():
            raise ValueError("PhoneScene v2 metadata requires capture_id")
        if metadata.get("primary_depth_stream") != "scene_depth_raw":
            raise ValueError("PhoneScene v2 primary_depth_stream must be scene_depth_raw")
        if metadata.get("world_alignment") != "gravity":
            raise ValueError("PhoneScene v2 world_alignment must be gravity")
        if metadata.get("rgb_orientation") != "native_sensor":
            raise ValueError("PhoneScene v2 RGB must use the native sensor orientation")
        if metadata.get("camera_model") != "arkit_lidar":
            raise ValueError("PhoneScene v2 camera_model must be arkit_lidar")
        device_info = metadata.get("device_info")
        if not isinstance(device_info, dict) or not device_info.get("hardware_identifier"):
            raise ValueError("PhoneScene v2 requires device hardware provenance")
        capture = metadata.get("capture")
        if not isinstance(capture, dict) or not capture.get("raw_scene_depth_enabled"):
            raise ValueError("PhoneScene v2 requires raw ARKit scene depth")
        if int(capture.get("requested_fps", 0)) <= 0:
            raise ValueError("PhoneScene v2 requested_fps must be positive")
        if not isinstance(capture.get("scene_reconstruction_mode"), str):
            raise ValueError("PhoneScene v2 requires the scene reconstruction mode")
        app = metadata.get("app")
        if not isinstance(app, dict):
            raise ValueError("PhoneScene v2 metadata requires app provenance")
        for key in ("version", "build", "git_commit"):
            if not isinstance(app.get(key), str) or not str(app[key]).strip():
                raise ValueError(f"PhoneScene v2 app provenance requires {key}")
    return format_version


def _validate_capture_stats(scene, format_version: int, frame_count: int) -> dict | None:
    path = scene.root / "capture_stats.json"
    if not path.exists():
        if format_version == 2:
            raise ValueError("PhoneScene v2 capture_stats.json is required")
        return None
    try:
        stats = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"capture_stats.json is unreadable: {exc}") from exc
    if not isinstance(stats, dict):
        raise ValueError("capture_stats.json must contain an object")

    pending = int(stats.get("pending_writes_at_finish", 0))
    failed = int(stats.get("failed_writes", 0))
    dropped = int(stats.get("dropped_writes", 0))
    rejected_after_stop = int(stats.get("rejected_after_stop", 0))
    integrity_failures = stats.get("integrity_failures", [])
    if pending != 0:
        raise ValueError(f"capture finalized with {pending} pending frame writes")
    if failed != 0:
        raise ValueError(f"capture reports {failed} failed frame writes")
    if rejected_after_stop != 0:
        raise ValueError(f"capture reports {rejected_after_stop} post-stop frame attempts")
    if stats.get("base_capture_complete") is False:
        raise ValueError("capture_stats.json marks base_capture_complete=false")
    if integrity_failures:
        raise ValueError(f"capture reports integrity failures: {integrity_failures}")
    if format_version == 2:
        if dropped != 0:
            raise ValueError(f"PhoneScene v2 capture reports {dropped} dropped frame writes")
        if stats.get("base_capture_complete") is not True:
            raise ValueError("PhoneScene v2 must explicitly mark base_capture_complete=true")
        accepted = int(stats.get("accepted_frames", -1))
        written = int(stats.get("written_frames", -1))
        if accepted != frame_count or written != frame_count:
            raise ValueError(
                "capture frame counts disagree: "
                f"accepted={accepted}, written={written}, manifest={frame_count}"
            )
        if str(stats.get("capture_id", "")) != str(scene.metadata.get("capture_id", "")):
            raise ValueError("capture_id differs between metadata and capture_stats")
        requested_bookmarks = int(stats.get("requested_sign_bookmarks", -1))
        written_bookmarks = int(stats.get("written_sign_bookmarks", -1))
        if requested_bookmarks != written_bookmarks:
            raise ValueError("requested and written sign bookmark counts disagree")
        if int(stats.get("failed_sign_bookmarks", 0)) != 0:
            raise ValueError("capture reports failed sign bookmark writes")
        if int(stats.get("failed_session_events", 0)) != 0:
            raise ValueError("capture reports failed session event writes")
    return stats


def _validate_stream_file_set(
    scene_root: Path,
    directory: str,
    expected: set[Path],
    *,
    format_version: int,
) -> None:
    stream_root = scene_root / directory
    if not stream_root.exists():
        if expected or format_version == 2:
            raise FileNotFoundError(stream_root)
        return
    actual = {path.resolve() for path in stream_root.iterdir() if path.is_file()}
    missing = expected - actual
    if missing:
        raise FileNotFoundError(
            f"Missing {directory} files: " + ", ".join(str(path) for path in sorted(missing))
        )
    if format_version == 2:
        extras = actual - expected
        if extras:
            raise ValueError(
                f"Unreferenced files in {directory}: "
                + ", ".join(str(path.relative_to(scene_root)) for path in sorted(extras))
            )


def _validate_sign_bookmarks(scene, format_version: int, capture_stats: dict | None) -> dict:
    path = scene.root / "annotation" / "sign_bookmarks.jsonl"
    if not path.exists():
        if format_version == 2:
            raise ValueError("PhoneScene v2 requires annotation/sign_bookmarks.jsonl")
        return {"count": 0, "cue_types": {}}
    entries = _read_jsonl_objects(path)
    frame_by_id = {frame.frame_id: frame for frame in scene.frames}
    bookmark_ids: set[str] = set()
    cue_types = Counter()
    for index, entry in enumerate(entries):
        bookmark_id = str(entry.get("bookmark_id", ""))
        if not bookmark_id or bookmark_id in bookmark_ids:
            raise ValueError(f"Invalid or duplicate sign bookmark_id at index {index}")
        bookmark_ids.add(bookmark_id)
        frame_id = int(entry.get("frame_id", -1))
        if frame_id not in frame_by_id:
            raise ValueError(f"Sign bookmark references unknown frame_id {frame_id}")
        frame = frame_by_id[frame_id]
        expected_rgb = frame.rgb.relative_to(scene.root).as_posix()
        if entry.get("source_rgb") != expected_rgb:
            raise ValueError(f"Sign bookmark {bookmark_id} source_rgb does not match frame {frame_id}")
        if abs(float(entry.get("frame_timestamp", np.nan)) - frame.timestamp) > 1e-6:
            raise ValueError(f"Sign bookmark {bookmark_id} timestamp does not match source frame")
        pose = np.asarray(entry.get("camera_to_world"), dtype=np.float64)
        if pose.shape != (4, 4) or not np.all(np.isfinite(pose)):
            raise ValueError(f"Sign bookmark {bookmark_id} has an invalid camera pose")
        if not np.allclose(pose, frame.camera_to_world_arkit, atol=1e-5):
            raise ValueError(f"Sign bookmark {bookmark_id} pose does not match source frame")
        cue_type = str(entry.get("cue_type", ""))
        if cue_type not in {"unreviewed", "directional", "locational", "directory"}:
            raise ValueError(f"Sign bookmark {bookmark_id} has invalid cue_type {cue_type!r}")
        if entry.get("tracking_state") != frame.tracking_state:
            raise ValueError(f"Sign bookmark {bookmark_id} tracking state does not match its frame")
        if entry.get("review_status") != "unreviewed":
            raise ValueError(f"Sign bookmark {bookmark_id} has an invalid initial review status")
        if not str(entry.get("created_at_utc", "")).strip():
            raise ValueError(f"Sign bookmark {bookmark_id} has no creation timestamp")
        cue_types[cue_type] += 1
    if format_version == 2 and capture_stats is not None:
        written = int(capture_stats.get("written_sign_bookmarks", -1))
        if written != len(entries):
            raise ValueError(
                f"sign bookmark count disagrees: stats={written}, jsonl={len(entries)}"
            )
    return {"path": str(path), "count": len(entries), "cue_types": dict(cue_types)}


def _validate_session_events(scene, format_version: int) -> dict:
    path = scene.root / "session_events.jsonl"
    if not path.exists():
        if format_version == 2:
            raise ValueError("PhoneScene v2 requires session_events.jsonl")
        return {"count": 0, "event_types": {}}
    entries = _read_jsonl_objects(path)
    event_ids: set[str] = set()
    event_types = Counter()
    for index, entry in enumerate(entries):
        event_id = str(entry.get("event_id", ""))
        if not event_id or event_id in event_ids:
            raise ValueError(f"Invalid or duplicate session event_id at index {index}")
        event_ids.add(event_id)
        event_type = str(entry.get("event_type", ""))
        if not event_type:
            raise ValueError(f"Session event {event_id} has no event_type")
        if not str(entry.get("wall_time_utc", "")).strip():
            raise ValueError(f"Session event {event_id} has no wall-clock timestamp")
        if not isinstance(entry.get("details", {}), dict):
            raise ValueError(f"Session event {event_id} details must be an object")
        if entry.get("frame_timestamp") is not None and not np.isfinite(
            float(entry["frame_timestamp"])
        ):
            raise ValueError(f"Session event {event_id} has a non-finite frame timestamp")
        event_types[event_type] += 1
    if format_version == 2:
        if event_types.get("recording_started", 0) != 1:
            raise ValueError("PhoneScene v2 requires exactly one recording_started event")
        if event_types.get("recording_stop_requested", 0) != 1:
            raise ValueError("PhoneScene v2 requires exactly one recording_stop_requested event")
    return {"path": str(path), "count": len(entries), "event_types": dict(event_types)}


def _read_ply_header(path: Path) -> dict:
    vertex_count = None
    face_count = None
    vertex_properties: list[str] = []
    face_properties: list[str] = []
    section = None
    with path.open("r", encoding="utf-8") as stream:
        if stream.readline().strip() != "ply":
            raise ValueError(f"Not a PLY file: {path}")
        if stream.readline().strip() != "format ascii 1.0":
            raise ValueError(f"PhoneScene ARKit mesh must be ASCII PLY: {path}")
        for line in stream:
            parts = line.strip().split()
            if not parts:
                continue
            if parts[0] == "end_header":
                break
            if parts[:2] == ["element", "vertex"]:
                vertex_count = int(parts[2])
                section = "vertex"
            elif parts[:2] == ["element", "face"]:
                face_count = int(parts[2])
                section = "face"
            elif parts[0] == "property":
                if section == "vertex":
                    vertex_properties.append(parts[-1])
                elif section == "face":
                    face_properties.append(parts[-1])
        else:
            raise ValueError(f"PLY header has no end_header: {path}")
    if vertex_count is None or face_count is None or vertex_count <= 0 or face_count <= 0:
        raise ValueError(f"PLY header has invalid vertex/face counts: {path}")
    return {
        "vertices": vertex_count,
        "faces": face_count,
        "vertex_properties": vertex_properties,
        "face_properties": face_properties,
    }


def _validate_ply_body(path: Path, header: dict) -> dict[str, int]:
    vertex_count = int(header["vertices"])
    face_count = int(header["faces"])
    vertex_property_count = len(header["vertex_properties"])
    has_classification = "classification" in header["face_properties"]
    classification_counts: Counter[str] = Counter()

    with path.open("r", encoding="utf-8") as stream:
        for line in stream:
            if line.strip() == "end_header":
                break
        else:
            raise ValueError(f"PLY header has no end_header: {path}")

        for vertex_index in range(vertex_count):
            line = stream.readline()
            if not line:
                raise ValueError(f"PLY ended before vertex {vertex_index}: {path}")
            values = line.split()
            if len(values) != vertex_property_count:
                raise ValueError(f"PLY vertex {vertex_index} property count mismatch")
            try:
                numeric = np.asarray([float(value) for value in values], dtype=np.float64)
            except ValueError as exc:
                raise ValueError(f"PLY vertex {vertex_index} contains a non-number") from exc
            if not np.all(np.isfinite(numeric)):
                raise ValueError(f"PLY vertex {vertex_index} contains a non-finite value")

        for face_index in range(face_count):
            line = stream.readline()
            if not line:
                raise ValueError(f"PLY ended before face {face_index}: {path}")
            values = line.split()
            try:
                index_count = int(values[0])
            except (IndexError, ValueError) as exc:
                raise ValueError(f"PLY face {face_index} has no valid index count") from exc
            if index_count != 3:
                raise ValueError(f"PLY face {face_index} is not an ARKit triangle")
            expected_values = 1 + index_count + int(has_classification)
            if len(values) != expected_values:
                raise ValueError(f"PLY face {face_index} property count mismatch")
            try:
                indices = [int(value) for value in values[1 : 1 + index_count]]
            except ValueError as exc:
                raise ValueError(f"PLY face {face_index} has a non-integer vertex index") from exc
            if any(index < 0 or index >= vertex_count for index in indices):
                raise ValueError(f"PLY face {face_index} references an invalid vertex")
            if has_classification:
                try:
                    classification = int(values[-1])
                except ValueError as exc:
                    raise ValueError(f"PLY face {face_index} has an invalid classification") from exc
                if classification not in range(8):
                    raise ValueError(f"PLY face {face_index} has unknown ARKit classification")
                classification_counts[str(classification)] += 1

        if any(line.strip() for line in stream):
            raise ValueError(f"PLY contains records beyond its declared element counts: {path}")

    return dict(classification_counts)


def _validate_mesh(scene, format_version: int) -> dict | None:
    capture = scene.metadata.get("capture")
    mesh_expected = bool(capture.get("mesh_expected")) if isinstance(capture, dict) else False
    if scene.mesh_path is None:
        if format_version == 2 and mesh_expected:
            raise ValueError("PhoneScene v2 expected an ARKit mesh, but none was exported")
        return None
    report = _read_ply_header(scene.mesh_path)
    report["classification_counts"] = _validate_ply_body(scene.mesh_path, report)
    if format_version == 2:
        required_vertex = {"x", "y", "z", "nx", "ny", "nz"}
        if not required_vertex.issubset(report["vertex_properties"]):
            raise ValueError("PhoneScene v2 mesh is missing positions or world normals")
        if "classification" not in report["face_properties"]:
            raise ValueError("PhoneScene v2 mesh is missing per-face ARKit classification")
        if scene.mesh_anchor_metadata_path is None:
            raise ValueError("PhoneScene v2 mesh is missing arkit_mesh_anchors.json")
        sidecar = json.loads(scene.mesh_anchor_metadata_path.read_text(encoding="utf-8"))
        if sidecar.get("format") != "phonescene_arkit_mesh_anchors":
            raise ValueError("Invalid ARKit mesh anchor sidecar format")
        if int(sidecar.get("vertex_count", -1)) != report["vertices"]:
            raise ValueError("ARKit mesh anchor sidecar vertex count mismatch")
        if int(sidecar.get("face_count", -1)) != report["faces"]:
            raise ValueError("ARKit mesh anchor sidecar face count mismatch")
        anchors = sidecar.get("anchors")
        if not isinstance(anchors, list) or not anchors:
            raise ValueError("ARKit mesh anchor sidecar contains no anchors")
        expected_vertex_offset = 0
        expected_face_offset = 0
        anchor_ids: set[str] = set()
        for anchor in anchors:
            if not isinstance(anchor, dict):
                raise ValueError("ARKit mesh anchor entry must be an object")
            anchor_id = str(anchor.get("anchor_id", ""))
            if not anchor_id or anchor_id in anchor_ids:
                raise ValueError("ARKit mesh anchor IDs must be non-empty and unique")
            anchor_ids.add(anchor_id)
            transform = np.asarray(anchor.get("transform"), dtype=np.float64)
            if transform.shape != (4, 4) or not np.all(np.isfinite(transform)):
                raise ValueError(f"ARKit mesh anchor {anchor_id} has an invalid transform")
            if not np.allclose(transform[3], [0.0, 0.0, 0.0, 1.0], atol=1e-4):
                raise ValueError(f"ARKit mesh anchor {anchor_id} is not homogeneous")
            if int(anchor.get("vertex_offset", -1)) != expected_vertex_offset:
                raise ValueError("ARKit mesh anchor vertex offsets are not contiguous")
            if int(anchor.get("face_offset", -1)) != expected_face_offset:
                raise ValueError("ARKit mesh anchor face offsets are not contiguous")
            expected_vertex_offset += int(anchor.get("vertex_count", -1))
            expected_face_offset += int(anchor.get("face_count", -1))
        if expected_vertex_offset != report["vertices"] or expected_face_offset != report["faces"]:
            raise ValueError("ARKit mesh anchor ranges do not cover the PLY")
        report["anchor_count"] = len(anchors)
        report["anchor_metadata_path"] = str(scene.mesh_anchor_metadata_path)
    report["path"] = str(scene.mesh_path)
    return report


def validate_phone_scene(root: Path | str) -> dict:
    scene = load_phone_scene(root)
    if not scene.frames:
        raise ValueError(f"No frames in {scene.root}")

    format_version = _validate_capture_metadata(scene.metadata)
    frame_ids = [frame.frame_id for frame in scene.frames]
    if frame_ids != list(range(len(scene.frames))):
        raise ValueError("Frame IDs must be unique, ordered, contiguous, and start at zero")

    missing: list[str] = []
    warnings: list[dict] = []
    if format_version == 2:
        git_commit = str(scene.metadata.get("app", {}).get("git_commit", "")).lower()
        if git_commit in {"development", "unknown"}:
            _warn(
                warnings,
                "non_reproducible_app_build",
                "Capture app provenance does not identify a concrete Git commit.",
                git_commit=git_commit,
            )
    finite_ratios: list[float] = []
    high_confidence_ratios: list[float] = []
    smoothed_finite_ratios: list[float] = []
    pose_steps: list[float] = []
    rotation_steps_deg: list[float] = []
    camera_positions_ros: list[np.ndarray] = []
    tracking_states = Counter()
    previous_translation = None
    previous_rotation = None
    referenced_streams: dict[str, set[Path]] = {
        "rgb": set(),
        "depth": set(),
        "confidence": set(),
        "depth_smoothed": set(),
        "confidence_smoothed": set(),
    }

    for frame in scene.frames:
        frame_missing = False
        for path in (frame.rgb, frame.depth):
            if not path.exists():
                missing.append(str(path))
                frame_missing = True
        if frame.confidence and not frame.confidence.exists():
            missing.append(str(frame.confidence))
            frame_missing = True
        if frame.smoothed_depth and not frame.smoothed_depth.exists():
            missing.append(str(frame.smoothed_depth))
            frame_missing = True
        if frame.smoothed_confidence and not frame.smoothed_confidence.exists():
            missing.append(str(frame.smoothed_confidence))
            frame_missing = True
        if frame_missing:
            continue
        referenced_streams["rgb"].add(frame.rgb.resolve())
        referenced_streams["depth"].add(frame.depth.resolve())
        if frame.confidence:
            referenced_streams["confidence"].add(frame.confidence.resolve())
        if frame.smoothed_depth:
            referenced_streams["depth_smoothed"].add(frame.smoothed_depth.resolve())
        if frame.smoothed_confidence:
            referenced_streams["confidence_smoothed"].add(frame.smoothed_confidence.resolve())
        if format_version == 2 and frame.raw.get("depth_source") != "scene_depth_raw":
            raise ValueError(f"Frame {frame.frame_id} is not backed by raw ARKit scene depth")
        if min(
            frame.image_width,
            frame.image_height,
            frame.depth_width,
            frame.depth_height,
        ) <= 0:
            raise ValueError(f"Frame {frame.frame_id} has non-positive stream dimensions")
        if format_version == 2:
            if not isinstance(frame.raw.get("image_pixel_format"), str):
                raise ValueError(f"Frame {frame.frame_id} has no RGB pixel format provenance")
            if frame.raw.get("depth_pixel_format") != "fdep":
                raise ValueError(f"Frame {frame.frame_id} raw depth is not DepthFloat32")
            if frame.confidence and frame.raw.get("confidence_pixel_format") != "L008":
                raise ValueError(f"Frame {frame.frame_id} confidence is not OneComponent8")
            if frame.smoothed_depth and frame.raw.get("smoothed_depth_pixel_format") != "fdep":
                raise ValueError(f"Frame {frame.frame_id} smoothed depth is not DepthFloat32")
            if (
                frame.smoothed_confidence
                and frame.raw.get("smoothed_confidence_pixel_format") != "L008"
            ):
                raise ValueError(
                    f"Frame {frame.frame_id} smoothed confidence is not OneComponent8"
                )
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
                if np.any(confidence > 2):
                    raise ValueError(f"Confidence values exceed ARKit range in frame {frame.frame_id}")
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
                high_confidence_ratios.append(float(np.mean(confidence == 2)))

        if frame.smoothed_depth:
            smoothed_width = int(frame.raw.get("smoothed_depth_width", frame.depth_width))
            smoothed_height = int(frame.raw.get("smoothed_depth_height", frame.depth_height))
            smoothed = read_depth_f32(frame.smoothed_depth, smoothed_width, smoothed_height)
            smoothed_valid = np.isfinite(smoothed) & (smoothed > 0.05) & (smoothed < 20.0)
            smoothed_finite_ratios.append(float(np.mean(smoothed_valid)))
            if frame.smoothed_confidence:
                smoothed_confidence_width = int(
                    frame.raw.get("smoothed_confidence_width", smoothed_width)
                )
                smoothed_confidence_height = int(
                    frame.raw.get("smoothed_confidence_height", smoothed_height)
                )
                smoothed_confidence = read_confidence_u8(
                    frame.smoothed_confidence,
                    smoothed_confidence_width,
                    smoothed_confidence_height,
                )
                if smoothed_confidence.shape != smoothed.shape:
                    raise ValueError(
                        f"Smoothed confidence/depth size mismatch in frame {frame.frame_id}"
                    )
                if np.any(smoothed_confidence > 2):
                    raise ValueError(
                        f"Smoothed confidence values exceed ARKit range in frame {frame.frame_id}"
                    )

        cam_to_world = arkit_cam_to_world_to_ros_optical(frame.camera_to_world_arkit)
        translation = cam_to_world[:3, 3]
        camera_positions_ros.append(translation)
        if previous_translation is not None:
            pose_steps.append(float(np.linalg.norm(translation - previous_translation)))
        rotation = frame.camera_to_world_arkit[:3, :3]
        if previous_rotation is not None:
            relative = previous_rotation.T @ rotation
            cosine = float(np.clip((np.trace(relative) - 1.0) * 0.5, -1.0, 1.0))
            rotation_steps_deg.append(float(np.degrees(np.arccos(cosine))))
        previous_translation = translation
        previous_rotation = rotation
        tracking_states[frame.tracking_state] += 1

    if missing:
        raise FileNotFoundError("Missing frame files:\n" + "\n".join(missing[:20]))

    for directory, expected in referenced_streams.items():
        _validate_stream_file_set(
            scene.root,
            directory,
            expected,
            format_version=format_version,
        )

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
    if rotation_steps_deg and intervals.size:
        angular_velocity = np.asarray(rotation_steps_deg) / intervals
        maximum_angular_velocity = float(np.max(angular_velocity))
        if maximum_angular_velocity > 120.0:
            _warn(
                warnings,
                "high_angular_velocity",
                "Camera rotation exceeded the recommended capture angular velocity.",
                max_angular_velocity_deg_s=maximum_angular_velocity,
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

    capture_stats = _validate_capture_stats(scene, format_version, len(scene.frames))
    if capture_stats is not None and int(capture_stats.get("dropped_writes", 0)):
        _warn(
            warnings,
            "dropped_writes",
            "Legacy PhoneScene reports dropped frame writes.",
            dropped_writes=int(capture_stats["dropped_writes"]),
        )
    if capture_stats is not None:
        throttled = int(capture_stats.get("throttled_frames", 0))
        if throttled:
            _warn(
                warnings,
                "adaptive_capture_throttling",
                "Capture sampling was reduced to protect lossless frame writes.",
                throttled_frames=throttled,
            )
        raw_unavailable = int(capture_stats.get("raw_depth_unavailable_frames", 0))
        if raw_unavailable:
            _warn(
                warnings,
                "raw_depth_temporarily_unavailable",
                "ARKit raw scene depth was unavailable at scheduled sampling times.",
                frame_opportunities=raw_unavailable,
            )

    sign_bookmarks = _validate_sign_bookmarks(scene, format_version, capture_stats)
    session_events = _validate_session_events(scene, format_version)
    mesh = _validate_mesh(scene, format_version)

    gt_rooms = _validate_gt_room_coverage(
        scene.root,
        np.asarray(camera_positions_ros, dtype=np.float64),
        warnings,
    )

    result = {
        "root": str(scene.root),
        "status": "warning" if warnings else "ok",
        "format_version": format_version,
        "reconstruction_input_ready": True,
        "frames": len(scene.frames),
        "duration_s": float(timestamps[-1] - timestamps[0]) if len(timestamps) > 1 else 0.0,
        "mean_depth_valid_ratio": float(np.mean(finite_ratios)) if finite_ratios else 0.0,
        "min_depth_valid_ratio": float(np.min(finite_ratios)) if finite_ratios else 0.0,
        "mean_high_confidence_ratio": (
            float(np.mean(high_confidence_ratios)) if high_confidence_ratios else 0.0
        ),
        "mean_smoothed_depth_valid_ratio": (
            float(np.mean(smoothed_finite_ratios)) if smoothed_finite_ratios else None
        ),
        "mean_pose_step_m": float(np.mean(pose_steps)) if pose_steps else 0.0,
        "max_pose_step_m": float(np.max(pose_steps)) if pose_steps else 0.0,
        "max_rotation_step_deg": (
            float(np.max(rotation_steps_deg)) if rotation_steps_deg else 0.0
        ),
        "tracking_states": dict(tracking_states),
        "has_arkit_mesh": scene.mesh_path is not None,
        "mesh": mesh,
        "sign_bookmarks": sign_bookmarks,
        "session_events": session_events,
        "warnings": warnings,
    }
    if capture_stats is not None:
        result["capture_stats"] = capture_stats
    if gt_rooms is not None:
        result["gt_rooms"] = gt_rooms
    return result
