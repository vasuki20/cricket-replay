# P0-03: Offline phone-hosted connection

Issue: [#9](https://github.com/vasuki20/cricket-replay/issues/9). Updated 2026-10-04 (Asia/Singapore).
Status: iOS experiment implemented and build-tested; shared-Wi-Fi QR pairing and peer ping **pass by user report** on the two iPhones. Android connectivity implementation and verification are deferred under the agreed iPhone-first sequence.

## Architecture and limits

User-requested scope update on 2026-10-04: move QR pairing into this iPhone experiment because manual secret entry made testing difficult. Host now starts with a fresh generated secret and displays a QR code; the camera scans it and connects automatically. Manual entry remains under **Manual connection options**. QR includes a versioned Replay marker, private IPv4 address, port and session secret, generated locally with Core Image and scanned with AVFoundation. Invalid payloads/versions, non-local endpoints and invalid ports/secrets are rejected; camera denial, cancellation and interruption return visible errors. No third-party QR service or dependency is used. Android scanning remains deferred.

### Quick QR test

1. Keep both phones on the same Wi-Fi with mobile data off. Open the updated app on both.
2. Host phone: **Host → Start host & show QR**. Wait for **listening** and the code. If multiple addresses appear, select the Wi-Fi interface (normally en0); another candidate may be needed for hotspot tests.
3. Other phone: **Camera → Scan host QR & connect**. Allow camera access and point at the host screen. Allow Local Network access if prompted.
4. Confirm **Peer authenticated: Yes** on both, then tap peer ping/status on each.
5. Test Cancel, an unrelated QR, denied camera permission, and rescanning after stop/restart. Reversing phone roles still needs verification. The code carries the session secret, so do not include it in published screenshots/results.

QR-payload validation and existing connection regression tests pass; signed iOS and Angular builds pass. Physical QR scanning and two-phone pairing remain unverified until observed.

Follow-up user evidence on 2026-10-04: after the four-step QR test (host starts/shows code; camera scans/connects; authentication confirmation; peer ping), the user reports “all done” and “working properly.” Record QR scan/pairing and peer ping as **user-reported PASS** on the shared Wi-Fi setup with mobile data off. Exact timings, individual counters and role reversal were not supplied. Camera denial/cancel, unrelated QR, real-phone wrong-secret rejection, Wi-Fi interruption, lock/background behavior and offline hotspot creation remain unverified. Do not extend this smoke-test result to those checks or to Android.

The final QR-enabled signed build was installed and launched on both connected iPhones via CoreDevice on 2026-10-04. Their installed bundle identifier is `com.aadhinitinytales.cricketreplay`, matching the user's updated signing configuration. Camera-based scanning and peer authentication still need the user's on-screen test.

A native `NWListener` runs on the host phone, using a manually entered TCP port (default 8765). Camera initiates `NWConnection` to a manually entered private/link-local IPv4 address. Both directions share that connection. Cellular interfaces are prohibited. Host displays IPv4 interface candidates from Wi-Fi/hotspot interfaces; it does not assume a fixed hotspot gateway or select the correct candidate automatically. IPv6 and automatic discovery are outside this spike; QR pairing was added at the user’s request.

Network creation/joining is manual in phone settings. The app does not create or configure a hotspot. Native status snapshots report listener/connection/authentication state, received requests/replies and monotonic round-trip timing. Ping and status requests receive authenticated acknowledgement messages; status confirms peer readiness, not recording capabilities. Capture and video transfer are not implemented by this ticket.

Local Network permission is triggered by actual outgoing traffic. Listening alone does not establish permission approval. The app declares `NSLocalNetworkUsageDescription`; there is no invented permission boolean and no Bonjour/multicast entitlement. Waiting/failure text asks users to inspect Settings rather than treating every network error as permission denial. See [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

On iOS background entry, the app closes listener/connection and clears native authentication state. Foregrounding requires explicit restart/reconnect. No unrestricted background hosting is claimed. A disconnected host keeps its listener for a new camera attempt while foreground. Handshake/connect attempts time out after 20 seconds; unanswered ping/status requests time out after eight seconds. One camera connection is accepted at a time, with at most four outstanding requests. Diagnostic newline-delimited JSON frames are limited to 2048 bytes; #10 allows authenticated encrypted transfer frames up to 65536 bytes. Oversized/invalid messages terminate the peer.

## Pairing protection decision for this spike

Use a generated 128-bit random secret, displayed only when the host reveals it for manual entry. It is not sent over the connection or persisted to disk. Each connection has fresh nonces; both peers prove knowledge of the secret using CryptoKit HMAC-SHA256, then exchange an authenticated ready confirmation. Every subsequent message authenticates protocol version, sender/receiver nonces, direction, ordered sequence number, message type and request ID. Wrong secret, reflected proof, replay, sequence mismatch or message alteration terminates the peer. This is an experiment protocol, not an audited production pairing system.

**Diagnostic traffic is authenticated but not encrypted.** The subsequent [#10 sample transfer experiment](transfer.md) uses protocol version 2 with encrypted video packets, separate directional session keys, and ciphertext covered by the frame HMAC. Install the updated build on both phones. There is no global TLS-validation bypass, trust-all certificate callback or ATS relaxation. HMAC is provided by [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit/hmac), transport by [Network.framework](https://developer.apple.com/documentation/network/nwconnection).

Production decision is pending: investigate a reviewed encrypted transport with scoped peer trust/pairing, including pinned TLS identity or compatible TLS-PSK support on both platforms. Confirm actual interoperability, provisioning/entitlement requirements and protection against active interception before production footage transfer. #10 encrypts synthetic sample packets for its bounded experiment; this does not settle the production transport decision. The status-only HMAC implementation does not establish production transport security or eliminate the Android implementation requirement.

## iPhone hotspot assumption: explicit risk

[Apple's Personal Hotspot guidance](https://support.apple.com/en-us/111785) says hotspot uses cellular data, needs a supporting carrier, and advises enabling Cellular Data when hotspot is unavailable. Thus a SIM/service-free iPhone hotspot with mobile data disabled is **not established** and may block the product's proposed host setup. Do not enable mobile data and call that an offline-constraint pass.

First test the requested setup exactly. If hotspot cannot be created/retained with data disabled, record the failure and phone/SIM/carrier state. Bounded alternatives: test a shared Wi-Fi network with no internet to isolate service interoperability; later test an Android-provided local hotspot. Shared external Wi-Fi only proves the connection service and changes the network-creation assumption; it does not satisfy phone-only hotspot creation. Any changed assumption needs review at the P0 exit gate.

## Build/install

```sh
npm ci
npm run sync:ios
npm run open:ios
```

Rebuild/install **this updated app on both iPhones** using Xcode signing. The older #8 build has no connection service. Keep signing account configuration local. See [harness guide](harness.md).

## Manual two-phone procedure

1. Record both model/OS versions, SIM/service availability and initial permission state. Set mobile data off on both phones. Try to create Personal Hotspot on the host and join from the camera. Record whether creation/joining works, whether it requires mobile data/service, and whether disabling data subsequently drops the hotspot. If this fails, record a failure before trying the no-internet shared-Wi-Fi fallback.
2. Open both apps foreground. Host: select **Host**, **Generate secret**, reveal/copy the secret manually and **Start host**. Record the displayed address candidates and listener startup duration. The secret differs from the Wi-Fi hotspot password; do not save it in public results.
3. Camera: select **Camera**, enter a candidate host IP (only the numeric address), matching port and secret, then **Connect camera**. Approve Local Network access when prompted. Record connection duration and states. Try another displayed candidate if needed; record which interface actually works. Do not assume 172.20.10.1.
4. Verify **Peer authenticated: Yes** on both. Tap **Send peer ping** and **Request peer status** on each phone; verify replies, opposite received counters and round-trip values. Record at least three attempts. No computer/server participates.
5. Camera: stop, enter a deliberately different valid 32-character hex secret and reconnect. Verify neither side becomes authenticated and the failure is visible. Host should still accept a subsequent correct-secret retry. Stop clears the input, so copy the host secret again.
6. Toggle camera Local Network access off in **Settings → Privacy & Security → Local Network**. Reconnect and record waiting/failure; re-enable and retry. A settings trip backgrounds/stops the app, so explicitly restart host if testing host settings too. A host-only listener may never trigger a permission prompt; record that rather than claiming permission is granted. If repeating first-use prompts, reinstall the app as described by Apple's technote.
7. Interrupt Wi-Fi, observe the states and then reconnect manually. Send a ping to detect an otherwise idle broken TCP connection. Record failure-detection/reconnect durations and whether network recreation is needed.
8. Background/lock host and camera separately. Confirm stopped/interrupted status after returning and explicitly restart/reconnect. Repeat with roles reversed (iPhone 15 as host and Pro as camera), recording differences.

## Real-device matrix

| Host → camera | Devices / OS | Network, data/SIM state | Result | Limitations / evidence |
| --- | --- | --- | --- | --- |
| Android → Android | Not identified | Not run | NOT RUN | Phones, Android build toolchain and connectivity implementation deferred |
| iPhone → iPhone | iPhone 15 Pro: previously reported iOS 26.3.1 (a); iPhone 15: queried iOS 26.6 | Shared Wi-Fi, mobile data off (user confirmed); Wi-Fi internet availability not verified; hotspot not run | USER-REPORTED PASS for QR pairing/authentication and peer ping | Exact timings and role reversal pending; interruptions and hotspot creation unverified |
| Android → iPhone | Android pending; iPhone candidates above | Not run | NOT RUN | Deferred |
| iPhone → Android | iPhone candidates above; Android pending | Not run | NOT RUN | Deferred |

For each real test append: date, model/OS, host/camera roles, network setup and interface/address used, mobile-data state, SIM/service dependency, permissions, three connection/ping timings, wrong-secret result, interruption/lifecycle observations and pass/fail with limits. Do not publish personal identifiers or session secrets.

## Code verification on 2026-10-04

Latest update: user reports installation on both iPhones succeeded after switching to a new Apple developer account. The earlier registration-limit blocker below is resolved for installation. Physical peer authentication, ping/status, wrong-secret rejection and interruption results are still awaiting manual verification; successful installation alone does not prove connectivity.

Both phones were connected and selectable in Xcode. Vasuki's iPhone is an iPhone 15 running iOS 26.6 (23G71), with Developer Mode and developer disk-image services enabled. A signed generic iOS build passed. Building specifically for the iPhone 15 failed because Apple reported the development team had reached its registered-iPhone limit; its provisioning profile does not include this phone. Therefore two-phone connectivity is blocked by signing, not proven or failed by a network test. Resolve registration or use another eligible signing team before testing. Personal identifiers and profile contents are not stored here.

The updated signed app was installed and launched successfully on Karthik's iPhone via CoreDevice. User confirms both phones are on the same Wi-Fi network with mobile data off. Peer connection/ping has not run because the second phone still cannot install the app. This network setup would test service interoperability; it does not prove phone-hosted hotspot creation.

- Angular production build, strict templates, TypeScript checking and iOS project/plist syntax: pass.
- Unsigned full iOS Debug build with Xcode: pass. This does not prove phone behavior.
- Native implementation compiled and tested on macOS loopback: pass for bidirectional ping/status, reconnect using the same host secret, wrong-secret rejection on the wire, and stop. Authentication tests also reject replay, altered message type, cross-connection replay and reflected proof.

Reproduce the native tests (requires macOS Network.framework/CryptoKit):

```sh
xcrun swiftc ios/App/App/LocalSession.swift ios/App/App/PairingCode.swift ios/App/App/SampleTransfer.swift tests/ConnectivityTests.swift \
  -o /private/tmp/cricket-connectivity-tests
/private/tmp/cricket-connectivity-tests
```

These loopback checks use a computer solely for development verification. They are not any entry in the real-phone results matrix. #9 remains open pending actual pairings, Android implementation and the transport/hotspot findings.
