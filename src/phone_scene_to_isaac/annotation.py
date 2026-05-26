"""Small geometry helpers for phone-side room annotation checks."""

from __future__ import annotations

from collections.abc import Sequence

Point2D = Sequence[float]


def polygon_area_xy(points: Sequence[Point2D]) -> float:
    if len(points) < 3:
        return 0.0
    total = 0.0
    for idx, point in enumerate(points):
        nxt = points[(idx + 1) % len(points)]
        total += float(point[0]) * float(nxt[1]) - float(nxt[0]) * float(point[1])
    return abs(total) * 0.5


def polygon_self_intersects(points: Sequence[Point2D]) -> bool:
    if len(points) < 4:
        return False
    for first_idx in range(len(points)):
        first_next = (first_idx + 1) % len(points)
        for second_idx in range(first_idx + 1, len(points)):
            second_next = (second_idx + 1) % len(points)
            if first_idx == second_idx or first_next == second_idx or second_next == first_idx:
                continue
            if first_idx == 0 and second_next == 0:
                continue
            if _segments_intersect(
                points[first_idx],
                points[first_next],
                points[second_idx],
                points[second_next],
            ):
                return True
    return False


def _segments_intersect(a: Point2D, b: Point2D, c: Point2D, d: Point2D) -> bool:
    o1 = _orientation(a, b, c)
    o2 = _orientation(a, b, d)
    o3 = _orientation(c, d, a)
    o4 = _orientation(c, d, b)

    if o1 == 0 and _point_on_segment(c, a, b):
        return True
    if o2 == 0 and _point_on_segment(d, a, b):
        return True
    if o3 == 0 and _point_on_segment(a, c, d):
        return True
    if o4 == 0 and _point_on_segment(b, c, d):
        return True
    return o1 != o2 and o3 != o4


def _orientation(a: Point2D, b: Point2D, c: Point2D) -> int:
    value = (float(b[1]) - float(a[1])) * (float(c[0]) - float(b[0])) - (
        float(b[0]) - float(a[0])
    ) * (float(c[1]) - float(b[1]))
    if abs(value) < 1e-9:
        return 0
    return 1 if value > 0 else 2


def _point_on_segment(point: Point2D, a: Point2D, b: Point2D) -> bool:
    px, py = float(point[0]), float(point[1])
    ax, ay = float(a[0]), float(a[1])
    bx, by = float(b[0]), float(b[1])
    return (
        px <= max(ax, bx) + 1e-9
        and px + 1e-9 >= min(ax, bx)
        and py <= max(ay, by) + 1e-9
        and py + 1e-9 >= min(ay, by)
    )
