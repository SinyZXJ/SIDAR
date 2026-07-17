from __future__ import annotations

from pathlib import Path

import numpy as np

from phone_scene_to_isaac.mesh import build_depth_triangle_mesh_usd, read_ascii_ply_mesh

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


def test_mesh_reader_accepts_v2_normals_and_face_classification(tmp_path: Path) -> None:
    path = tmp_path / "semantic_mesh.ply"
    path.write_text(
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
                "3 0 1 2 2",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    mesh = read_ascii_ply_mesh(path)

    assert mesh.vertices.shape == (3, 3)
    assert mesh.faces.tolist() == [[0, 1, 2]]
