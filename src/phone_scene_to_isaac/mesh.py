"""Mesh construction and USD export."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .coordinates import (
    arkit_cam_to_world_to_ros_optical,
    arkit_world_points_to_ros,
    camera_projection,
    invert_transform,
    scale_intrinsics,
    transform_points,
)
from .io import load_phone_scene, read_depth_f32, read_rgb


@dataclass
class MeshData:
    vertices: np.ndarray
    faces: np.ndarray
    colors: np.ndarray | None = None


def read_ascii_ply_mesh(path: Path) -> MeshData:
    """Read the simple ASCII PLY mesh written by the iPhone app."""
    with path.open("r", encoding="utf-8") as stream:
        first = stream.readline().strip()
        if first != "ply":
            raise ValueError(f"Not a PLY file: {path}")
        fmt = stream.readline().strip()
        if fmt != "format ascii 1.0":
            raise ValueError(f"Only ASCII PLY is supported here: {path}")

        vertex_count = 0
        face_count = 0
        vertex_properties: list[str] = []
        section = None
        for line in stream:
            stripped = line.strip()
            if stripped == "end_header":
                break
            parts = stripped.split()
            if not parts:
                continue
            if parts[:2] == ["element", "vertex"]:
                vertex_count = int(parts[2])
                section = "vertex"
            elif parts[:2] == ["element", "face"]:
                face_count = int(parts[2])
                section = "face"
            elif parts[0] == "property" and section == "vertex":
                vertex_properties.append(parts[-1])

        vertices = np.zeros((vertex_count, 3), dtype=np.float64)
        colors = np.zeros((vertex_count, 3), dtype=np.uint8)
        has_color = all(name in vertex_properties for name in ("red", "green", "blue"))
        prop_index = {name: idx for idx, name in enumerate(vertex_properties)}

        for idx in range(vertex_count):
            values = stream.readline().strip().split()
            vertices[idx] = [
                float(values[prop_index["x"]]),
                float(values[prop_index["y"]]),
                float(values[prop_index["z"]]),
            ]
            if has_color:
                colors[idx] = [
                    int(values[prop_index["red"]]),
                    int(values[prop_index["green"]]),
                    int(values[prop_index["blue"]]),
                ]

        faces: list[list[int]] = []
        for _ in range(face_count):
            values = stream.readline().strip().split()
            if not values:
                continue
            count = int(values[0])
            if count != 3:
                continue
            faces.append([int(values[1]), int(values[2]), int(values[3])])

    return MeshData(vertices=vertices, faces=np.asarray(faces, dtype=np.int32), colors=colors if has_color else None)


def colorize_vertices_from_phone_frames(
    scene_root: Path,
    vertices_ros: np.ndarray,
    frame_stride: int = 5,
    max_depth_m: float = 8.0,
    depth_consistency_m: float = 0.25,
) -> np.ndarray:
    """Project mesh vertices into recorded RGB frames and assign nearest-view colors."""
    scene = load_phone_scene(scene_root)
    vertices = np.asarray(vertices_ros, dtype=np.float64)
    best_distance = np.full(vertices.shape[0], np.inf, dtype=np.float64)
    colors = np.full((vertices.shape[0], 3), 180, dtype=np.uint8)

    for frame in scene.frames[:: max(frame_stride, 1)]:
        rgb = read_rgb(frame.rgb)
        depth = read_depth_f32(frame.depth, frame.depth_width, frame.depth_height)
        cam_to_world = arkit_cam_to_world_to_ros_optical(frame.camera_to_world_arkit)
        world_to_cam = invert_transform(cam_to_world)
        points_cam = transform_points(world_to_cam, vertices)
        projected = camera_projection(frame.intrinsics, points_cam)
        u = np.rint(projected[:, 0]).astype(np.int64)
        v = np.rint(projected[:, 1]).astype(np.int64)
        z = projected[:, 2]

        depth_intrinsics = scale_intrinsics(
            frame.intrinsics,
            frame.image_width,
            frame.image_height,
            frame.depth_width,
            frame.depth_height,
        )
        depth_projected = camera_projection(depth_intrinsics, points_cam)
        depth_u = np.rint(depth_projected[:, 0]).astype(np.int64)
        depth_v = np.rint(depth_projected[:, 1]).astype(np.int64)
        in_depth = (
            (depth_u >= 0)
            & (depth_v >= 0)
            & (depth_u < frame.depth_width)
            & (depth_v < frame.depth_height)
        )
        sampled_depth = np.full(vertices.shape[0], np.nan, dtype=np.float64)
        sampled_depth[in_depth] = depth[depth_v[in_depth], depth_u[in_depth]]
        depth_tolerance = np.maximum(depth_consistency_m, 0.05 * np.maximum(z, 0.0))
        depth_consistent = (
            np.isfinite(sampled_depth)
            & (sampled_depth > 0.05)
            & (np.abs(sampled_depth - z) <= depth_tolerance)
        )
        valid = (
            (z > 0.05)
            & (z < max_depth_m)
            & (u >= 0)
            & (v >= 0)
            & (u < frame.image_width)
            & (v < frame.image_height)
            & depth_consistent
            & (z < best_distance)
        )
        if not np.any(valid):
            continue
        colors[valid] = rgb[v[valid], u[valid]]
        best_distance[valid] = z[valid]

    return colors


def build_arkit_mesh_usd(
    scene_root: Path,
    output_usd: Path,
    frame_stride: int = 5,
    max_depth_m: float = 8.0,
) -> MeshData:
    scene = load_phone_scene(scene_root)
    if scene.mesh_path is None:
        raise FileNotFoundError(f"No ARKit mesh found under {scene.root / 'mesh'}")
    mesh = read_ascii_ply_mesh(scene.mesh_path)
    vertices_ros = arkit_world_points_to_ros(mesh.vertices)
    colors = mesh.colors
    if colors is None:
        colors = colorize_vertices_from_phone_frames(scene.root, vertices_ros, frame_stride, max_depth_m)
    result = MeshData(vertices=vertices_ros, faces=mesh.faces, colors=colors)
    write_usda_mesh(output_usd, result)
    return result


def build_depth_triangle_mesh_usd(
    scene_root: Path,
    output_usd: Path,
    frame_stride: int = 5,
    pixel_stride: int = 4,
    max_depth_m: float = 8.0,
    max_triangle_edge_m: float = 0.15,
) -> MeshData:
    scene = load_phone_scene(scene_root)
    all_vertices: list[np.ndarray] = []
    all_faces: list[np.ndarray] = []
    all_colors: list[np.ndarray] = []
    vertex_offset = 0

    for frame in scene.frames[:: max(frame_stride, 1)]:
        depth = read_depth_f32(frame.depth, frame.depth_width, frame.depth_height)
        rgb = read_rgb(frame.rgb)
        intr = scale_intrinsics(
            frame.intrinsics,
            frame.image_width,
            frame.image_height,
            frame.depth_width,
            frame.depth_height,
        )
        ys = np.arange(0, frame.depth_height, max(pixel_stride, 1), dtype=np.int32)
        xs = np.arange(0, frame.depth_width, max(pixel_stride, 1), dtype=np.int32)
        grid_x, grid_y = np.meshgrid(xs, ys)
        z = depth[grid_y, grid_x].astype(np.float64)
        valid = np.isfinite(z) & (z > 0.05) & (z < max_depth_m)

        x_cam = (grid_x.astype(np.float64) - intr[0, 2]) * z / intr[0, 0]
        y_cam = (grid_y.astype(np.float64) - intr[1, 2]) * z / intr[1, 1]
        vertices_cam = np.column_stack((x_cam.reshape(-1), y_cam.reshape(-1), z.reshape(-1)))
        cam_to_world = arkit_cam_to_world_to_ros_optical(frame.camera_to_world_arkit)
        vertices_world = transform_points(cam_to_world, vertices_cam)

        rgb_u = np.clip(
            np.rint(grid_x.astype(np.float64) * frame.image_width / frame.depth_width).astype(np.int64),
            0,
            frame.image_width - 1,
        )
        rgb_v = np.clip(
            np.rint(grid_y.astype(np.float64) * frame.image_height / frame.depth_height).astype(np.int64),
            0,
            frame.image_height - 1,
        )
        colors = rgb[rgb_v.reshape(-1), rgb_u.reshape(-1)]

        local_index = np.arange(vertices_world.shape[0], dtype=np.int32).reshape(grid_x.shape)
        idx00 = local_index[:-1, :-1]
        idx01 = local_index[:-1, 1:]
        idx10 = local_index[1:, :-1]
        idx11 = local_index[1:, 1:]

        p00 = vertices_world[idx00]
        p01 = vertices_world[idx01]
        p10 = vertices_world[idx10]
        p11 = vertices_world[idx11]
        edge_max = np.maximum.reduce(
            [
                np.linalg.norm(p00 - p01, axis=2),
                np.linalg.norm(p00 - p10, axis=2),
                np.linalg.norm(p01 - p11, axis=2),
                np.linalg.norm(p10 - p11, axis=2),
                np.linalg.norm(p01 - p10, axis=2),
            ]
        )
        quad_valid = (
            valid[:-1, :-1]
            & valid[:-1, 1:]
            & valid[1:, :-1]
            & valid[1:, 1:]
            & np.isfinite(edge_max)
            & (edge_max <= max_triangle_edge_m)
        )

        if not np.any(quad_valid):
            continue

        faces_a = np.column_stack(
            (
                idx00[quad_valid].reshape(-1),
                idx01[quad_valid].reshape(-1),
                idx10[quad_valid].reshape(-1),
            )
        )
        faces_b = np.column_stack(
            (
                idx01[quad_valid].reshape(-1),
                idx11[quad_valid].reshape(-1),
                idx10[quad_valid].reshape(-1),
            )
        )
        local_faces = np.vstack((faces_a, faces_b)).astype(np.int32, copy=False)
        used_vertices, inverse = np.unique(local_faces.reshape(-1), return_inverse=True)
        compact_faces = inverse.reshape((-1, 3)).astype(np.int32, copy=False)
        compact_vertices = vertices_world[used_vertices]
        compact_colors = colors[used_vertices]

        all_vertices.append(compact_vertices)
        all_colors.append(compact_colors)
        all_faces.append(compact_faces + vertex_offset)
        vertex_offset += compact_vertices.shape[0]

    if not all_vertices:
        raise ValueError("No valid depth triangles were produced")

    mesh = MeshData(
        vertices=np.vstack(all_vertices),
        faces=np.vstack(all_faces),
        colors=np.vstack(all_colors),
    )
    write_usda_mesh(output_usd, mesh)
    return mesh


def _format_vec3(values: np.ndarray) -> str:
    return f"({values[0]:.6f}, {values[1]:.6f}, {values[2]:.6f})"


def _format_color(values: np.ndarray) -> str:
    color = np.asarray(values, dtype=np.float64) / 255.0
    return f"({color[0]:.5f}, {color[1]:.5f}, {color[2]:.5f})"


def write_usda_mesh(path: Path, mesh: MeshData) -> None:
    """Write an ASCII USD mesh with per-vertex display colors."""
    path = Path(path).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    vertices = np.asarray(mesh.vertices, dtype=np.float64).reshape((-1, 3))
    faces = np.asarray(mesh.faces, dtype=np.int32).reshape((-1, 3))
    colors = mesh.colors
    if colors is None:
        colors = np.full((vertices.shape[0], 3), 180, dtype=np.uint8)
    colors = np.asarray(colors, dtype=np.uint8).reshape((-1, 3))
    if colors.shape[0] != vertices.shape[0]:
        raise ValueError("Color count must match vertex count")

    with path.open("w", encoding="utf-8") as stream:
        stream.write("#usda 1.0\n")
        stream.write("(\n")
        stream.write('    defaultPrim = "World"\n')
        stream.write("    metersPerUnit = 1\n")
        stream.write('    upAxis = "Z"\n')
        stream.write(")\n\n")
        stream.write('def Xform "World"\n{\n')
        stream.write('    def Mesh "SceneMesh"\n    {\n')
        stream.write('        uniform token subdivisionScheme = "none"\n')

        stream.write("        int[] faceVertexCounts = [\n")
        for _ in faces:
            stream.write("            3,\n")
        stream.write("        ]\n")

        stream.write("        int[] faceVertexIndices = [\n")
        flat_faces = faces.reshape(-1)
        for start in range(0, flat_faces.size, 18):
            values = ", ".join(str(int(v)) for v in flat_faces[start : start + 18])
            stream.write(f"            {values},\n")
        stream.write("        ]\n")

        stream.write("        point3f[] points = [\n")
        for vertex in vertices:
            stream.write(f"            {_format_vec3(vertex)},\n")
        stream.write("        ]\n")

        stream.write('        color3f[] primvars:displayColor = [\n')
        for color in colors:
            stream.write(f"            {_format_color(color)},\n")
        stream.write("        ] (\n")
        stream.write('            interpolation = "vertex"\n')
        stream.write("        )\n")
        stream.write("    }\n")
        stream.write("}\n")
