# Android encrypted sample transfer

Continuation of [#10](https://github.com/vasuki20/cricket-replay/issues/10). Updated 2026-10-04.
Android uses the same Angular controls and Capacitor methods as iOS: generate, send, progress/status, play verified sample, and delete temporary samples. Physical Android/iPhone transfer and playback pass by user report in both host directions.

## Native implementation

Kotlin mirrors iOS's acknowledged transfer state machine: fresh UUID per request, 1–32 MiB offer with SHA-256, one bounded 16 KiB chunk in flight, exact offset acknowledgements, end marker, checksum verification and completed-file receipt. The host writes `.part` files in app-private cache; only verified, renamed `.mp4` files are eligible for native playback. Receiving 100% of bytes alone is insufficient. Invalid sizes, IDs, offsets, ciphertext or checksum fail the peer and delete partial files. A 30-second inactivity timeout, explicit stop, detected disconnect and backgrounding cancel active transfers. Reconnect/retry starts from byte zero; slow mode delays chunks by 0.5 seconds for interruption testing. Successful attempts retain request ID, bytes, elapsed seconds and decimal MB/s, with the same timing definitions as [the iOS experiment](transfer.md).

AES-GCM uses Android's platform crypto provider with 12-byte random nonces and 128-bit tags, packaged as nonce/ciphertext/tag to match CryptoKit. Directional AES-256 keys use the same HKDF-SHA256 secret/nonces/label derivation; request ID is associated data. The outer ordered HMAC covers the ciphertext. Authenticated transfer frames have a 64 KiB limit; diagnostics remain capped at 2 KiB. No TLS bypass or ATS change is involved. This remains a synthetic-video experiment with the custom protocol's previously documented production/forward-secrecy limits.

[MediaCodec](https://developer.android.com/reference/android/media/MediaCodec) and [MediaMuxer](https://developer.android.com/reference/android/media/MediaMuxer) generate 600 frames of 640×360 H.264 video at 30 fps, approximately 20 seconds, without audio. Flexible YUV input image planes are filled using their actual row/pixel strides. The Android sample is grayscale with a moving ball and per-second ticks; the iPhone's synthetic sample is colored. Unsupported encoders/layouts and encoding timeout produce visible errors and remove failed output. No real camera footage or microphone permission is used. Generation runs off the UI thread, before transfer timing begins, and subsequent sends reuse the same generated file.

Completed local files play through VideoView/MediaController in a full-screen native dialog. This keeps the main Activity foreground during playback; stopping/locking the app dismisses playback and stops the session. Preparation failures/timeouts are surfaced. Close playback before cleanup. File paths and bytes stay in Kotlin; Angular receives metadata only. Cleanup removes generated and received cache files and resets successful-attempt history; files are not saved to Photos or public storage. New incoming transfers replace the previous received sample.

## Development checks

OnePlus CPH2465, Android 14 / OxygenOS 14.0: final instrumented run reports **OK (6 tests)**. The updated APK was installed successfully and launched after testing.

- Angular and Gradle app/test builds pass.
- Three encrypted transfers between native endpoints on the same phone's Wi-Fi address pass, with exact bytes, checksum gating and timing/history; interrupted partial file cannot be played; reconnect/retry and cleanup pass.
- Corrupt SHA-256, out-of-order chunks and oversized offers are rejected and partial files removed.
- Actual Swift/CryptoKit ciphertext decrypts on Android in both directions. Android-generated fixture ciphertext independently decrypts to the expected packets in CryptoKit. Modified request ID/tag and cross-session ciphertext are rejected.
- Generated MP4 metadata and decoded frames pass: approximately 20 seconds, 640×360, no audio, visible motion/progress. Native VideoView preparation/start passes on the unlocked OnePlus. The test releases frame-inspection decoder resources before opening playback and keeps only its temporary Activity window awake; it does not change system settings.

These are development checks, not physical Android/iPhone transfer evidence. Public test-fixture secrets are not real pairing credentials. Native UI tests require the OnePlus unlocked with its screen on; a locked-screen run cannot establish visible playback. Earlier playback tests failed while the display was locked or decoder resources were retained; releasing the inspection decoder and running with the display awake resolved the test. The subsequent two-phone procedure passed by user report; exact measured durations and throughput were not supplied.

## User-reported physical result

On 2026-10-04, after the requested test (iPhone host/OnePlus camera generate/send/verify/play, three attempts, reverse roles, then interrupted slow transfer/reconnect/retry), the user reports “All done. Tested, looks good.” Record **USER-REPORTED PASS** for mixed-phone transfer/playback in both directions and interruption/retry. Exact bytes, elapsed seconds, throughput, individual checksum observations, and the iPhone model/OS used were not supplied. Shared Wi-Fi/mobile-data-off was the requested setup; network/data state was not independently reconfirmed for this run. Separate background/Wi-Fi-loss, explicit cleanup, hotspot creation, and Android-to-Android checks remain unverified. Do not infer iPhone-to-iPhone transfer evidence from this mixed-phone result.

## Two-phone test

1. Keep OnePlus and an updated iPhone unlocked, both apps foreground, on the same Wi-Fi with mobile data off. Pair using QR.
2. **iPhone host / OnePlus camera:** OnePlus generates a sample and sends it. iPhone waits for **ready / checksum verified**, then **Play verified sample**. Confirm approximately 20 seconds, moving ball and ticks. Close playback and repeat for three normal attempts; record bytes, seconds and MB/s.
3. Stop sessions and reverse roles: **OnePlus host / iPhone camera**. Generate/send from iPhone, then verify/play on OnePlus. Repeat three times and record measurements.
4. Enable slow mode on the camera, send, and stop the session midway. Host must show failed, unverified checksum and disabled playback. Reconnect, disable slow mode, resend, and verify a fresh request ID and working playback. Separately test app backgrounding and Wi-Fi loss.
5. Close playback and stop active transfers, then **Delete temporary samples** on both. Confirm camera sample disappears, host returns to idle and playback is disabled.

| Host → camera | Three attempts / playback | Interruption / retry | Status |
| --- | --- | --- | --- |
| iPhone → OnePlus | User-reported pass; numerical measurements not supplied | User-reported pass for requested slow-transfer retry | USER-REPORTED PASS |
| OnePlus → iPhone | User-reported pass; numerical measurements not supplied | Role-specific interruption details not supplied | USER-REPORTED PASS |
| Android → Android | Second Android phone needed | Pending | NOT RUN |

Shared Wi-Fi does not prove phone-only hotspot creation or no internet; record network/data state and hotspot tests separately. Record exact models/OS and host/camera roles. Do not include QR codes/secrets in published results.

## Reproduce development checks

Build/install both app and instrumented-test APKs using the [Android connectivity instructions](android-connectivity.md), then run all test classes:

```sh
adb -s <device> shell am instrument -w -r \
  com.aadhinitinytales.cricketreplay.test/androidx.test.runner.AndroidJUnitRunner
```

The tests require Wi-Fi and an unlocked display. To independently verify Android-generated public fixture ciphertext on macOS:

```sh
adb -s <device> exec-out run-as com.aadhinitinytales.cricketreplay \
  cat cache/android-transfer-test-output.json > /private/tmp/android-transfer-test-output.json
xcrun swiftc tests/VerifyAndroidCipher.swift -parse-as-library -o /private/tmp/cricket-verify-android-cipher
/private/tmp/cricket-verify-android-cipher /private/tmp/android-transfer-test-output.json
```

Launch Replay Feasibility after the test runner finishes before manual two-phone testing. The user authorized committing and pushing the implementation after reporting successful physical testing.
