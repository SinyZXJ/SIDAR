"""Coordinate conversions between ARKit, ROS optical, and USD camera frames."""

from __future__ import annotations

import numpy as np
from scipy.spatial.transform import Rotation


ARKIT_WORLD_TO_ROS_WORLD = np.array(
    [
        [0.0, 0.0, -1.0, 0.0],
        [-1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ],
    dtype=np.float64,
)

# ARKit camera coordinates are converted to ROS optical coordinates
# (x right, y down, z forward) by flipping camera Y and Z.
ROS_OPTICAL_TO_ARKIT_CAMERA = np.diag([1.0, -1.0, -1.0, 1.0]).astype(np.float64)

# USD/OpenUSD camera coordinates also use x right, y up, -z forward.
ROS_OPTICAL_TO_USD_CAMERA = np.diag([1.0, -1.0, -1.0, 1.0]).astype(np.float64)


def arkit_cam_to_world_to_ros_optical(cam_to_world_arkit: np.ndarray) -> np.ndarray:
    """Return ROS-world transform of the ROS optical camera frame."""
    cam_to_world_arkit = np.asarray(cam_to_world_arkit, dtype=np.float64).reshape(4, 4)
    return ARKIT_WORLD_TO_ROS_WORLD @ cam_to_world_arkit @ ROS_OPTICAL_TO_ARKIT_CAMERA


def arkit_world_points_to_ros(points: np.ndarray) -> np.ndarray:
    points = np.asarray(points, dtype=np.float64)
    rot = ARKIT_WORLD_TO_ROS_WORLD[:3, :3]
    return points @ rot.T


def ros_optical_to_usd_camera_pose(camera_to_world_ros: np.ndarray) -> np.ndarray:
    """Convert a ROS optical camera pose to a USD camera pose."""
    camera_to_world_ros = np.asarray(camera_to_world_ros, dtype=np.float64).reshape(4, 4)
    return camera_to_world_ros @ ROS_OPTICAL_TO_USD_CAMERA


def transform_points(transform: np.ndarray, points: np.ndarray) -> np.ndarray:
    points = np.asarray(points, dtype=np.float64)
    ones = np.ones((points.shape[0], 1), dtype=np.float64)
    homog = np.hstack((points, ones))
    return (np.asarray(transform, dtype=np.float64).reshape(4, 4) @ homog.T).T[:, :3]


def camera_projection(intrinsics: np.ndarray, points_camera: np.ndarray) -> np.ndarray:
    intrinsics = np.asarray(intrinsics, dtype=np.float64).reshape(3, 3)
    points_camera = np.asarray(points_camera, dtype=np.float64)
    z = points_camera[:, 2]
    safe_z = np.where(np.abs(z) > 1e-9, z, 1e-9)
    u = intrinsics[0, 0] * points_camera[:, 0] / safe_z + intrinsics[0, 2]
    v = intrinsics[1, 1] * points_camera[:, 1] / safe_z + intrinsics[1, 2]
    return np.column_stack((u, v, z))


def invert_transform(transform: np.ndarray) -> np.ndarray:
    transform = np.asarray(transform, dtype=np.float64).reshape(4, 4)
    inv = np.eye(4, dtype=np.float64)
    rotation = transform[:3, :3]
    inv[:3, :3] = rotation.T
    inv[:3, 3] = -rotation.T @ transform[:3, 3]
    return inv


def matrix_to_translation_quaternion(transform: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    transform = np.asarray(transform, dtype=np.float64).reshape(4, 4)
    translation = transform[:3, 3].copy()
    quat_xyzw = Rotation.from_matrix(transform[:3, :3]).as_quat()
    return translation, quat_xyzw


def scale_intrinsics(
    intrinsics: np.ndarray,
    source_width: int,
    source_height: int,
    target_width: int,
    target_height: int,
) -> np.ndarray:
    scaled = np.asarray(intrinsics, dtype=np.float64).reshape(3, 3).copy()
    sx = float(target_width) / float(source_width)
    sy = float(target_height) / float(source_height)
    scaled[0, 0] *= sx
    scaled[0, 2] *= sx
    scaled[1, 1] *= sy
    scaled[1, 2] *= sy
    return scaled
