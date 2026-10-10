# Review timing and recorded frames — #13

Implemented experiment, 2026-10-10. This adds timing and inspection to both native recording prototypes. Physical accuracy remains unverified. The requested clip stays on the camera phone; recording-clip transfer and host playback are the next integration task, #14. Existing encrypted synthetic-video transfer is preserved.

## Timing design

The host measures eight authenticated exchanges, spaced 400 ms apart, over the existing local connection. Both phones use native monotonic microseconds. For host send/receive `t1/t4` and camera receive/reply `t2/t3`:

```
peerMinusHost = ((t2 - t1) + (t3 - t4)) / 2
networkRoundTrip = (t4 - t1) - (t3 - t2)
networkUncertainty = networkRoundTrip / 2
```

These are the four-timestamp equations in [RFC 5905, section 8](https://www.rfc-editor.org/rfc/rfc5905#section-8), applied to private clocks rather than UTC or a full NTP implementation. The lowest corrected round-trip sample is selected. Displayed uncertainty describes network asymmetry for that sample; it excludes clock drift, sensor exposure timing, timestamp precision and native-bridge scheduling. Four replies are required; mappings older than 30 seconds are rejected. Reconnect discards calibration. These experiment bounds do not establish frame-perfect synchronization.

The tap timestamp is taken on entry to the native request method, before any injected 0–5-second delivery delay. Browser-event-to-native-call latency is outside the clock measurement. Camera extraction ends at the mapped tap, rather than request arrival. Missing/expired windows fail explicitly while recording continues. Sealed inputs can be extracted immediately; unfinished inputs follow the continuous encoder's keyframe/finalization path and are pinned during extraction. Capture and encoder are not restarted for review.

iOS converts host-clock timestamps into the capture session's synchronization clock using `CMSyncConvertTime` (`masterClock` fallback on iOS 15.0–15.3). Apple documents that [capture output timestamps use the synchronization clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock). Android uses `SystemClock.elapsedRealtimeNanos`; mapped extraction is allowed only for [SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME](https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME). Unknown timebases fail rather than assuming an offset. Actual encoder PTS alignment remains a phone measurement.

Clip metadata records `requestedHostUs` (camera's mapped endpoint), `requestedSourceUs`, original `sourceFirstUs/sourceLastUs`, and `endpointErrorUs = sourceLastUs - requestedSourceUs`. This error reveals frame quantization/encoded-frame availability relative to the estimated endpoint; it does not measure true cross-phone synchronization error. Negative means the final frame precedes the estimated endpoint. Keyframe lead-in can extend the beginning beyond the requested review duration.

## Recorded frames and playback

Native workers enumerate real compressed sample timestamps and decode the requested sample index. iOS uses zero requested-time tolerances and checks the returned timestamp. Android uses [getFrameAtIndex](https://developer.android.com/reference/android/media/MediaMetadataRetriever#getFrameAtIndex(int)), requiring decoder and extractor frame counts to match. Android inspection requires API 28; older installations show an inspection error. Nonmonotonic samples, mismatched counts, invalid indices and decoding failures are visible errors.

First/last/previous/next show index, count and clip PTS. Decoded stills are scaled to at most 640 pixels per dimension and sent as PNG across the local Capacitor bridge. No intermediate frames are generated, interpolated or inferred. Spatial display scaling is not temporal interpolation. Replacement/cleanup is blocked during inspection; indexing is bounded to 10,000 samples.

Native playback offers 1×, 0.5× and 0.25× initial rates, with visible unsupported-rate errors. Display refresh may repeat recorded frames. Physical playback duration and perceived motion remain unverified. Players make decisions; this performs no umpiring.

## Evidence, 2026-10-10

- Automated Angular production build and Capacitor synchronization pass; signed iOS Debug build passes. Existing synchronous AVFoundation helpers produce deprecation warnings; inspection runs on a worker.
- Swift authenticated loopback tests pass with an injected five-second camera clock offset. Offset is within measured uncertainty plus 50 microseconds fixture tolerance. Zero/two-second delayed requests preserve the original mapped endpoint. Disconnect invalidates calibration; reconnect requires fresh measurements. Existing encrypted-transfer, tamper/replay, interruption/retry and cleanup regressions pass.
- Swift synthetic VideoToolbox tests pass: continuous cross-segment extraction, decoded boundary-frame equality, forward/backward inspection of distinct moving frames, sample PTS/count, invalid-index rejection and interrupted-encoder stop/restart. Generated fixtures only.
- Android app and instrumented-test APK build; five existing JVM buffer/preview-geometry checks pass. Added frame inspection assertions to the instrumented remux test: **compiled, not run**. No Android phone is connected in this session.

No physical results exist for the new controls yet. Mixed-platform clock exchanges, physical window error, slow-play duration, Android frame decoding and reconnect behavior remain pending. Earlier user-reported recording/playback passes apply to the previous prototype. The 30-minute recording test, physical capture continuity and offline hotspot exit criteria remain pending. Keep #13 open until measurements support acceptance.

## Quick phone check (5–10 minutes)

Use current builds on iPhone and OnePlus, on the same local Wi-Fi. Keep both apps open and Camera sideways. The existing [simple phone sheet](../testing/phone-test-sheet.html) remains unchanged. For this additional check, note only Works/Problem and any exact error:

1. Pair normally. Start recording on **Camera** and wait 25 seconds.
2. On **Host**, tap **Measure phone clocks**, wait for eight samples, select **None** for delay, then **Request review at this tap**. Wait for “Requested clip ready on camera.” Play it on Camera; confirm the recent scene and that recording continues after closing playback.
3. Measure again, select **5 seconds**, then request while someone holds up one finger in view. Immediately change to two fingers. The clip should end around the one-finger moment, rather than including five extra seconds of the later scene. Repeat with roles reversed; report noticeably early/late endings or failures.
4. Close playback. **Inspect first frame**, then **Last frame**. Press **Previous** a few times, then **Next**. Numbers/times should move correctly and returning should restore the image. Play at **0.5×** and **0.25×**; report slower motion, orientation problems or crashes.
5. Stop/reconnect the local session while keeping recording active. Fresh calibration should be required. Measure again and request once more; confirm recording continued and review worked.

For developer acceptance measurements, record roles, sample count, offset/uncertainty, delay, camera endpoint error, event placement and slow-play wall duration. An independent timing reference is needed to quantify actual event/window error; the finger check is qualitative. Do not require nontechnical testers to copy JSON or upload footage.

## Development checks

```sh
npm run sync:android
JAVA_HOME=/private/tmp/cricket-jdk21/jdk-21.0.12.1+1/Contents/Home \
  android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest
npm run sync:ios
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath /private/tmp/cricket-replay-derived build
xcrun swiftc ios/App/App/LocalSession.swift ios/App/App/PairingCode.swift \
  ios/App/App/SampleTransfer.swift tests/ConnectivityTests.swift -o /private/tmp/cricket-connectivity-tests
/private/tmp/cricket-connectivity-tests
xcrun swiftc -swift-version 5 -D RECORDING_TEST ios/App/App/RecordingBuffer.swift \
  ios/App/App/RecordingClip.swift ios/App/App/RollingRecording.swift tests/RecordingTests.swift \
  -o /private/tmp/cricket-recording-tests
/private/tmp/cricket-recording-tests
```
