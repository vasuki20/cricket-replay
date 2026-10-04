# Android connection and QR pairing

Continuation of [#9](https://github.com/vasuki20/cricket-replay/issues/9), which is currently closed on GitHub. Android was previously deferred; mixed-phone QR pairing and ping/status now pass by user report; detailed edge-case evidence remains pending. Updated 2026-10-04.

## Implemented

The shared Angular screens and Capacitor contract now support Android host/camera roles, private IPv4 manual connection, local QR generation and scanning, generated 128-bit pairing secrets, authenticated ping/status, counters, and round-trip timing. Kotlin uses the same protocol-v2 HMAC transcript, roles, connection nonces, ordered sequence numbers, and request IDs as Swift. Both installed apps must support version 2. Wrong secrets, replay, reflection, changed payloads, malformed handshakes and unexpected responses fail the peer. Diagnostic messages remain authenticated but unencrypted; The subsequent [Android transfer implementation](android-transfer.md) adds encrypted packets and enables the shared video controls; mixed-phone transfer/playback and interruption/retry now pass by user report.

Android camera sockets are bound to an available non-VPN Wi-Fi `Network`, including Wi-Fi without internet; cellular fallback is not used. See [Android Network.bindSocket](https://developer.android.com/reference/android/net/Network#bindSocket(java.net.Socket)). Host address candidates come from active private IPv4 addresses on wlan/ap/swlan/wifi interfaces. The listener checks each accepted socket's local interface and private peer address before starting authentication. Other interfaces are rejected. Interface names outside these prefixes and IPv6 are unsupported in this experiment. Hotspot creation/joining remains manual; no fixed gateway is assumed.

Serial state processing is separate from blocking connection, accept, read and write operations. One camera, four outstanding requests, bounded 2 KiB diagnostic frames (64 KiB for authenticated encrypted transfer frames), and a bounded writer queue are supported. Connection/authentication times out after 20 seconds; unanswered ping/status after eight seconds. Foreground hosting only: Activity stop closes the connection/listener, clears authentication and cancels pending requests. Foregrounding requires explicit restart/reconnect. Scanner cancellation, timeout, denied camera access, or an unrelated QR returns a visible error; retry scanning. No microphone, storage, Nearby Wi-Fi Devices, discovery or hotspot-creation runtime permission is requested.

QR decoding/encoding uses pinned [ZXing Android Embedded 4.3.0](https://github.com/journeyapps/zxing-android-embedded) under Apache 2.0. The scanner runs inside this app via Capacitor's Activity Result callback, requires no separate scanner app, and stores no barcode image. Payload validation matches iOS: Replay marker/version, canonical private/link-local IPv4, port 1024–65535, and 32 lowercase hex secret characters, at most 1024 UTF-8 bytes. QR secrets remain in memory and must not be published in screenshots/logs.

## On-device development evidence

OnePlus Nord CE 3 Lite 5G (CPH2465), Android 14 / OxygenOS 14.0: Angular build and Gradle app/test builds pass. The final app/test APKs were installed with ADB; the final instrumented run reports **OK (3 tests)**, and the pairing app was launched afterward. Native instrumented tests pass for:

- Actual Swift-generated HMAC fixtures in both roles; Android-generated HMAC matching Swift output; payload alteration, replay and reflection rejection.
- Pairing payload round-trip; unrelated/unsupported QR, invalid secret/port, public IP, Unicode/ambiguous/malformed IPv4 rejection.
- Two native endpoints on the **same OnePlus's Wi-Fi address**: mutual authentication, bidirectional ping/status, measured round-trip, reconnect, wrong-secret failure, and stop.

The fixture secret is public test data, not a real pairing credential. These tests prove native code behavior on Android and protocol transcript compatibility; they do not prove physical camera scanning, two-phone network interoperability, phone-only hotspot creation, or real background/permission edge cases.

## User-reported two-phone result

On 2026-10-04, after the requested four-step smoke test (iPhone hosts/OnePlus scans, authenticated ping/status on both, then reverse roles), the user reports “done. it is working.” Record both mixed host/camera directions as **USER-REPORTED PASS** for QR pairing, authentication and ping/status. The procedure requested shared Wi-Fi with mobile data off; exact network/data state, iPhone model/OS, counters and round-trip values were not independently supplied for this run. Three measured retries, permission denial/regrant, wrong-secret rejection on two phones, lock/background interruption and hotspot creation remain unverified. This result does not establish Android video transfer or Android-to-Android behavior.

## Two-phone procedure

1. Keep OnePlus and an updated iPhone unlocked, both apps foreground, on the same Wi-Fi with mobile data off. Record OS versions, data state, and whether the Wi-Fi has internet. For a strict no-internet check use an isolated Wi-Fi network; shared-router success does not prove hotspot creation.
2. iPhone **Host → Start host & show QR**. OnePlus **Camera → Scan host QR & connect**. Allow camera access if prompted. Confirm authenticated on both, and send ping/status in both directions. Repeat reconnect three times and record round-trip values.
3. Stop both sessions and reverse roles: OnePlus hosts/shows QR; iPhone scans/connects. If multiple addresses appear, select the Wi-Fi interface that the other phone can reach.
4. Camera: stop and use Manual connection options with the host address/port and a deliberately different valid secret. Confirm rejection, then scan the correct host QR to retry. Do not record the real secret in results.
5. Cancel scanning, scan an unrelated QR, deny/regrant camera permission, disable Wi-Fi, and lock/background each phone separately. Confirm failures are visible, authentication is cleared, and restart/reconnect works. Ping an idle connection to detect a broken network.
6. Separately test OnePlus-created hotspot with mobile data off and iPhone joined. Record whether creation/retention needs SIM/carrier/data and whether disabling data drops the hotspot. Reverse network hosting only if the iPhone supports the exact offline setup; its known Personal Hotspot restriction remains unresolved. Do not call a cellular-enabled setup an offline pass.

| Host → camera | Status | Evidence needed |
| --- | --- | --- |
| iPhone → OnePlus | USER-REPORTED PASS: QR/authentication/ping/status | Exact iPhone model/OS, network/data confirmation, three timings, lifecycle/retry |
| OnePlus → iPhone | USER-REPORTED PASS: QR/authentication/ping/status, reversed roles | Detailed timings and edge cases pending |
| Android → Android | NOT RUN | Second physical Android phone |
| iPhone → iPhone | Earlier user-reported QR/ping pass | Detailed timings/edge cases remain pending in connectivity.md |

## Reproduce

```sh
npm run sync:android
cd android
# Current temporary Java runtime; configure a durable Java 21 installation for later builds.
JAVA_HOME=/private/tmp/cricket-jdk21/jdk-21.0.12.1+1/Contents/Home ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
# ADB is under ~/Library/Android/sdk/platform-tools; select the physical device explicitly.
adb -s <device> install --no-streaming -r app/build/outputs/apk/debug/app-debug.apk
adb -s <device> install --no-streaming -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s <device> shell am instrument -w -r -e class com.aadhinitinytales.cricketreplay.ConnectivityTest \
  com.aadhinitinytales.cricketreplay.test/androidx.test.runner.AndroidJUnitRunner
```

The on-device connection test requires the phone to be joined to Wi-Fi. It uses no computer/server endpoint. Running tests launches the test process and may replace the foreground app; launch Replay Feasibility afterward before manual pairing.
