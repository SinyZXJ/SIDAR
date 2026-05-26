# MP3D-Compatible ROS2 Contract

Generated bags intentionally mimic the existing VRS-Hydra MP3D replay contract.

## Topics

```text
/tesse/left_cam/rgb/image_raw              sensor_msgs/msg/Image, rgb8
/tesse/left_cam/camera_info                sensor_msgs/msg/CameraInfo
/tesse/depth_cam/mono/image_raw            sensor_msgs/msg/Image, 32FC1 meters
/tesse/seg_cam/converted/image_raw         sensor_msgs/msg/Image, mono16 dummy label
/tf                                        tf2_msgs/msg/TFMessage
/tf_static                                 tf2_msgs/msg/TFMessage
```

Use `ros2 bag play BAG --clock --qos-profile-overrides-path ~/.tf_overrides.yaml`
when replaying, as in the MP3D workflow.

## Frames

```text
world -> base_link_gt
base_link_gt -> left_cam
```

`left_cam` is treated as an optical frame. For phone-only captures, the body frame
and camera frame are coincident, so `base_link_gt -> left_cam` is identity.

## GT Rooms

Room annotation should use `polygon_xy` in the same `world` frame:

```json
{
  "dataset": "phone_isaac",
  "scene": "office_001",
  "frame": "world",
  "rooms": [
    {
      "room_id": 0,
      "label": "office",
      "polygon_xy": [[0, 0], [4, 0], [4, 3], [0, 3]],
      "min_z": 0.0,
      "max_z": 2.8
    }
  ]
}
```
