# P0-05: Android rolling camera experiment

Issue [#11](https://github.com/vasuki20/cricket-replay/issues/11), parent [#1](https://github.com/vasuki20/cricket-replay/issues/1). Updated 2026-10-04 (Asia/Singapore). **Prototype implemented; physical acceptance pending. 30-minute test NOT RUN; no gap-free claim.** The user authorized committing/pushing the prototype on 2026-10-04 and deferred physical testing until 2026-10-05. Issue #11 remains open, including the unresolved late-run camera failure described below.

## Pipeline and boundaries

Angular owns configuration, start/stop/extract/play/cleanup controls and polled status. Kotlin owns camera, encoding, app-private files and extraction. The typed methods and metadata in `src/native.ts` are a contract for iOS #12; recording calls are now enabled on Android and iPhone; see the iOS experiment for its evidence. Existing synthetic transfer remains separate: extracted camera footage is not sent automatically.

A single rear-camera [Camera2 repeating capture session](https://developer.android.com/reference/android/hardware/camera2/CameraCaptureSession#setRepeatingRequest(android.hardware.camera2.CaptureRequest,%20android.hardware.camera2.CameraCaptureSession.CaptureCallback,%20android.os.Handler)) feeds one H.264 [MediaCodec input surface](https://developer.android.com/reference/android/media/MediaCodec#createInputSurface()). The encoder stays running for the entire foreground experiment. AVC Baseline and, on API 29+, zero B frames are requested; decreasing/duplicate output timestamps fail explicitly. The selected encoder and actual output dimensions are reported. Audio is absent; no microphone permission or audio track is used.

Only [MediaMuxer](https://developer.android.com/reference/android/media/MediaMuxer) outputs rotate: each new MP4 starts with an encoder-marked sync frame at roughly five seconds. Closing/starting muxers does **not** stop the camera, rebuild its session, replace its input surface, flush the encoder, or signal EOS. The same encoded frame goes into exactly one segment. Each file rebases PTS to its first frame; a native manifest retains the original first/last PTS so extraction restores intervals between files. This architecture avoids deliberate camera restart gaps; device buffering, storage latency, exposure and thermal behavior still require measured validation.

The one-second I-frame interval is requested, not assumed. [Requesting a sync frame](https://developer.android.com/reference/android/media/MediaCodec#PARAMETER_KEY_REQUEST_SYNC_FRAME) means “soon”, without a guaranteed deadline. Segment rotation requests one after five seconds if needed and stops capture visibly if no boundary occurs within ten seconds. Extraction records the current last encoded PTS at the tap, requests a sync frame, seals the active file at that next keyframe, then pins all sealed inputs covering the request window **before eviction**. The new keyframe belongs to the next continuously recorded segment. Extraction waits at most five seconds for sealing, and excludes frames newer than the tap's encoded PTS. It never reads an unfinalized MP4.

The extraction worker uses [MediaExtractor](https://developer.android.com/reference/android/media/MediaExtractor) and a new muxer to remux the selected files. It starts at the preceding sync sample, keeps original PTS deltas across boundaries, and rejects non-monotonic/missing/invalid inputs. The clip is therefore approximately the requested review duration, with up to five seconds of disclosed keyframe lead-in; typical one-second keyframes should produce much less. Pin references release on success/failure. Only one extraction is allowed. Prior completed clip replacement is blocked while playback is open. Beginning, middle and final clip frames must decode before it is marked ready. Native VideoView playback keeps the Activity foreground and recording can continue during playback.

## Selection, bounded retention and lifecycle

Target: landscape 1280×720, 30 fps. Start requests camera permission when needed and requires landscape display relative to rear sensor orientation; hold that landscape direction throughout the run. Native rotation metadata is 0/180 degrees. The shared UI now shows a native live rear-camera preview. Camera2 sends frames to a TextureView surface alongside the encoder in the same repeating request. Preview stays attached while scrolling or playing clips; only its layout/visibility changes. Preview support is checked separately from encoder sizes, and session setup failures remain visible. Actual preview correctness and its effect on capture rate/heat still need physical validation. Starting upright produces a visible error before capture. No UI/system orientation setting is permanently changed.

[Camera stream sizes/minimum frame durations](https://developer.android.com/reference/android/hardware/camera2/params/StreamConfigurationMap) and AE fps ranges are intersected with [encoder size/rate capabilities](https://developer.android.com/reference/android/media/MediaCodecInfo.VideoCapabilities). Preference is 720p, then 640×480 landscape (4:3); fps preference is the largest advertised AE upper bound of 15–30, favoring a fixed range. A variable AE range is disclosed as a fallback even with an upper bound of 30. Actual sensor/encoder fps and encoder output resolution are measured separately; advertised support alone is not a physical pass. Startup/session/codec failures are surfaced instead of silently changing quality mid-run. Other size/rate fallbacks and runtime retry at a lower configuration remain outside this prototype.

Defaults: retention 120 seconds and review 20 seconds. Both UI and native code require whole seconds: retention 30–180, review 5–30, and review ≤ retention − 10. These are conservative **experiment bounds**, validated for type/range and covered by tests; they are not proven sustained performance bounds for every supported device, nor permanent product limits.

Eviction deletes only entire sealed, unpinned segments older than the latest encoded PTS minus retention. A segment overlapping the cutoff is kept, so physical retention may exceed the configured interval by one segment (normally ~5 seconds, enforced <10 seconds). Active extraction may temporarily retain older pinned inputs; the worker releases them and triggers eviction afterward. Ring media, timestamp sidecars, latest clip and evidence share a 256 MiB hard disk watchdog; capture stops rather than deleting protected inputs if that bound is reached. At the requested 4 Mbit/s, 120s media is roughly 60 MB and 180s roughly 90 MB; these are estimates, not observed storage. Actual codec bitrate and MP4 preallocation can differ. At least 64 MiB free space must remain. Checks run every second, so transient writes can exceed the threshold before failure is detected. Sensor/encoded event CSV has a separate 16 MiB bound; capture stops visibly if reached. Segment/extraction history is capped at 1000/100 entries; old media and per-segment sidecars are deleted together. There is one retained review clip, replaced by the next extraction.

Files are in app-private **no-backup** storage under `recording-experiment/`. They are not added to Photos, shared storage, transfer, or a server. They survive normal app relaunch for developer inspection; read the saved report after relaunch if needed. Starting a new experiment deletes the previous experiment. Explicit **Delete recording experiment** requires stopped capture, completed extraction and closed playback. Abrupt process death can leave an incomplete active segment; it is never offered as a ready clip. This prototype does not recover/continue a killed recording.

Wi-Fi connection state does not control capture. Stopping/disconnecting a local session should leave capture active. Backgrounding/locking stops camera recording explicitly and also preserves the existing network session shutdown behavior. Foreground recording adds only a temporary keep-screen-on window flag. No background camera service is implemented.

## Timestamp and frame evidence

`report.json` is updated every second and after stop/extraction. It contains device/OS, requested and encoded dimensions, capability fallback, elapsed time, encoder/sensor counts and effective fps, interval maxima, >50 ms counts, failed captures, current/peak disk bytes, cumulative encoded bytes, segment first/last PTS and preceding boundary intervals, and extraction results. **Read full experiment report** returns metadata only for selecting/copying on the phone; the ordinary diagnostics view shows current status only.

`capture-events.csv` records each [sensor exposure timestamp](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#SENSOR_TIMESTAMP) in nanoseconds and each encoder PTS in microseconds, deltas within each domain, segment boundaries, failed captures, and Android thermal status each second (API 29+). Timestamp source is recorded; UNKNOWN does not guarantee comparability to elapsed realtime. Sensor and encoder intervals/fps are assessed separately, with no assumption of a fixed offset or common clock. The 50 ms threshold is a diagnostic at a 30 fps target, not a verdict: fallback 15 fps or exposure variability can legitimately exceed it.

Per-segment CSV records global encoded PTS, deltas and sync markers. `clip-frames.csv` maps frame index to global PTS, clip PTS, delta and source segment. This last file describes only the latest clip. Timestamp continuity and successful decoding do not establish smooth visible motion. The instrumented capture check decodes adjacent actual frames around every join but does not judge a visible timer. The user must inspect moving footage; no AI makes an umpiring decision or gap verdict.

## Development evidence

- Angular production build/strict templates and Android Debug app/test builds: PASS (Java 21). Sandboxed Angular worker aborted; outside-sandbox build succeeded. Gradle requires access to its installed home cache.
- Three JVM unit tests: PASS for configuration rejection, insufficient buffer, and protected input survival across eviction/release.
- Two non-camera instrumented extraction tests on OnePlus CPH2465 / Android 14: **PASS, OK (2 tests)** in 9.518s. A synthetic 20s/30fps sample is split into four MP4s, remuxed across joins, and checked for original 33.333ms intervals and exactly matching decoded frames immediately before/at/after each join. Missing input fails and removes incomplete output. This proves synthetic remuxing on this phone, not camera continuity.
- Existing native engine regressions: **PASS, OK (5 tests)** in 2.965s for pairing validation, on-phone Wi-Fi authentication/connection retry/encrypted transfer, Swift protocol fixtures, CryptoKit ciphertext/tamper rejection and corrupt partial-file handling. Existing native visible playback test was not rerun because the display was locked. Application ID, signing, transport and iOS native code are unchanged.
- First short OnePlus recording run: **FAILED late in run** after successful extraction and decoded join frames. Its initial test did not retain the failure report, so the cause is unresolved. Do not count it as a sustained-capture pass. A rerun failed at landscape startup; ADB then confirmed the phone was locked/asleep. The final test checks unlocked state explicitly and waits for landscape rotation. A final sustained-camera rerun and existing UI regression suite require an unlocked phone.
- Camera permission denial/regrant: NOT RUN for recording UI.
- Wi-Fi loss during camera capture: NOT RUN.
- 30-minute recording/storage plateau/heat and visible timer continuity: NOT RUN.
- User-reported evidence from pairing and synthetic transfer is documented separately in `android-transfer.md`; it does not prove camera recording.

## Reproduce development checks

Use the current Java 21 runtime only if it still exists. Discover ADB identifiers at test time; an offline emulator can also be present. Keep the OnePlus **unlocked**, app foreground, camera permission granted and rear camera aimed at a nonpersonal subject. The capture test temporarily selects landscape and records ~36 seconds, with 30s retention/20s review; it deletes its camera footage afterward and retains **metadata only** in `cache/recording-test-result.json`. It starts a fresh experiment and therefore removes any prior recording experiment; preserve manual evidence before rerunning it.

```sh
npm run sync:android
cd android
JAVA_HOME=/private/tmp/cricket-jdk21/jdk-21.0.12.1+1/Contents/Home \
  ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest
~/Library/Android/sdk/platform-tools/adb devices -l
~/Library/Android/sdk/platform-tools/adb -s <device> install --no-streaming -r app/build/outputs/apk/debug/app-debug.apk
~/Library/Android/sdk/platform-tools/adb -s <device> install --no-streaming -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
~/Library/Android/sdk/platform-tools/adb -s <device> shell am instrument -w -r \
  com.aadhinitinytales.cricketreplay.test/androidx.test.runner.AndroidJUnitRunner
~/Library/Android/sdk/platform-tools/adb -s <device> shell am start -n com.aadhinitinytales.cricketreplay/.MainActivity
```

The all-class run also exercises existing native connectivity/encrypted transfer/synthetic generation/playback tests. They require Wi-Fi and an unlocked phone. A recording-only run adds `-e class com.aadhinitinytales.cricketreplay.RecordingTest` to instrumentation.

While awaiting unlock, the two non-camera extraction checks can run independently by adding `-e class 'com.aadhinitinytales.cricketreplay.RecordingTest#remuxPreservesSyntheticFramesAndIntervalsAcrossFiles,com.aadhinitinytales.cricketreplay.RecordingTest#missingExtractionInputFailsWithoutPublishingClip'`.

## Physical 30-minute procedure (phone-only runtime)

1. First run a **45-second smoke check**, extract/play after 25s, and confirm camera counters continue to 45s without an error. If it fails, stop and copy **Read full experiment report** and the error text before restarting; the earlier late-run failure still needs a clean rerun. For the endurance run, keep personal footage out of the experiment. Use a visible stopwatch with hundredths and a moving object. Prop the OnePlus in landscape, keep a consistent direction, record lighting, case on/off, ambient conditions, battery %, charging state and starting warmth. Disable mobile data. Open the app, request camera permission if needed. Leave retention/review at **120 / 20**.
2. Tap **Start rear camera**. Expect `recording`; note selected/encoded dimensions, AE range, fallback and measured fps after 30s. Extract at roughly **24s, 29s and 34s**, closing playback before each next extraction. An arbitrary tap may cut an extra segment; reports record the actual boundaries. Each result must be ready with multiple source segments and recording/frame counters must continue increasing. Play each clip and inspect the timer/moving object for freezes/skips/repeated intervals around joins. Report visible defects even if the timestamp counts are clean.
3. Continue for **at least 30:00** without stopping capture. At **2, 5, 10, 20 and 30 minutes**, note elapsed/buffered seconds, storage/peak MiB, effective encoder/sensor fps, max frame interval and >50ms count, failed captures and warmth (cool/warm/hot/uncomfortable), thermal warning or throttling, and battery %. Extract and play at every checkpoint, and make two nearby extraction requests around a five-second checkpoint to stress boundaries. Capture continues during playback; close playback before extracting again. Buffer storage should plateau apart from one segment, latest clip and bounded growing telemetry. Cumulative encoded bytes intentionally continues growing even when retained storage stabilizes.
4. After at least two minutes, turn **Wi-Fi off using the notification shade**, dismiss it promptly and keep the app foreground. Wait 30s; verify `recording` and frame/elapsed counters keep advancing, then extract/play while disconnected. Record counters before/after. If the OS backgrounds the app, report that separately and restart the endurance run; a stopped/restarted run does not satisfy uninterrupted 30 minutes. Return Wi-Fi to your preferred state afterward.
5. At **30:00 or later**, extract/play again while capture remains active. Record final observations and tap **Stop recording**; expect `stopped` and a final report. Tap **Read full experiment report** and select/copy the metadata into your results. Do **not** start another experiment or delete files until results are preserved. No laptop is needed for capture, extraction, local playback or copying this report.
6. Separately test denial after preserving the endurance results: phone **Settings → Apps → Replay Feasibility → Permissions → Camera → Don't allow** (OxygenOS labels may vary). Return and tap Start; expect a clear denied/not-requested error, no recording and no microphone prompt. Request camera permission and deny if the OS offers a prompt; report the actual flow. Grant Camera in Settings, return, hold landscape and start a fresh short experiment; confirm recovery. This deletes the previous experiment. Also try invalid review/retention values, portrait start and an extraction before enough footage; expect visible errors and no false ready clip.
7. Optionally background/lock a short run: expect capture to stop visibly on return and require a fresh start. This is an explicit lifecycle limitation, not the 30-minute endurance run. Close playback/stop and delete the temporary recording experiment after evidence is saved.

Send metadata/observations only, not footage, pairing QR or secrets. Suggested result rows:

| Elapsed | Encoded dimensions / fps | Storage / peak MiB | Gap count / max ms | Extraction duration / segments / result | Warmth / thermal / battery / charging |
| --- | --- | --- | --- | --- | --- |
| 0:30 | Pending | Pending | Pending | Pending | Pending |
| 2:00 | Pending | Pending | Pending | Pending | Pending |
| 5:00 | Pending | Pending | Pending | Pending | Pending |
| 10:00 | Pending | Pending | Pending | Pending | Pending |
| 20:00 | Pending | Pending | Pending | Pending | Pending |
| ≥30:00 | Pending | Pending | Pending | Pending | Pending |

Also report Wi-Fi-loss before/after counters, timer continuity at joins, permission denial/recovery and any error text. Issue #11 stays open until evidence satisfies its criteria or documents a blocker. The epic's other pairing/hotspot/iOS requirements remain open independently.

## Optional developer inspection without copying footage

After discovering the current device, retrieve **only** the report or timestamp CSV via `run-as`. Camera frames remain on the phone. These commands need a developer computer solely for inspecting evidence, not for app operation:

```sh
adb -s <device> exec-out run-as com.aadhinitinytales.cricketreplay \
  cat no_backup/recording-experiment/report.json > /private/tmp/cricket-recording-report.json
adb -s <device> exec-out run-as com.aadhinitinytales.cricketreplay \
  cat no_backup/recording-experiment/clip-frames.csv > /private/tmp/cricket-clip-frames.csv
```

Compare each segment's preceding interval and first/last PTS, inspect flagged intervals in both timestamp domains, and decode adjacent actual clip frames around the segment-name transitions on the phone. Report non-monotonic timestamps, visible freezes and sensor-versus-encoder count differences with context; startup/shutdown frames can differ legitimately. No footage is to be uploaded.

## Startup feedback update — 2026-10-04

The user reported that Start seemed inactive on both platforms, then confirmed both work when held sideways. This is user-reported startup evidence, not endurance/extraction acceptance. A saved OnePlus metadata report read during diagnosis showed 462 encoded/input frames at 1280×720, ~29.25 fps over 16.5 wall-clock seconds, with 14 encoded intervals above 50 ms and no capture failures. This does not establish visible continuity. Start now checks landscape in the shared UI, requests Camera access, and places startup status/errors beside the controls. The live preview uses the [documented multiple-output capture-session pipeline](https://developer.android.com/media/camera/camera2/capture-sessions-requests), keeping the camera and encoder running continuously. Preview display/aiming and scroll/playback recovery require a new physical smoke check.

Preview update verification: Angular build, Android debug/test APK builds and JVM buffer/configuration checks passed. The two non-camera native extraction tests passed on the OnePlus (11.017 seconds). The updated app was installed successfully on the OnePlus. These checks do not exercise or establish live-preview orientation/visibility; use the updated short-check cases in the tester sheet. No new camera endurance test was run.

## Preview container crash — 2026-10-04

The user reported repeated OnePlus crashes and confirmed iPhone works. Android crash logs showed `ClassCastException: FrameLayout.LayoutParams cannot be cast to CoordinatorLayout.LayoutParams` when the preview was added to Capacitor’s CoordinatorLayout. The preview now supplies the actual parent’s layout-parameter type before attachment and rejects unsupported parents rather than attaching incompatible parameters. The corrected debug/test APKs built and were installed on OnePlus. A dedicated non-camera regression creates the preview in the real app parent and exercises layout/hide/show while retaining the surface. Its first execution could not create a preview surface because the phone was locked; window diagnostics showed screen-off/lock-screen state. That run was not a pass. After window diagnostics confirmed the phone was awake/unlocked, the rerun passed: `RecordingPreviewTest.previewSurvivesRealContainerLayoutAndHide`, one native test in 1.573 seconds. It verifies real-container layout traversal, surface creation, and surface retention through hide/show and repositioning. No endurance or camera preview correctness pass is implied.
