# PhoneSceneCapture iOS App

This is SIDAR's integrity-checked ARKit/LiDAR recorder for LiDAR-capable iPhones.

It records:

- RGB frames from `ARFrame.capturedImage`
- raw LiDAR depth from `ARFrame.sceneDepth` as the primary reconstruction stream
- optional `ARFrame.smoothedSceneDepth` in a separate comparison stream
- separate raw and smoothed depth-confidence maps
- camera intrinsics
- ARKit camera-to-world poses
- ARKit world mesh positions/normals, per-face semantic classifications, and
  anchor transforms/ranges
- sign bookmarks tied to exact accepted frames and poses
- capture statistics and session lifecycle events

Recording first targets a `.phonescene.partial` directory. SIDAR publishes the
final `.phonescene` name only when every accepted write and final integrity check
succeeds. A partial package is diagnostic/recoverable data, not a valid input.

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
