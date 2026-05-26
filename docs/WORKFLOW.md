# End-to-End Workflow

## 1. Record on iPhone

1. Build `ios/PhoneSceneCapture` in Xcode.
2. Install to iPhone 15 Pro.
3. Start AR session and wait for tracking state `normal`.
4. Press Record.
5. Walk every room deliberately. Enter each room and rotate in place.
6. Stop recording and wait until mesh export finishes.
7. Optionally tap **Review / Annotate Rooms**. The app opens a top-down
   projection built from recorded mesh/depth/trajectory only. Draw one polygon
   per room, choose labels, and save GT. For stairs or multi-level scenes,
   switch the floor selector before drawing rooms on a different level; the app
   infers floor z bands from the recorded camera trajectory and lets you adjust
   each floor's `min_z` / `max_z` before saving.
8. Copy the `.phonescene` directory from the app Documents folder.

Recommended capture style:

- Keep the phone in landscape orientation.
- Move at walking speed.
- Maintain 60% or more visual overlap between nearby viewpoints.
- Revisit doorways and room boundaries.
- Avoid fast yaw motion and long blank-wall-only segments.

Phone-side annotation writes:

```text
annotation/topdown_map.png
annotation/annotation_payload.json
annotation/gt_rooms.json
```

The `gt_rooms.json` file uses `frame: "world"` and ROS-world `polygon_xy`, so it
can be passed to VRS-Hydra real-scene evaluation alongside the generated bag.
Each room also carries a z band. The phone and Linux validators report
trajectory-frame coverage per room using both `polygon_xy` and that z band; low
coverage is a warning, not a hard failure, so experiments can continue while the
scene is flagged for review.
The regular `phone-scene validate` command still validates the base capture and
does not require annotation files.

## 1.1 Upload Directly To A Workstation

Instead of copying scenes through Finder, run a receiver on the workstation:

```bash
phone-scene receive \
  --output-dir /data/sidar/scenes \
  --host 0.0.0.0 \
  --port 8765 \
  --token YOUR_TOKEN \
  --validate
```

In the iPhone app, open **Gallery -> Upload Settings**, enter
`http://WORKSTATION_IP:8765` and the same token, then use **Upload** from each
scene's menu. Uploads are sent file-by-file into a temporary directory and are
moved into `--output-dir` only after the final request succeeds. If a scene with
the same name already exists, the receiver keeps both by adding a numeric suffix
unless `--overwrite` is passed.

## 2. Validate

```bash
phone-scene validate data/scenes/office_001.phonescene
```

The validator checks:

- RGB/depth/confidence file existence.
- Depth dimensions and finite metric depth ratio.
- Intrinsics shape.
- Pose continuity.
- Tracking-state summary.

## 3. Build USD Scene

Prefer ARKit mesh when available:

```bash
phone-scene build-mesh data/scenes/office_001.phonescene outputs/office_001/scene.usda
```

Fallback to depth triangles:

```bash
phone-scene build-mesh \
  data/scenes/office_001.phonescene \
  outputs/office_001/scene.usda \
  --mode depth-triangles \
  --frame-stride 5 \
  --pixel-stride 4
```

## 4. Render in Isaac Sim

```bash
phone-scene make-isaac-script \
  data/scenes/office_001.phonescene \
  outputs/office_001/scene.usda \
  outputs/office_001/render_job.py \
  --output-dir outputs/office_001/renders

isaacsim --no-window --python outputs/office_001/render_job.py
```

The generated render directory contains:

```text
metadata.json
manifest.jsonl
rgb/
depth/
pose/
```

## 5. Write MP3D-Compatible Bag

```bash
phone-scene render-to-bag outputs/office_001/renders outputs/office_001/rosbag2
```

Replay:

```bash
ros2 bag play outputs/office_001/rosbag2 --clock
```

Then run the existing VRS-Hydra MP3D-style launch files with the generated bag.
