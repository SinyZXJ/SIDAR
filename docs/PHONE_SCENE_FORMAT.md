# `.phonescene` Format

A `.phonescene` package is a directory. It is designed to be easy to inspect,
copy from iOS, and process without custom binary dependencies.

```text
scene_name.phonescene/
  metadata.json
  manifest.jsonl
  rgb/
    000000.png
  depth/
    000000.f32
  confidence/
    000000.u8
  mesh/
    arkit_mesh_world.ply
  annotation/
    topdown_map.png
    topdown_mesh.png
    annotation_payload.json
    preview_mesh.json
    preview_mesh.bin
    preview_mesh_colored.json
    preview_mesh_colored.bin
    gt_rooms.json
```

## `metadata.json`

Top-level recording metadata:

```json
{
  "format": "phonescene",
  "format_version": 1,
  "device": "iPhone",
  "world_alignment": "gravity",
  "camera_model": "arkit_lidar",
  "rgb_color_space": "sRGB",
  "depth_units": "meters",
  "pose": {
    "convention": "arkit_cam_to_world",
    "matrix_order": "row_major_4x4"
  }
}
```

## `manifest.jsonl`

One JSON object per captured frame:

```json
{
  "frame_id": 0,
  "timestamp": 123.456,
  "rgb": "rgb/000000.png",
  "depth": "depth/000000.f32",
  "confidence": "confidence/000000.u8",
  "image_width": 1920,
  "image_height": 1440,
  "depth_width": 256,
  "depth_height": 192,
  "intrinsics": [[fx, 0, cx], [0, fy, cy], [0, 0, 1]],
  "camera_to_world": [[...], [...], [...], [...]],
  "tracking_state": "normal"
}
```

Depth files are little-endian `float32` meters with row-major layout and dimensions
recorded in the corresponding manifest entry. Confidence files are raw `uint8`
values with the same depth dimensions.

## Optional `annotation/`

The iOS app can create this folder after capture when the user reviews the
top-down scene projection and draws ground-truth room polygons. Older
`.phonescene` packages may omit the folder entirely.

`topdown_map.png` is a grayscale density image built only from recorded geometry:
ARKit mesh vertices, sampled depth points, and the camera trajectory. It is for
phone-side annotation and must not contain model predictions.

`annotation_payload.json` maps image pixels back to metric ROS-world
coordinates:

```json
{
  "scene_id": "scene_YYYYMMDD_HHMMSS",
  "map_build_version": 2,
  "image_width": 512,
  "image_height": 384,
  "world_min_xy": [-1.0, -1.0],
  "world_max_xy": [4.0, 3.0],
  "resolution_m_per_px": 0.02,
  "trajectory_xy": [[0.0, 0.0], [0.1, 0.0]],
  "trajectory_xyz": [[0.0, 0.0, 1.2], [0.1, 0.0, 1.2]],
  "labels": ["living_room", "bedroom", "bathroom"],
  "floors": [
    {"id": "floor_1", "name": "Level 1", "min_z": -0.5, "max_z": 2.8}
  ]
}
```

`trajectory_xyz` stores the same camera path in ROS-world meters with height.
The app uses it to infer one or more floor z bands. The top-down map includes
all inferred floor bands instead of applying a fixed height crop, so stairs and
multi-level captures remain visible. The `floors` array is optional for older
packages, but new room GT uses each selected floor's `min_z` / `max_z` when
writing `gt_rooms.json`.
`map_build_version` lets the app detect older annotation maps and rebuild them
with the current floor-aware projection logic.

`topdown_mesh.png` is an optional mesh-only top-down projection that can be used
as an annotation background when available.

`preview_mesh.json` and `preview_mesh.bin` are optional lightweight 3D preview
assets generated from `mesh/arkit_mesh_world.ply`. They are intended for
interactive phone-side review only. The binary cache stores sampled ARKit-world
vertices, per-vertex colors, and optional triangle indices. If the full mesh is
too large, the preview may degrade to a sampled point primitive.

`preview_mesh_colored.json` and `preview_mesh_colored.bin` are optional RGB
vertex-color preview assets. They are generated only when the user explicitly
starts RGB colorization in the app. Failure to generate these preview files does
not invalidate the recording or room GT.

`gt_rooms.json` is evaluator-compatible real-scene GT:

```json
{
  "dataset": "real",
  "scene_id": "scene_YYYYMMDD_HHMMSS",
  "frame": "world",
  "rooms": [
    {
      "room_id": 0,
      "label": "office",
      "polygon_xy": [[0.0, 0.0], [2.0, 0.0], [2.0, 1.5], [0.0, 1.5]],
      "min_z": 0.0,
      "max_z": 3.0
    }
  ]
}
```

Room polygons use ROS-world `xy` meters. The current labelspace is
`vlm_mtp3d_1`: `living_room`, `bedroom`, `bathroom`, `kitchen`, `dining_room`,
`office`, `hallway`, `staircase`, `balcony`, `home_theater`, `gym`,
`pool_area`, `laundry_room`, `junk`, and `garage`.

## Coordinate Conventions

The iPhone app stores ARKit camera-to-world matrices directly:

- ARKit world is gravity-aligned, with `+Y` up.
- ARKit camera uses Apple's camera convention.

The Python tools convert to a ROS/MP3D-friendly world:

```text
ros_x = -arkit_z
ros_y = -arkit_x
ros_z =  arkit_y
```

The ROS camera frame is optical:

```text
x right, y down, z forward
```
