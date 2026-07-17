# `.phonescene` format

A `.phonescene` package is an immutable, self-describing directory. Format v2
preserves the raw ARKit measurements required for metric reconstruction while
remaining readable by v1 tooling through the original `rgb`, `depth`,
`confidence`, intrinsics, and pose fields.

## Atomic package lifecycle

SIDAR records into `scene_*.phonescene.partial`. It stops accepting frames,
drains every accepted write, closes and synchronizes all JSONL streams, exports
the final ARKit mesh, writes `capture_stats.json`, and checks the complete file
contract. Only a capture with zero pending, dropped, rejected, or failed writes
is atomically renamed to `scene_*.phonescene`.

A `.partial` directory is evidence of an interrupted or failed capture. It must
never be uploaded, reconstructed, or renamed manually.

```text
scene_name.phonescene/
  metadata.json
  manifest.jsonl
  capture_stats.json
  session_events.jsonl
  rgb/
    000000.png
  depth/
    000000.f32
  confidence/
    000000.u8
  depth_smoothed/
    000000.f32
  confidence_smoothed/
    000000.u8
  mesh/
    arkit_mesh_world.ply
    arkit_mesh_anchors.json
  annotation/
    sign_bookmarks.jsonl
    topdown_map.png
    topdown_mesh.png
    annotation_payload.json
    preview_mesh.json
    preview_mesh.bin
    preview_mesh_colored.json
    preview_mesh_colored.bin
    gt_rooms.json
```

The smoothed-depth files, mesh, preview assets, and room GT are conditional on
device support or user annotation. The v2 directories and JSONL files exist
even when a conditional stream contains no entries, which makes absence
explicit and allows strict detection of orphan files.

## `metadata.json`

Format v2 records capture identity, app provenance, exact hardware, enabled
ARKit streams, and coordinate contracts. The abbreviated shape is:

```json
{
  "format": "phonescene",
  "format_version": 2,
  "capture_id": "uuid",
  "created_at_utc": "2026-07-18T12:34:56Z",
  "device": "iPhone",
  "device_info": {
    "hardware_identifier": "iPhone17,1",
    "system_name": "iOS",
    "system_version": "26.4.2"
  },
  "app": {
    "name": "SIDAR",
    "version": "2.0",
    "build": "2",
    "git_commit": "0123456789ab"
  },
  "capture": {
    "requested_fps": 10,
    "raw_scene_depth_enabled": true,
    "smoothed_scene_depth_enabled": true,
    "mesh_expected": true,
    "scene_reconstruction_mode": "mesh_with_classification"
  },
  "primary_depth_stream": "scene_depth_raw",
  "depth_units": "meters",
  "rgb_orientation": "native_sensor",
  "world_alignment": "gravity",
  "pose": {
    "convention": "arkit_cam_to_world",
    "matrix_order": "row_major_4x4"
  }
}
```

`git_commit=development` means the app was launched directly from Xcode without
the repository build script. Formal captures must use a build with a concrete
commit recorded in the bundle.

## `manifest.jsonl`

Each line is one successfully materialized frame. Frame IDs are ordered,
contiguous, and start at zero. A manifest line is appended only after all files
for that frame have been written successfully.

```json
{
  "frame_id": 0,
  "timestamp": 123.456,
  "rgb": "rgb/000000.png",
  "depth": "depth/000000.f32",
  "confidence": "confidence/000000.u8",
  "depth_source": "scene_depth_raw",
  "smoothed_depth": "depth_smoothed/000000.f32",
  "smoothed_confidence": "confidence_smoothed/000000.u8",
  "image_width": 1920,
  "image_height": 1440,
  "image_pixel_format": "420f",
  "depth_width": 256,
  "depth_height": 192,
  "depth_pixel_format": "fdep",
  "confidence_width": 256,
  "confidence_height": 192,
  "confidence_pixel_format": "L008",
  "smoothed_depth_width": 256,
  "smoothed_depth_height": 192,
  "smoothed_depth_pixel_format": "fdep",
  "smoothed_confidence_pixel_format": "L008",
  "intrinsics": [[1337.0, 0, 957.3], [0, 1337.0, 729.9], [0, 0, 1]],
  "camera_to_world": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
  "tracking_state": "normal"
}
```

