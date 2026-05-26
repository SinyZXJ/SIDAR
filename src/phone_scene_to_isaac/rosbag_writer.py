"""Write Isaac render packages as MP3D-compatible ROS2 bags."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from rosbags.rosbag2 import Writer
from rosbags.typesys import Stores, get_typestore

from .coordinates import matrix_to_translation_quaternion
from .io import load_render_package, read_render_depth, read_rgb


def _default_ros2_store():
    """Pick the newest compatible ROS2 typestore available in installed rosbags."""
    for name in ("ROS2_JAZZY", "ROS2_IRON", "ROS2_HUMBLE", "LATEST"):
        store = getattr(Stores, name, None)
        if store is not None:
            return store
    raise RuntimeError("Installed rosbags package does not provide a ROS2 typestore")


def _writer(path: Path):
    try:
        return Writer(path, version=9)
    except TypeError:
        return Writer(path)


def _time_msg(store, seconds: float):
    Time = store.types["builtin_interfaces/msg/Time"]
    sec = int(np.floor(seconds))
    nanosec = int(round((seconds - sec) * 1.0e9))
    if nanosec >= 1_000_000_000:
        sec += 1
        nanosec -= 1_000_000_000
    return Time(sec=sec, nanosec=nanosec)


def _header(store, seconds: float, frame_id: str):
    Header = store.types["std_msgs/msg/Header"]
    return Header(stamp=_time_msg(store, seconds), frame_id=frame_id)


def _image_msg(store, seconds: float, frame_id: str, image: np.ndarray, encoding: str):
    Image = store.types["sensor_msgs/msg/Image"]
    if encoding == "rgb8":
        data = np.asarray(image, dtype=np.uint8)
        height, width = data.shape[:2]
        step = width * 3
        payload = data.reshape(-1)
    elif encoding == "32FC1":
        data = np.asarray(image, dtype="<f4")
        height, width = data.shape[:2]
        step = width * 4
        payload = data.view(np.uint8).reshape(-1)
    elif encoding == "mono16":
        data = np.asarray(image, dtype="<u2")
        height, width = data.shape[:2]
        step = width * 2
        payload = data.view(np.uint8).reshape(-1)
    else:
        raise ValueError(f"Unsupported image encoding: {encoding}")

    return Image(
        header=_header(store, seconds, frame_id),
        height=int(height),
        width=int(width),
        encoding=encoding,
        is_bigendian=0,
        step=int(step),
        data=np.asarray(payload, dtype=np.uint8),
    )


def _camera_info_msg(store, seconds: float, frame_id: str, width: int, height: int, intrinsics: np.ndarray):
    CameraInfo = store.types["sensor_msgs/msg/CameraInfo"]
    Roi = store.types["sensor_msgs/msg/RegionOfInterest"]
    k = np.asarray(intrinsics, dtype=np.float64).reshape(3, 3)
    projection = np.array(
        [
            k[0, 0],
            0.0,
            k[0, 2],
            0.0,
            0.0,
            k[1, 1],
            k[1, 2],
            0.0,
            0.0,
            0.0,
            1.0,
            0.0,
        ],
        dtype=np.float64,
    )
    return CameraInfo(
        header=_header(store, seconds, frame_id),
        height=int(height),
        width=int(width),
        distortion_model="plumb_bob",
        d=np.asarray([], dtype=np.float64),
        k=k.reshape(-1),
        r=np.eye(3, dtype=np.float64).reshape(-1),
        p=projection,
        binning_x=0,
        binning_y=0,
        roi=Roi(x_offset=0, y_offset=0, height=0, width=0, do_rectify=False),
    )


def _transform_msg(
    store,
    seconds: float,
    parent: str,
    child: str,
    transform: np.ndarray,
):
    TransformStamped = store.types["geometry_msgs/msg/TransformStamped"]
    Transform = store.types["geometry_msgs/msg/Transform"]
    Vector3 = store.types["geometry_msgs/msg/Vector3"]
    Quaternion = store.types["geometry_msgs/msg/Quaternion"]
    translation, quat_xyzw = matrix_to_translation_quaternion(transform)
    return TransformStamped(
        header=_header(store, seconds, parent),
        child_frame_id=child,
        transform=Transform(
            translation=Vector3(
                x=float(translation[0]),
                y=float(translation[1]),
                z=float(translation[2]),
            ),
            rotation=Quaternion(
                x=float(quat_xyzw[0]),
                y=float(quat_xyzw[1]),
                z=float(quat_xyzw[2]),
                w=float(quat_xyzw[3]),
            ),
        ),
    )


def write_mp3d_bag(
    render_root: Path | str,
    output_bag: Path | str,
    dummy_semantic_label: int = 25,
    world_frame: str = "world",
    robot_frame: str = "base_link_gt",
    camera_frame: str = "left_cam",
) -> Path:
    frames = load_render_package(render_root)
    if not frames:
        raise ValueError("Render package has no frames")

    output_bag = Path(output_bag).expanduser().resolve()
    if output_bag.exists():
        raise FileExistsError(f"Output bag already exists: {output_bag}")
    output_bag.parent.mkdir(parents=True, exist_ok=True)

    store = get_typestore(_default_ros2_store())
    TfMessage = store.types["tf2_msgs/msg/TFMessage"]

    rgb_topic = "/tesse/left_cam/rgb/image_raw"
    info_topic = "/tesse/left_cam/camera_info"
    depth_topic = "/tesse/depth_cam/mono/image_raw"
    semantic_topic = "/tesse/seg_cam/converted/image_raw"
    tf_topic = "/tf"
    tf_static_topic = "/tf_static"

    with _writer(output_bag) as writer:
        rgb_conn = writer.add_connection(rgb_topic, "sensor_msgs/msg/Image", typestore=store)
        info_conn = writer.add_connection(info_topic, "sensor_msgs/msg/CameraInfo", typestore=store)
        depth_conn = writer.add_connection(depth_topic, "sensor_msgs/msg/Image", typestore=store)
        semantic_conn = writer.add_connection(semantic_topic, "sensor_msgs/msg/Image", typestore=store)
        tf_conn = writer.add_connection(tf_topic, "tf2_msgs/msg/TFMessage", typestore=store)
        tf_static_conn = writer.add_connection(tf_static_topic, "tf2_msgs/msg/TFMessage", typestore=store)

        first_stamp = frames[0].timestamp
        identity = np.eye(4, dtype=np.float64)
        static_tf = TfMessage(
            transforms=[
                _transform_msg(
                    store,
                    first_stamp,
                    robot_frame,
                    camera_frame,
                    identity,
                )
            ]
        )
        writer.write(
            tf_static_conn,
            int(first_stamp * 1.0e9),
            store.serialize_cdr(static_tf, "tf2_msgs/msg/TFMessage"),
        )

        for frame in frames:
            stamp_ns = int(frame.timestamp * 1.0e9)
            rgb = read_rgb(frame.rgb)
            depth = read_render_depth(frame.depth)
            if depth.shape != (frame.height, frame.width):
                raise ValueError(f"Depth shape mismatch for frame {frame.frame_id}: {depth.shape}")
            semantic = np.full(
                (frame.height, frame.width),
                int(dummy_semantic_label),
                dtype=np.uint16,
            )

            tf_msg = TfMessage(
                transforms=[
                    _transform_msg(
                        store,
                        frame.timestamp,
                        world_frame,
                        robot_frame,
                        frame.camera_to_world_ros,
                    )
                ]
            )
            messages = [
                (tf_conn, "tf2_msgs/msg/TFMessage", tf_msg),
                (rgb_conn, "sensor_msgs/msg/Image", _image_msg(store, frame.timestamp, camera_frame, rgb, "rgb8")),
                (
                    info_conn,
                    "sensor_msgs/msg/CameraInfo",
                    _camera_info_msg(
                        store,
                        frame.timestamp,
                        camera_frame,
                        frame.width,
                        frame.height,
                        frame.intrinsics,
                    ),
                ),
                (
                    depth_conn,
                    "sensor_msgs/msg/Image",
                    _image_msg(store, frame.timestamp, camera_frame, depth, "32FC1"),
                ),
                (
                    semantic_conn,
                    "sensor_msgs/msg/Image",
                    _image_msg(store, frame.timestamp, camera_frame, semantic, "mono16"),
                ),
            ]
            for conn, msgtype, msg in messages:
                writer.write(conn, stamp_ns, store.serialize_cdr(msg, msgtype))

    return output_bag
