# PhoneSceneCapture iOS App

This is a minimal ARKit/LiDAR recorder for iPhone 15 Pro.

It records:

- RGB frames from `ARFrame.capturedImage`
- LiDAR depth from `ARFrame.smoothedSceneDepth` when available, otherwise `sceneDepth`
- depth confidence maps
- camera intrinsics
- ARKit camera-to-world poses
- an optional ARKit mesh as `mesh/arkit_mesh_world.ply`

Open `PhoneSceneCapture.xcodeproj` on macOS with Xcode, select your iPhone, and run.
Captured `.phonescene` folders are written to the app Documents directory. Enable file
sharing in Finder to copy the packages back to the workstation.

## Command Line Build

This app requires full Xcode with the `iphoneos` SDK. Command Line Tools alone are not
enough. Select Xcode first:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

From the repository root, build a signed local iPhone app:

```bash
scripts/build_iphone_app.sh \
  --team YOUR_TEAM_ID \
  --bundle-id com.yourname.PhoneSceneCapture
```

To also export a development `.ipa`:

```bash
scripts/build_iphone_app.sh \
  --team YOUR_TEAM_ID \
  --bundle-id com.yourname.PhoneSceneCapture \
  --export-ipa
```
