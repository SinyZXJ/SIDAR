"""Command line interface."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

from .isaac import make_isaac_script
from .mesh import build_arkit_mesh_usd, build_depth_triangle_mesh_usd
from .receiver import serve_receiver
from .rosbag_writer import write_mp3d_bag
from .validation import validate_phone_scene


def _print_json(payload: dict) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def cmd_validate(args: argparse.Namespace) -> int:
    report = validate_phone_scene(args.scene)
    _print_json(report)
    if args.strict and report.get("warnings"):
        return 2
    return 0


def cmd_build_mesh(args: argparse.Namespace) -> int:
    if args.mode == "arkit-mesh":
        mesh = build_arkit_mesh_usd(
            args.scene,
            args.output,
            frame_stride=args.frame_stride,
            max_depth_m=args.max_depth_m,
        )
    elif args.mode == "depth-triangles":
        mesh = build_depth_triangle_mesh_usd(
            args.scene,
            args.output,
            frame_stride=args.frame_stride,
            pixel_stride=args.pixel_stride,
            max_depth_m=args.max_depth_m,
            max_triangle_edge_m=args.max_triangle_edge_m,
        )
    else:
        raise ValueError(args.mode)
    _print_json(
        {
            "output": str(Path(args.output).expanduser().resolve()),
            "vertices": int(mesh.vertices.shape[0]),
            "faces": int(mesh.faces.shape[0]),
            "has_colors": mesh.colors is not None,
        }
    )
    return 0


def cmd_make_isaac_script(args: argparse.Namespace) -> int:
    script = make_isaac_script(
        args.scene,
        args.scene_usd,
        args.script,
        args.output_dir,
        width=args.width,
        height=args.height,
        frame_stride=args.frame_stride,
        max_depth_m=args.max_depth_m,
        headless=not args.window,
    )
    _print_json({"script": str(script), "config": str(script.with_suffix(".json"))})
    return 0


def cmd_render_to_bag(args: argparse.Namespace) -> int:
    bag = write_mp3d_bag(
        args.render_dir,
        args.output_bag,
        dummy_semantic_label=args.dummy_semantic_label,
        world_frame=args.world_frame,
        robot_frame=args.robot_frame,
        camera_frame=args.camera_frame,
    )
    _print_json({"bag": str(bag)})
    return 0


def cmd_make_demo_render(args: argparse.Namespace) -> int:
    """Create a tiny render package for local bag-writer sanity checks."""
    root = Path(args.output_dir).expanduser().resolve()
    (root / "rgb").mkdir(parents=True, exist_ok=True)
    (root / "depth").mkdir(parents=True, exist_ok=True)
    width = int(args.width)
    height = int(args.height)
    fx = fy = float(width)
    cx = (width - 1) * 0.5
    cy = (height - 1) * 0.5
    intrinsics = [[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]]

    manifest = []
    for idx in range(int(args.frames)):
        rgb = np.zeros((height, width, 3), dtype=np.uint8)
        rgb[:, :, 0] = np.linspace(0, 255, width, dtype=np.uint8)[None, :]
        rgb[:, :, 1] = np.linspace(0, 255, height, dtype=np.uint8)[:, None]
        rgb[:, :, 2] = np.uint8(40 + idx * 20)
        depth = np.full((height, width), 2.0 + 0.1 * idx, dtype=np.float32)
        pose = np.eye(4, dtype=np.float64)
        pose[0, 3] = 0.1 * idx

        stem = f"{idx:06d}"
        Image.fromarray(rgb).save(root / "rgb" / f"{stem}.png")
        np.save(root / "depth" / f"{stem}.npy", depth)
        manifest.append(
            {
                "frame_id": idx,
                "timestamp": float(idx) / float(args.fps),
                "rgb": f"rgb/{stem}.png",
                "depth": f"depth/{stem}.npy",
                "width": width,
                "height": height,
                "intrinsics": intrinsics,
                "camera_to_world_ros": pose.tolist(),
            }
        )

    (root / "metadata.json").write_text(
        json.dumps({"format": "phone_isaac_render", "format_version": 1}, indent=2) + "\n",
        encoding="utf-8",
    )
    with (root / "manifest.jsonl").open("w", encoding="utf-8") as stream:
        for entry in manifest:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")
    _print_json({"render_dir": str(root), "frames": len(manifest)})
    return 0


def cmd_receive(args: argparse.Namespace) -> int:
    serve_receiver(
        args.output_dir,
        host=args.host,
        port=args.port,
        token=args.token,
        validate=args.validate,
        overwrite=args.overwrite,
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="phone-scene")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="Validate a .phonescene package")
    validate.add_argument("scene", type=Path)
    validate.add_argument(
        "--strict",
        action="store_true",
        help="Return a non-zero exit code when quality warnings are present",
    )
    validate.set_defaults(func=cmd_validate)

    build_mesh = sub.add_parser("build-mesh", help="Build a USD mesh from phone data")
    build_mesh.add_argument("scene", type=Path)
    build_mesh.add_argument("output", type=Path)
    build_mesh.add_argument("--mode", choices=["arkit-mesh", "depth-triangles"], default="arkit-mesh")
    build_mesh.add_argument("--frame-stride", type=int, default=5)
    build_mesh.add_argument("--pixel-stride", type=int, default=4)
    build_mesh.add_argument("--max-depth-m", type=float, default=8.0)
    build_mesh.add_argument("--max-triangle-edge-m", type=float, default=0.15)
    build_mesh.set_defaults(func=cmd_build_mesh)

    make_script = sub.add_parser("make-isaac-script", help="Generate an Isaac Sim render script")
    make_script.add_argument("scene", type=Path)
    make_script.add_argument("scene_usd", type=Path)
    make_script.add_argument("script", type=Path)
    make_script.add_argument("--output-dir", type=Path, required=True)
    make_script.add_argument("--width", type=int, default=1280)
    make_script.add_argument("--height", type=int, default=720)
    make_script.add_argument("--frame-stride", type=int, default=1)
    make_script.add_argument("--max-depth-m", type=float, default=8.0)
    make_script.add_argument("--window", action="store_true", help="Run Isaac with a visible window")
    make_script.set_defaults(func=cmd_make_isaac_script)

    render_to_bag = sub.add_parser("render-to-bag", help="Write a render package to ROS2 bag")
    render_to_bag.add_argument("render_dir", type=Path)
    render_to_bag.add_argument("output_bag", type=Path)
    render_to_bag.add_argument("--dummy-semantic-label", type=int, default=25)
    render_to_bag.add_argument("--world-frame", default="world")
    render_to_bag.add_argument("--robot-frame", default="base_link_gt")
    render_to_bag.add_argument("--camera-frame", default="left_cam")
    render_to_bag.set_defaults(func=cmd_render_to_bag)

    demo = sub.add_parser("make-demo-render", help="Create a tiny local render package")
    demo.add_argument("output_dir", type=Path)
    demo.add_argument("--frames", type=int, default=3)
    demo.add_argument("--width", type=int, default=64)
    demo.add_argument("--height", type=int, default=48)
    demo.add_argument("--fps", type=float, default=10.0)
    demo.set_defaults(func=cmd_make_demo_render)

    receive = sub.add_parser("receive", help="Run a local HTTP receiver for SIDAR iPhone uploads")
    receive.add_argument("--output-dir", type=Path, default=Path("received_scenes"))
    receive.add_argument("--host", default="0.0.0.0")
    receive.add_argument("--port", type=int, default=8765)
    receive.add_argument("--token", default=None, help="Optional shared token required from the app")
    receive.add_argument("--validate", action="store_true", help="Validate each scene before accepting it")
    receive.add_argument("--overwrite", action="store_true", help="Replace an existing scene with the same name")
    receive.set_defaults(func=cmd_receive)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
