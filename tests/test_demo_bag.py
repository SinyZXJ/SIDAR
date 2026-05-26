from pathlib import Path

from rosbags.highlevel import AnyReader

from phone_scene_to_isaac.cli import cmd_make_demo_render
from phone_scene_to_isaac.rosbag_writer import write_mp3d_bag


class Args:
    pass


def test_demo_render_to_bag(tmp_path: Path) -> None:
    args = Args()
    args.output_dir = tmp_path / "renders"
    args.frames = 2
    args.width = 32
    args.height = 24
    args.fps = 10.0
    cmd_make_demo_render(args)

    bag = write_mp3d_bag(tmp_path / "renders", tmp_path / "rosbag2")
    with AnyReader([bag]) as reader:
        counts = {conn.topic: conn.msgcount for conn in reader.connections}

    assert counts["/tesse/left_cam/rgb/image_raw"] == 2
    assert counts["/tesse/depth_cam/mono/image_raw"] == 2
    assert counts["/tesse/left_cam/camera_info"] == 2
    assert counts["/tesse/seg_cam/converted/image_raw"] == 2
    assert counts["/tf"] == 2
    assert counts["/tf_static"] == 1
