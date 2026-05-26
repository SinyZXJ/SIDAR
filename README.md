# PhoneSceneToIsaac

PhoneSceneToIsaac is a standalone pipeline for turning an iPhone 15 Pro LiDAR scan
into an Isaac Sim scene and then rendering an MP3D-compatible ROS2 bag for
VRS-Hydra room-segmentation experiments.

The pipeline is intentionally metric-first:

1. Record RGB, LiDAR depth, ARKit camera poses, intrinsics, timestamps, and an
   optional ARKit mesh on iPhone.
2. Optionally annotate GT room polygons on-device from a top-down projection.
3. Validate the exported `.phonescene` package on Linux.
4. Build a colorized metric mesh and export it as USD/USDA.
5. Render RGB-D and camera poses in Isaac Sim.
6. Write a ROS2 bag that matches the existing MP3D workflow topics.

## Output ROS2 Topic Contract

Generated bags use these topics:

```text
/tesse/left_cam/rgb/image_raw
/tesse/left_cam/camera_info
/tesse/depth_cam/mono/image_raw
/tesse/seg_cam/converted/image_raw
/tf
/tf_static
```

TF uses:

```text
world -> base_link_gt
base_link_gt -> left_cam
```

For phone-only data, `base_link_gt -> left_cam` is identity and
`world -> base_link_gt` is the rendered camera pose.

## Local Capabilities

This repository contains:

- `ios/PhoneSceneCapture`: Swift/ARKit source for the iPhone recording app.
- `src/phone_scene_to_isaac`: Python tools for validation, mesh export, Isaac
  script generation, and ROS2 bag writing.
- `scripts`: shell entrypoints for the common workflow.
- `configs`: default capture and rendering settings.

The current Linux workstation can validate Python tooling and write ROS2 bags.
It does not have Xcode or Isaac Sim installed, so iPhone build and Isaac rendering
must be run on machines with those tools.

## Quick Start

Install Python tooling:

```bash
cd /home/siny/Repos/PhoneSceneToIsaac
python3 -m pip install -e .
```

Validate a phone capture:

```bash
phone-scene validate data/scenes/office_001.phonescene
```

Build a colorized mesh from the ARKit mesh if available:

```bash
phone-scene build-mesh \
  data/scenes/office_001.phonescene \
  outputs/office_001/scene.usda \
  --mode arkit-mesh
```

If ARKit mesh is not available, build a depth-triangle mesh:

```bash
phone-scene build-mesh \
  data/scenes/office_001.phonescene \
  outputs/office_001/scene.usda \
  --mode depth-triangles \
  --frame-stride 5 \
  --pixel-stride 4
```

Generate an Isaac Sim rendering script:

```bash
phone-scene make-isaac-script \
  data/scenes/office_001.phonescene \
  outputs/office_001/scene.usda \
  outputs/office_001/render_job.py \
  --output-dir outputs/office_001/renders
```

Run the generated script inside Isaac Sim:

```bash
isaacsim --no-window --python outputs/office_001/render_job.py
```

Convert the rendered frames to an MP3D-compatible ROS2 bag:

```bash
phone-scene render-to-bag \
  outputs/office_001/renders \
  outputs/office_001/rosbag2
```

## iPhone Recording App

Open `ios/PhoneSceneCapture/PhoneSceneCapture.xcodeproj` on macOS with Xcode.
Build to an iPhone 15 Pro. The installed app is displayed as **SIDAR** and writes `.phonescene` directories into the app
Documents folder. After stopping a recording, tap **Review / Annotate Rooms** to
draw evaluator-compatible room GT on the phone. The app writes optional
`annotation/topdown_map.png`, `annotation/annotation_payload.json`, and
`annotation/gt_rooms.json` files inside the `.phonescene` directory. Retrieve
captures through Finder device file sharing or the Files app.
For stairs and multi-level captures, the annotation payload stores full
ROS-world `trajectory_xyz` and inferred floor z bands so room coverage is
validated in both XY and height.

To receive scenes directly from the phone over the local network, run this on
the workstation:

```bash
phone-scene receive \
  --output-dir /data/sidar/scenes \
  --host 0.0.0.0 \
  --port 8765 \
  --token YOUR_TOKEN \
  --validate
```

Then open **Gallery -> Upload Settings** in SIDAR, enter
`http://WORKSTATION_IP:8765` and the same token, and use **Upload** on any
recorded scene.

See [docs/PHONE_SCENE_FORMAT.md](docs/PHONE_SCENE_FORMAT.md) and
[docs/WORKFLOW.md](docs/WORKFLOW.md).
