# VR Player

Native Cardboard VR video player for iPhone, built with Swift 6, SwiftUI,
SwiftData, AVFoundation, Metal, and Google Cardboard 1.34.0.

## Requirements

- Xcode 26.6 in `/Applications/Xcode.app`
- iOS 26.5 or later
- CocoaPods (the lockfile pins `Protobuf-C++` 3.18.0)
- A physical iPhone for motion tracking, Cardboard distortion calibration,
  hardware-decoder performance, SMB playback, brightness, and volume checks

The system `xcode-select` may still point at CommandLineTools. Set
`DEVELOPER_DIR` explicitly for command-line builds:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
pod install
open vr-player.xcworkspace
```

Open `vr-player.xcworkspace`, not `vr-player.xcodeproj`.

## Supported media

The first release targets MP4/MOV containers with H.264 or H.265 video, AAC
audio, SDR, and up to 4K 60 fps when the device can hardware-decode the source.
It supports 180-degree and 360-degree projection plus Mono and side-by-side SBS
texture layouts.

Selected files are validated before they are added to the playlist. Unsupported
containers, codecs, audio formats, and HDR video are rejected during import.

MKV, VP9, AV1, HDR, and software decoding are intentionally out of scope.

## Local and SMB files

Connect an SMB share in Apple's Files app, then use **Add video** in VR Player.
The app does not implement SMB credentials or directory browsing. It persists a
security-scoped bookmark for each selected file.

Remote files are exposed to AVFoundation through byte-range requests backed by
a sparse cache in the app's Caches directory. Cached ranges and source metadata
are mirrored in SwiftData so later playback and seeks can reuse downloaded data.
If iOS removes or truncates a cache file, its persisted range index is discarded
and the data is read from the source again. Deleting a playlist item also deletes
its cached bytes. The first release does not enforce a cache-size limit.

## Viewer profile

The app looks for this optional bundled file:

```text
vr-player/viewer_profile.bin
```

Place or replace the final self-built viewer profile at that path and rebuild.
The Xcode file-system-synchronized group includes it in the app bundle. If the
file is absent or empty, the Cardboard v1 profile is used. QR scanning is not
included and the app does not request camera permission.

## Verification

Run simulator unit tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -workspace vr-player.xcworkspace \
  -scheme vr-player \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  test -quiet
```

Run an unsigned device build:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -workspace vr-player.xcworkspace \
  -scheme vr-player \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Simulator tests cover range merging, cache-file recovery and deletion, supported
container validation, UV mapping, gaze dwell/hit testing, playback state and
control transitions, and bookmark round trips. Before relying on the player,
validate these on a physical iPhone with representative local and SMB 4K60
H.264/H.265 SDR samples:

- startup, ten-minute continuous playback, pause/resume, previous/next, and seek
- disconnect, reconnect, and Retry behavior during SMB playback
- saved progress and per-item 180/360 plus Mono/SBS settings
- Cardboard pose tracking, recentering, distortion, and the up/down HUD gesture
- brightness and system volume controls
- sustained dropped-frame rate at or below 1 percent for local playback

## Debug HUD preview

The Debug build accepts `--hud-preview` to render a deterministic stereo HUD
without importing a video. This mode exists for simulator visual QA; its action
handler is intentionally inert.
