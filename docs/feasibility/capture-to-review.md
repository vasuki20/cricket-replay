# Offline capture-to-review integration — #14

Issue [#14](https://github.com/vasuki20/cricket-replay/issues/14), parent [#1](https://github.com/vasuki20/cricket-replay/issues/1), dependency [#13](https://github.com/vasuki20/cricket-replay/issues/13). Updated 2026-10-10, Asia/Singapore. **Integration implemented and automated checks pass; physical acceptance not run. Keep the issue open.**

## Implemented flow

Pair using the existing QR/authenticated local TCP session. Camera starts continuous foreground recording. Host measures eight clock exchanges and captures its review tap at native method entry, before the optional 0/2/5-second delivery delay. Camera extracts at the mapped tap while capture continues, exports an independent native file snapshot, and sends that MP4 through the existing session-scoped AES-GCM transfer engine. Angular owns the controls; video/file work stays native. There is no runtime backend, account, internet or computer requirement. Players decide; no umpiring is performed.

The encrypted offer identifies `media: recording`, the originating `reviewId`, SHA-256/size and bounded integer recording metadata. Host accepts a recording only for its currently pending request. The synthetic sample path remains available and is identified separately. Original `sourceFirstUs`, `sourceLastUs`, `requestedHostUs` (mapped Camera monotonic tap), `requestedSourceUs`, `endpointErrorUs`, frame count and retention/review configuration survive the transfer. The MP4 remains relative to zero: each inspected source timestamp is `sourceFirstUs + clip PTS`. No transcoding or frame interpolation occurs.

Receiving every byte is insufficient. Host checks SHA-256, one silent H.264 track, monotonic actual sample timestamps, frame count, zero origin and final sample PTS against source metadata, and decodes beginning/middle/end frames before publishing ready. Failed hashes, invalid media, mismatched metadata, stale request IDs and incomplete windows fail visibly. A file awaiting verification uses `.part.mp4` so AVFoundation identifies the format; it has no completed URL and cannot be played. Only after validation does it become the completed file.

Experiment availability gates reject a final frame more than 100 ms before the mapped endpoint, a frame after that endpoint, or any internal recorded interval exceeding 100 ms. This permits nominal 15 fps capture but deliberately rejects larger missing stretches instead of calling them ready. It is a conservative feasibility gate, not an accuracy guarantee or proof of visible continuity. The existing >50 ms diagnostics remain useful, particularly at 30 fps. Clock uncertainty still excludes drift, exposure timing and bridge latency. Decoding three frames does not establish every frame's visual quality.

Automatic host playback is checked by default. Angular polling adds up to roughly one second before asking the native player to start. `verifiedElapsedMs` measures native tap to verified host clip; `tapToPlayMs` records the first native player prepared/start callback for this review. It includes injected delivery delay, polling, decoder preparation and any user wait if automatic playback is disabled. It is not a measurement of the first pixel on the display. Compare the displayed seconds with the **≤30-second target** and separately observe when video becomes visible. Later replay does not overwrite the first timing.

Host playback supports 1×/0.5×/0.25× and first/last/previous/next inspection of recorded samples. A native media lease for received samples and reviews blocks replacement/new requests and cleanup while host playback/inspection owns the file. Camera sends an independent snapshot, so later recording extraction/restart/cleanup cannot truncate an in-flight file. One extraction/transfer runs at a time; received media is bounded to 32 MiB. Reception requires space for the full offer plus a 64 MiB reserve; write/finalization errors fail explicitly.

## Interruption and retry behavior

- Wi-Fi/session loss does not intentionally stop Camera's independent recorder. An active review/transfer fails; the partial received file is discarded. Actual capture continuity under network loss remains a physical check.
- Both platforms stop capture/session on background or lock. Return, restart/reconnect and explicitly start fresh capture when needed. The iOS interrupted encoder fix remains in place. The reported Android background-stop problem is unresolved until reproduced on the phone.
- Reconnect invalidates clock calibration. Retry means **measure clocks and request at a new tap**; bytes restart from zero. The old request is not silently remapped, resumed or represented by a previous good clip. Continued capture may retain the requested window; expired/unavailable windows fail.
- Process termination loses the active recorder/session. On a new native owner, stable private transfer/snapshot directories discard stale media; no ready state is restored from killed-process files. The existing recording report can still describe the prior interrupted run; this prototype does not recover an unfinished buffer. Starting a new experiment removes the previous recorder files.
- Close host playback/inspection, stop the session to cancel an active transfer, then use **Delete temporary samples and reviews** to remove received sample/review files. Stop capture before **Delete recording experiment**. The outgoing snapshot is removed on completion, cancellation or failed startup. Personal footage never leaves the paired phones.

## Evidence ledger

These categories must remain separate. Build/install success cannot substitute for real-phone flow evidence.

| Category | Check | Result for #14 |
| --- | --- | --- |
| Automated | Angular strict production build and native sync | Pass: final strict production build and synchronization for both platforms |
| Automated | Signed iOS Debug app | Pass: final signed Debug build |
| Automated | Android app/test APK and JVM tests | Pass: final app/test APK builds and five JVM tests |
| Automated | Swift authenticated clock/sample-transfer regressions | Pass: delayed review protocol, encryption/tamper/replay, three samples, interruption/reconnect/retry/cleanup |
| Automated | Swift integrated H.264 loopback | Pass during implementation: three generated review fixtures with 0/2/5-second delivery delay, exact source timing/sample inspection, playback event fixture, lease, unavailable window, late export after disconnect, recalibration/retry and hash-valid invalid MP4 rejection. Final rerun also passes native remux with 60/10 configuration, internal gap rejection and wrong mapped-tap rejection |
| Automated | Swift continuous recording suite | Pass during implementation: generated continuous VideoToolbox encoding, cross-file remux/decoded joins, frame stepping, interrupted encoder stop/restart, buffer eviction and cleanup |
| Automated | Swift low-storage/restart/metadata checks | Pass with injected zero capacity and generated files; not a real full-phone test |
| Automated | Android review/storage/frame assertions | Final test APK compilation passes; **not run**, no Android connected |
| User-reported | Prior mixed-phone pairing, synthetic transfer and recording/playback | Earlier reports apply to pre-#14 prototypes. No integrated-review or new #13 physical pass reported |
| Physical | #14 reviews, visible timing, outdoor/range, endurance and failure matrix | **Not run** |

Phone discovery on 2026-10-10: iPhone 15 Pro / iOS 26.3.1 (a), build 23D771330a available; iPhone 15 unavailable; no ADB phone connected. Java 21 runtime exists. The final signed #14 build installed successfully on iPhone 15 Pro; launch was attempted but blocked by the locked phone. Installation is not camera/review acceptance. Do not save device identifiers or credentials here. Only one Android phone is owned, so Android/Android requires borrowing a second phone even when OnePlus reconnects.

## Required real-device results matrix

Run at least three complete reviews for each row, with mobile data off and runtime cables disconnected. Record exact models/OS, network owner/type, indoors/outdoors, distance, configuration and error text. A failed network setup is a result, not a pass via a computer network.

| Host | Camera | ≥3 reviews / tap-to-play seconds | Short-range outdoor | Result / blocker |
| --- | --- | --- | --- | --- |
| OnePlus Android | Second Android | Not run | Not run | Second Android unavailable |
| iPhone 15 Pro | iPhone 15 (also swap when possible) | Not run | Not run | iPhone 15 unavailable in current discovery |
| OnePlus Android | iPhone | Not run | Not run | OnePlus not connected; phone-only verification pending |
| iPhone | OnePlus Android | Not run | Not run | OnePlus not connected; phone-only verification pending |

## Phone-only test procedure

Use the [simple phone sheet](../testing/phone-test-sheet.html): Works/Problem, six displayed playback timings, essential observations and exact errors. No JSON/report copying is required from a casual tester. Install both current builds first; the app header identifies P0-08. Camera permission and local-network permission must be granted as prompted. Keep Camera landscape, awake, foreground and aimed at a nonpersonal moving subject/visible timer. No microphone prompt is expected.

1. Turn mobile data off. Create a phone hotspot that works without cellular internet and join it from the other phone. The hotspot owner may be Host or Camera; record it. If iPhone/OxygenOS refuses hotspot in this state or routes incorrectly, mark that topology Problem with the exact behavior. An existing local Wi-Fi can help isolate app behavior, but does not prove phone-created offline networking.
2. Pair before recording. Start Camera with **120 / 20**, wait 25 seconds. On Host measure clocks, wait for eight samples, leave automatic playback on, request with no delay. Observe verified status/video, the displayed tap-to-play seconds, correct orientation, recent action and continued capture. Close playback before another request.
3. Repeat at least three reviews per pairing; measure before each. Include a **5-second delivery delay** and a visible one-finger → two-finger change at the tap. The ending should track the tap, not delivery. Try host frame stepping and 0.5×/0.25×; note unsupported decoder errors. Timing accuracy needs an independent visible reference; the finger check is qualitative.
4. Stop capture, change to **60 / 10**, restart and wait 15 seconds. Repeat three reviews, noting duration/latency/lead-in and any errors. Neither configuration establishes permanent device limits.
5. Repeat the pairings outdoors at a recorded short distance (for example 3–5 m, chosen by tester), with unobstructed view and then normal phone placement. Record range, hotspot owner, interruptions and visible tap-to-play. No physical range is assumed from loopback tests.
6. On each recording platform run **30 uninterrupted foreground minutes** with defaults; request/inspect at about 0:30, 2, 5, 10, 20 and ≥30 minutes. Note Works/Problem, continued counters, buffered seconds, storage/peak, battery, warmth and exact errors; observe moving action/timer across boundaries. A restarted session does not count as uninterrupted. Run the second configuration as a separate comparison. Keep footage on phones.
7. Exercise the failure rows below separately from uninterrupted endurance. After each, record connection/capture state, buffer availability on return/reconnect, retry outcome and whether any incomplete footage was offered. Finish with stop and cleanup.

| Failure | Phone-only action | Observe and record |
| --- | --- | --- |
| Wi-Fi loss, capture remains foreground | Disable the hotspot from the other phone during a request/send. Return its app and restore networking. Avoid leaving Camera to isolate network loss | Explicit failure/partial discarded; Camera counters/buffer before/after; reconnect/manual connect, recalibrate, new tap retry. Settings on Camera is a separate background test |
| Host Home/lock | Leave or lock Host during extraction/transfer; return | Session stopped; no false ready. Restart host, reconnect Camera manually if still recording, recalibrate and retry; note retained buffer |
| Camera Home/lock | Leave or lock Camera during capture/request; return | Capture/session visibly stopped/interrupted; tail availability disclosed; explicit fresh Start and pairing/review recovery |
| Process termination, both roles | Force-close/swipe away or Android Force stop, then relaunch | No automatic capture or recovered ready transfer; stale partial cleanup; old buffer not silently claimed available; pair/start/review again |
| Low storage | Use a spare test phone already low on space; do not fill personal storage merely for this test | Explicit storage/start/write error; no ready partial; free space and fresh retry. If no suitable device, mark not run. Injected developer tests are separate |
| Unavailable/expired footage | Request before enough capture; leave delivery delay longer than a short retained window only if a developer fixture is available, otherwise record the early-window result | Clear unavailable message, no previous successful clip offered as this request. Wait for enough capture and make a new tap |
| Cleanup | Close playback/inspection; stop session/capture; delete temporary samples and recording experiment | No playable/inspectable received clip or camera clip afterward; fresh pairing/recording/review works |

To reconnect while Camera keeps recording, use the existing manual address/secret/port fields retained on Camera. QR scanning deliberately refuses to compete with active rear-camera capture. Starting a new Host session creates a new secret; update manual fields from Host or stop capture to scan, and report the resulting buffer loss. Mere peer loss leaves Host's listener/secret available; Camera can reconnect without restarting Host.

## Reproducible developer checks

```sh
npm run sync:ios
npm run sync:android
JAVA_HOME=/private/tmp/cricket-jdk21/jdk-21.0.12.1+1/Contents/Home \
  android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath /private/tmp/cricket-replay-derived build
xcrun swiftc ios/App/App/LocalSession.swift ios/App/App/PairingCode.swift \
  ios/App/App/SampleTransfer.swift tests/ConnectivityTests.swift -o /private/tmp/cricket-connectivity-tests
/private/tmp/cricket-connectivity-tests
xcrun swiftc -swift-version 5 ios/App/App/LocalSession.swift ios/App/App/PairingCode.swift \
  ios/App/App/SampleTransfer.swift ios/App/App/SampleVideo.swift ios/App/App/RecordingBuffer.swift \
  ios/App/App/RecordingClip.swift tests/ReviewFlowTests.swift -o /private/tmp/cricket-review-flow-tests
/private/tmp/cricket-review-flow-tests
xcrun swiftc -swift-version 5 -D RECORDING_TEST ios/App/App/RecordingBuffer.swift \
  ios/App/App/RecordingClip.swift ios/App/App/RollingRecording.swift ios/App/App/SampleTransfer.swift \
  tests/RecordingTests.swift -o /private/tmp/cricket-recording-tests
/private/tmp/cricket-recording-tests
xcrun swiftc -swift-version 5 ios/App/App/SampleTransfer.swift ios/App/App/SampleVideo.swift \
  tests/TransferTests.swift -o /private/tmp/cricket-transfer-tests
/private/tmp/cricket-transfer-tests
```

Discover devices afresh with `adb devices -l` and `xcrun devicectl list devices`. Install Android app/test APKs using `adb -s <device> install --no-streaming -r <apk>`; keep OnePlus unlocked. Android `ReviewFlowTest` runs two endpoints on one phone's Wi-Fi address with generated media; `TransferTest` adds injected storage/metadata/restart gates. These are automated native tests, not any of the four pairings. Run the instrumented suite only on the intended phone and preserve earlier manual evidence first. No instrumented #14 pass exists yet.

Official pipeline references: [Apple AVPlayerItem status](https://developer.apple.com/documentation/avfoundation/avplayeritem/status-swift.enum), [Android player prepared callback](https://developer.android.com/reference/android/media/MediaPlayer.OnPreparedListener), [Apple available volume capacity](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacitykey), and [Android File usable space](https://developer.android.com/reference/java/io/File#getUsableSpace()). These inform preparation/storage checks; none proves on-device timing or offline hotspot availability.

## Draft issue summary

Integrated requested recording clips with encrypted local transfer and verified Host playback/frame inspection; original Camera timestamps and mapped tap context survive. Shared UI displays tap-to-verification and tap-to-native-playback timings, defaults to automatic playback, and keeps synthetic samples separate. Failure/reconnect/cleanup behavior and phone-only instructions are documented here. Automated/build/install evidence and not-run physical criteria remain separated. All four physical pairings, outdoor tests, 30-minute endurance on each recording platform, actual low-storage/lifecycle behavior and ≤30-second visible playback evidence remain outstanding. A second Android phone is required. Keep #14, #13 and the parent epic open. No personal footage or credentials are attached.
