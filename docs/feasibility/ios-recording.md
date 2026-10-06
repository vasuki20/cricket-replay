# P0-06: iPhone rolling camera experiment

Issue [#12](https://github.com/vasuki20/cricket-replay/issues/12), parent [#1](https://github.com/vasuki20/cricket-replay/issues/1). Updated 2026-10-04. Prototype implementation; physical acceptance pending. The user reports successful sideways camera startup. Physical acceptance is still incomplete: 30-minute endurance, preview correctness, permission-denial, Wi-Fi-loss and lifecycle checks remain pending. Physical testing was deferred by the user until 2026-10-05. Issue #12 remains open.

## Pipeline

Angular provides configuration, start/stop/extract/play/cleanup and report controls through the shared `src/native.ts` contract. Swift owns recording and app-private files. A single rear wide-angle `AVCaptureSession` delivers silent NV12 video to one H.264 `VTCompressionSession`. Only compressed MP4 writers rotate, at sync samples around five seconds; capture and compression stay running. This avoids deliberate stop/restart gaps, but does not prove device capture is gap-free.

Apple documents raw video delivery and dropped-frame reporting in [TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html), the encoder in [VideoToolbox](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection), and compressed passthrough using nil [AVAssetWriterInput output settings](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/outputsettings). Raw callbacks use a serial queue, discard late frames rather than accumulate unbounded input, and log drops explicitly. Encoder reordering is disabled. Segment samples use local microsecond PTS; the manifest preserves original first/last capture PTS. Extraction restores the original intervals across files.

Extraction snapshots the last encoded timestamp, requests a sync sample, and waits for the previous writer to finalize while the next writer records. It pins every required finalized input before eviction. A worker remuxes approximately the configured review window, including a preceding keyframe with at most five seconds of disclosed lead-in. Non-monotonic timestamps, missing inputs, timeout and decode errors produce visible failure. Beginning, middle and final actual frames must decode before publication; that is a smoke check, not a physical continuity verdict. Pins release on success/failure. Only one extraction runs; local playback can continue alongside capture. Camera footage is never sent by the existing synthetic transfer controls.

## Selection and bounds

Start requests camera permission when needed and requires foreground app and landscape. Hold that orientation throughout recording. A native live viewfinder now uses [AVCaptureVideoPreviewLayer](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer) attached to the same capture session. The shared UI supplies its bounds and controls; scrolling changes layout without restarting capture. Preview uses aspect-fit without mirroring and detaches when capture ends. Preview orientation, scrolling, playback recovery and its performance impact still require a physical check. Selection prefers advertised 1280×720 at 30 fps, then 24/15 fps, then 640×480 at 30/24/15 fps. Selection and encoded dimensions are reported. Input fps measures delivered capture buffers, not individual sensor exposures. Encoder fps, drop counts, timestamps, intervals over 50 ms, thermal state and system pressure are recorded. Advertised capabilities alone do not establish actual device performance. Runtime camera/encoder failure is visible; there is no silent mid-run quality switch.

Defaults are 120-second retention and 20-second review. Native and UI validation require integer retention 30–180 seconds, review 5–30 seconds, and review ≤ retention − 10. These are experiment bounds, not established sustained device limits or permanent product constants. Whole-segment eviction keeps a cutoff-overlapping segment; finalized extraction inputs remain pinned until completion. Segments must rotate within ten seconds. Storage has a 256 MiB watchdog ceiling, 64 MiB free-space floor and 16 MiB timestamp-event limit; sampling can overshoot slightly before stopping visibly. Metadata history is bounded. Files live under Application Support/recording-experiment and are excluded from backup. Starting a new experiment replaces old results; preserve the report first.

Capture is foreground-only. Backgrounding, locking, session interruption and runtime errors stop it visibly and require explicit restart. The idle timer is temporarily disabled and restored afterward. Network disconnect does not deliberately stop the independent recorder; this still needs a physical Wi-Fi-loss test. Stop drains encoder output and finalizes writers. Cleanup requires stopped capture and completed extraction/finalization.

## Evidence and reproducible developer checks

Automated evidence on 2026-10-04: Angular build and unsigned iOS application build passed during development. The macOS synthetic recording suite passed: 1,260 frames representing 42 seconds, continuous VideoToolbox encoding, extraction while more inputs arrived, preserved 30 fps timestamps, matching decoded source/clip frames around at least three joins, bounded eviction, stop and cleanup. It also passed configuration rejection, pin/finalization protection and missing-input cleanup. The test initially found zero-sample reader markers being treated as frames; extraction now skips those markers, as permitted by Apple's SDK header for `copyNextSampleBuffer`. Segment files also explicitly start at zero with local PTS. These checks cannot establish iPhone resolution/fps, heat, capture continuity or permission/lifecycle behavior. User-reported sideways startup is recorded below; no sustained iPhone recording measurements have been supplied.

```sh
npm run sync:ios
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath /private/tmp/cricket-replay-derived \
  CODE_SIGNING_ALLOWED=NO build
xcrun swiftc -swift-version 5 -D RECORDING_TEST \
  ios/App/App/RecordingBuffer.swift ios/App/App/RecordingClip.swift \
  ios/App/App/RollingRecording.swift tests/RecordingTests.swift \
  -o /private/tmp/cricket-recording-tests
/private/tmp/cricket-recording-tests
```

Synthetic checks exercise invalid configuration, pin/finalization eviction protection, missing-input cleanup, the same VideoToolbox encoder with moving generated frames, extraction while frames continue, decoded frames around file joins, retention and stop/cleanup. Fixtures are compiled only with `RECORDING_TEST`; installed builds expose no fixture controls. VideoToolbox and Swift module caches may require execution outside the development sandbox.

Existing macOS connectivity and transfer suites also passed on 2026-10-04: authentication and encrypted loopback transfers, exact bytes/checksum gating, tamper rejection, interruption/retry/cleanup, and generated silent MP4 playback. These are automated engine regressions, not physical phone recording or mixed-phone evidence. Application ID and signing settings are unchanged; the initial recording build was unsigned. The subsequent preview update built with existing signing settings and installed successfully on the connected iPhone 15 and iPhone 15 Pro. Installation is not a preview or recording acceptance pass.

## Manual physical tests

1. Build/install from the existing Xcode App scheme with its existing signing settings. Discover the currently connected iPhone rather than reuse a prior identifier. Keep footage on the phone. Record model, iOS, battery, charging state, case and room conditions. Open the app, grant Camera, hold landscape and aim at moving action plus a visible running timer. No microphone prompt should appear.
2. Use defaults 120/20. Start, wait at least 25 seconds, extract and play locally. Confirm capture counters continue throughout extraction/playback. Record selected versus encoded resolution, delivered/encoded fps, drops, gap counts, maximum intervals, storage and extraction duration/segment count. Inspect timer and movement around boundaries; metadata alone cannot prove frame continuity.
3. Run at least 30 uninterrupted foreground minutes. Extract around 0:30, 2:00, 5:00, 10:00, 20:00 and ≥30:00, preferably at differing positions relative to five-second boundaries. At each point record the above measurements, storage/peak growth, warmth, thermal/pressure changes and battery. Stop and use **Read full experiment report**; copy metadata before restarting or cleanup. Report any error text exactly. Do not upload personal footage.
4. During the endurance run disconnect Wi-Fi using Settings without locking the phone; returning from Settings may itself cause the documented foreground stop. To isolate network loss, instead turn off the connected access point from another device while this app stays foreground. Record before/after capture counters and an extraction. Treat the Settings background test separately from network-loss evidence.
5. After preserving endurance evidence, start a short run and lock/background the phone. On return expect visible stopped/failed status, no implied automatic recording, and successful explicit fresh restart. Test a camera interruption if available and preserve its reported reason.
6. Preserve results, then deny Camera in iOS Settings → Apps → Replay Feasibility → Camera (labels vary by iOS). Start should visibly fail without files falsely marked ready. Request permission and deny the prompt on a fresh permission state if available; record the actual flow. Grant in Settings and verify a new landscape run. Also try portrait start, invalid values and early extraction; expect visible rejection.
7. Stop, preserve the final metadata report, then cleanup. Repeat short smoke checks on both iPhone 15 and iPhone 15 Pro when available. Existing pairing, synthetic transfer and playback require regression checks independently. Physical 30-minute and decoded camera-boundary evidence remain required before closing #12; the epic's offline/hotspot matrix remains unresolved.

## Startup feedback update — 2026-10-04

The user confirmed recording starts on iPhone and Android when held sideways. This is user-reported startup evidence only. The UI now explicitly explains rotation lock/auto-rotate, requests Camera access at Start, displays starting/recording/stopped feedback beside the controls, and reports errors there. Live preview is implemented; the signed iOS build passed. The existing macOS synthetic encoder suite does not exercise the iOS preview layer. All 30-minute and preview-specific physical acceptance checks remain pending.

Preview update verification: Angular build, signed iOS debug build and the macOS synthetic recording suite passed again. Installation succeeded on iPhone 15 and iPhone 15 Pro. No live camera preview or endurance test was run by the agent; preview display/orientation, scrolling, playback recovery and capture performance remain pending physical checks.

The user subsequently reported iPhone works and that repeated preview crashes affect only OnePlus. This is user-reported functional evidence, with no detailed orientation/interval/endurance measurements. The Android container crash fix does not change the installed iPhone build.

## Quick tester scope — 2026-10-06

The user reports iPhone preview is correct; no iPhone code changes accompany the OnePlus orientation fix. The public tester sheet now covers a short offline recording/clip/continued-capture check plus one demonstration-video send per host direction, with simple Works/Problem selections and optional notes. Report copying and numeric measurements are no longer required from the casual tester. The detailed 30-minute and failure-scenario procedures in this document remain follow-up work; no sustained recording acceptance is inferred from the shortened checklist.
