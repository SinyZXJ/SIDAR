import numpy as np

from phone_scene_to_isaac.annotation import polygon_area_xy, polygon_self_intersects
from phone_scene_to_isaac.coordinates import arkit_world_points_to_ros


def test_arkit_world_to_ros_xy_contract() -> None:
    points_arkit = np.array([[1.0, 2.0, 3.0], [-4.0, 0.5, -6.0]])

    points_ros = arkit_world_points_to_ros(points_arkit)

    np.testing.assert_allclose(points_ros[:, :2], [[-3.0, -1.0], [6.0, 4.0]])
    np.testing.assert_allclose(points_ros[:, 2], [2.0, 0.5])


def test_polygon_area_xy() -> None:
    polygon = [[0.0, 0.0], [2.0, 0.0], [2.0, 1.5], [0.0, 1.5]]

    assert polygon_area_xy(polygon) == 3.0


def test_polygon_self_intersection() -> None:
    simple = [[0.0, 0.0], [2.0, 0.0], [2.0, 1.0], [0.0, 1.0]]
    bow_tie = [[0.0, 0.0], [2.0, 2.0], [0.0, 2.0], [2.0, 0.0]]

    assert not polygon_self_intersects(simple)
    assert polygon_self_intersects(bow_tie)