`depth/` is raw `ARFrame.sceneDepth`, stored as little-endian row-major
`float32` camera-Z meters. It is the authoritative reconstruction stream.
`depth_smoothed/` is the optional temporally averaged
`ARFrame.smoothedSceneDepth`; it is retained for visualization and controlled
comparisons, never silently substituted for raw depth. Confidence maps are raw
ARKit `uint8` values in the range 0–2.

The camera image is stored in ARKit's native sensor orientation. Its dimensions
and intrinsics share that coordinate system; display/UI transforms are not part
of offline projection.

## `capture_stats.json`

This file is the final commit record. It includes accepted/written frames,
pending/dropped/rejected/failed writes, throttled and missing-depth samples,
bookmark/event counts, tracking-state counts, actual FPS, maximum angular
velocity, mesh summary, and `integrity_failures`.

For a valid v2 capture:

```text
base_capture_complete == true
accepted_frames == written_frames == manifest line count
pending_writes_at_finish == 0
dropped_writes == 0
rejected_after_stop == 0
failed_writes == 0
requested_sign_bookmarks == written_sign_bookmarks
failed_sign_bookmarks == 0
failed_session_events == 0
integrity_failures == []
```

Any violation is a hard validation failure.

## `session_events.jsonl`

This append-only stream records capture lifecycle and AR session faults. Every
v2 package contains exactly one `recording_started` and one
`recording_stop_requested` event, plus any interruption, resume, or failure
events. Event IDs are unique.

## ARKit mesh

`mesh/arkit_mesh_world.ply` remains ASCII for transparent inspection and v1
reader compatibility. Each vertex now stores world position and world normal:

```text
x y z nx ny nz
```

Each triangular face stores the three vertex indices followed by the raw
`ARMeshClassification` value. The companion `arkit_mesh_anchors.json` preserves
every anchor UUID, ARKit transform, contiguous vertex/face range, and whether
classification was available. This provenance supports floor/wall extraction,
door/portal candidates, collision cleanup, and deterministic debugging.

The phone mesh is still source geometry. It is not a render mesh, collision
proxy, or navigation mesh until the downstream reconstruction gates pass.

## Sign bookmarks

The capture UI can bookmark the latest accepted frame as `unreviewed`,
`directional`, `locational`, or `directory`. Each line of
`annotation/sign_bookmarks.jsonl` binds the observation to immutable source
evidence:

```json
{
  "bookmark_id": "uuid",
  "frame_id": 42,
  "frame_timestamp": 135.25,
  "source_rgb": "rgb/000042.png",
  "cue_type": "directional",
  "camera_to_world": [[...], [...], [...], [...]],
  "tracking_state": "normal",
  "review_status": "unreviewed",
  "created_at_utc": "2026-07-18T12:35:12Z"
}
```

Bookmarks are acquisition aids, not ground truth. Text, arrows, source crops,
branch grounding, and destination semantics require later human review.

## Optional room annotation

`topdown_map.png` and `topdown_mesh.png` are phone-side annotation backgrounds
built from recorded geometry. `annotation_payload.json` maps pixels to metric
ROS-world coordinates and contains the trajectory plus inferred floor bands.
`gt_rooms.json` stores reviewed room polygons with `polygon_xy`, `min_z`, and
`max_z`. Preview assets are caches only and never authoritative geometry.

## Coordinate conventions

The package stores ARKit camera-to-world matrices directly. ARKit world is
gravity aligned with `+Y` up. Python conversion uses:

```text
ros_x = -arkit_z
ros_y = -arkit_x
ros_z =  arkit_y
```

The ROS camera frame is optical: `x` right, `y` down, `z` forward.

## Format v1 compatibility

The Python reader continues to accept v1 packages. v1 has only one `depth`
stream, may omit capture stats, bookmarks, events, normals, classifications,
and anchor lineage, and receives warnings where v2 requires provenance.
Integrity evidence is never ignored: nonzero pending or failed writes is a hard
failure for every version.
