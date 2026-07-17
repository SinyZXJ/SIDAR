# End-to-End Workflow

## 1. Record on iPhone

1. Build `ios/PhoneSceneCapture` in Xcode.
2. Install to iPhone 15 Pro.
3. Start AR session and wait for tracking state `normal`.
4. Press Record.
5. Walk every room deliberately. Enter each room and rotate in place. Keep the
   live **Turn slower** warning clear.
6. Whenever a sign is visible, tap **Mark Sign**. Use **Typed Mark** when its
   directional/locational/directory role is already unambiguous. Each mark is
   attached to the latest accepted RGB-D frame, timestamp, pose, and tracking
   state; it is not a free-floating wall-clock note.
7. Stop recording and keep SIDAR open until finalization finishes. A valid
   capture is atomically renamed from `.phonescene.partial` to `.phonescene`.
   If any accepted write, bookmark, event, or expected mesh fails, SIDAR keeps
   the partial directory for diagnosis and does not publish a finished capture.
8. Optionally tap **Review / Annotate Rooms**. The app opens a top-down
   projection built from recorded mesh/depth/trajectory only. Draw one polygon
   per room, choose labels, and save GT. For stairs or multi-level scenes,
   switch the floor selector before drawing rooms on a different level; the app
   infers floor z bands from the recorded camera trajectory and lets you adjust
   each floor's `min_z` / `max_z` before saving.
9. Copy or upload the `.phonescene` directory from the app Documents folder.

Recommended capture style:

- Keep the phone in landscape orientation.
- Move at walking speed.
- Maintain 60% or more visual overlap between nearby viewpoints.
- Revisit doorways and room boundaries.
- Avoid fast yaw motion and long blank-wall-only segments.
- Capture both sides of doorways and approach signs closely enough for readable
  text; the button preserves the observation but cannot invent missing pixels.

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

- capture provenance, atomic-completion ledger, and exact frame/bookmark counts;
- raw and smoothed RGB-D stream existence, dimensions, and unreferenced files;
- metric-depth validity and ARKit confidence ranges;
- intrinsics, pose transforms, timestamp ordering, and trajectory continuity;
- mesh body, normals, face classifications, and anchor-range provenance;
- exact sign-to-frame/timestamp/pose binding and session lifecycle events.

Treat validation errors as hard blockers. Warnings identify usable but degraded
coverage (for example low depth validity, poor tracking, or excessive rotation)
and should be recorded in experiment metadata rather than ignored.

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

This command re-renders a prescribed camera trajectory for reproducible sensor
data. It is not required for interactive navigation. For live planner/executor
experiments, import the reconstructed USD as persistent scene geometry, generate
collision and navigation data in the downstream ALIGN pipeline, spawn a robot,
and drive it with the simulator's live control loop. The recorded phone path is
then only reconstruction evidence, not the robot's allowed trajectory.

## 5. Optionally Write an MP3D-Compatible Bag

```bash
phone-scene render-to-bag outputs/office_001/renders outputs/office_001/rosbag2
```

Replay:

```bash
ros2 bag play outputs/office_001/rosbag2 --clock
```

Use this only for compatibility/regression baselines. The interactive
Habitat/Isaac + ROOMS experiment should consume live simulator observations and
poses instead of replaying this bag.
