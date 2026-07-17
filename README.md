# SIDAR

SIDAR records metric, provenance-preserving iPhone LiDAR scenes and converts them
into reconstruction inputs for Habitat/Isaac navigation experiments. PhoneScene
v2 treats raw ARKit depth, RGB, the calibrated camera trajectory, mesh semantics,
and operator sign observations as an immutable source dataset.

The pipeline is intentionally metric-first:

1. Record RGB, raw LiDAR depth, optional smoothed depth, ARKit camera poses,
   intrinsics, timestamps, mesh normals/classifications, and anchor provenance.
2. Mark observed signs with a button bound to the exact source frame and pose.
3. Optionally annotate GT room polygons on-device from a top-down projection.
4. Validate every stream and the capture-completion ledger on Linux.
5. Build a colorized metric mesh and export it as USD/USDA.
6. Use that geometry to build collision/navigation assets downstream, or
   optionally re-render trajectories and write a ROS2 compatibility bag.

The `.phonescene` package is not a rosbag and does not constrain an agent to the
recorded phone path. Its geometry can be loaded as a persistent simulator stage;
after downstream collision and navmesh generation, a robot can move under a live
planner/executor while ROOMS maps and segments regions online. The current
`make-isaac-script` command is a deterministic trajectory-rendering utility, not
the interactive navigation layer itself.

## PhoneScene v2 integrity guarantees

- Captures are written to `.phonescene.partial` and become visible as
  `.phonescene` only after all queued writes and final checks succeed.
- `depth/` is always raw `ARFrame.sceneDepth`; temporal smoothing is kept in a
  separate optional stream and is never silently substituted.
- Any dropped/failed frame write, failed bookmark/event write, count mismatch,
  missing expected mesh, or non-contiguous frame ID prevents finalization.
- ARKit mesh normals, per-face classifications, and per-anchor transforms/ranges
  are preserved.
- `phone-scene validate` rejects incomplete, path-traversing, or internally
  inconsistent packages before reconstruction or upload acceptance.

## Optional ROS2 compatibility contract

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

Linux can validate and convert captures. Xcode is required to build the iOS app;
Isaac Sim is required for Isaac rendering or downstream simulator asset work.

## Quick Start

Install Python tooling:

```bash
cd /home/siny/Repos/SIDAR
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
Build to a LiDAR-capable iPhone. The installed app is displayed as **SIDAR**.
During recording, use **Mark Sign** for a fast unreviewed observation or
**Typed Mark** for directional, locational, or directory signs. After stopping,
wait for finalization; an integrity failure remains a recoverable
`.phonescene.partial` directory and is never presented as complete. SIDAR writes
finished `.phonescene` directories into the app Documents folder. Then tap
**Review / Annotate Rooms** to
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

For off-site uploads through a public VPS while storing all data on the Ubuntu
workstation, use the WireGuard + Nginx streaming relay described in
[docs/VPS_UPLOAD_RELAY.md](docs/VPS_UPLOAD_RELAY.md). In that setup the iPhone
uploads to `http://45.32.115.105:8765`, the VPS proxies the stream over
WireGuard, and the workstation receiver writes scenes to `/data/sidar/scenes`.

See [docs/PHONE_SCENE_FORMAT.md](docs/PHONE_SCENE_FORMAT.md) and
[docs/WORKFLOW.md](docs/WORKFLOW.md).
