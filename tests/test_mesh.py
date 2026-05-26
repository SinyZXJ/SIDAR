from __future__ import annotations

from pathlib import Path

import numpy as np

from phone_scene_to_isaac.mesh import build_depth_triangle_mesh_usd

from scene_fixtures import write_phone_scene


def test_depth_triangle_mesh_compacts_invalid_vertices(tmp_path: Path) -> None:
    depth = np.ones((4, 4), dtype=np.float32)
    depth[0, 0] = np.nan
    scene = write_phone_scene(tmp_path / "scene.phonescene", depth=depth)

    mesh = build_depth_triangle_mesh_usd(
        scene,
        tmp_path / "scene.usda",
        frame_stride=1,
        pixel_stride=1,
        max_triangle_edge_m=10.0,
    )

    assert mesh.faces.shape[0] > 0
    assert mesh.vertices.shape[0] < depth.size
    assert np.isfinite(mesh.vertices).all()
