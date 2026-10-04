# P0-04: Generated MP4 transfer

Issue: [#10](https://github.com/vasuki20/cricket-replay/issues/10). Updated 2026-10-04.
Status: iOS implementation and development checks pass. Android encryption, transfer, sample generation and native playback are now implemented; see [Android transfer checks](android-transfer.md). Mixed Android/iPhone transfer/playback in both host directions and interrupted-transfer retry pass by user report; numerical measurements and other physical checks remain pending. A second Android phone is still unavailable.

## Two-phone test

Install this build on **both** phones; protocol version 2 rejects older connection builds. Keep both apps foreground on the same Wi-Fi, with mobile data off. A shared router does not establish phone-only hotspot feasibility or prove its internet connection is disabled.

1. Host: **Start host & show QR**. Camera: **Scan host QR & connect**. Confirm authentication on both.
2. Camera: **Generate 20-second sample**, then **Send sample to host**. Generation runs separately from the transfer timer and reuses the sample for subsequent attempts.
3. Host: wait for **ready**, checksum **verified**, then **Play verified sample**. Confirm playback runs for approximately 20 seconds, with a moving yellow ball and one new tick per second. Close the player.
4. Repeat sending and playback for three normal attempts. Each phone retains the last ten successful attempt measurements: request ID, payload bytes, elapsed seconds, and decimal MB/s. Report the three rows and any playback error. Sender timing includes the host verification receipt; receiver timing ends after checksum verification and file rename. Payload throughput excludes framing/encryption overhead.
5. Camera: enable **Slow transfer for interruption test**, send again, and **Stop session** while receiving. Host must show failed, checksum pending, and disabled playback. Reconnect using the host QR (or restart host if it was stopped), disable slow mode, and retry. Confirm a new request ID and successful playback. Also try backgrounding one app mid-transfer; returning requires explicit restart/reconnect.
6. After playback closes and transfers stop, tap **Delete temporary samples** on both phones. Camera should show no generated sample; host returns to idle with playback disabled. Attempt history is cleared by cleanup.

| Pairing | Attempts 1 / 2 / 3 | Playback | Interruption / retry | Status |
| --- | --- | --- | --- | --- |
| iPhone 15 Pro ↔ iPhone 15, shared Wi-Fi | Pending: bytes, seconds, MB/s | Pending | Pending | NOT RUN |
| Android ↔ Android | Pending; second phone needed | Pending | Pending | NOT RUN |
| Android ↔ iPhone, either host role | User-reported pass; timings not supplied | User-reported pass | Requested slow-transfer retry passes by user report | USER-REPORTED PASS |

Record host/camera roles, model/OS versions, network setup, data state, and results; reversing iPhone roles is a separate check. Do not include QR secrets in shared evidence. Computer loopback results below are development checks, not phone results.

## Implementation

Native AVAssetWriter generates a silent 640×360 H.264 MP4 with 600 frames at 30 fps. It requests no capture permission and uses no personal footage. Native paths and bytes remain in Swift; Angular receives metadata and progress only. AVPlayerViewController plays a completed local URL.

One camera sends one file at a time over the authenticated Network.framework TCP connection. A fresh UUID identifies each transfer. The host accepts an offer of 1–32 MiB with a SHA-256 digest, writes bounded 16 KiB chunks to an app-owned `.part` file, and acknowledges each offset. A single acknowledged chunk is in flight. Receipt of all bytes alone does not enable playback: an end marker, exact length, and streaming SHA-256 verification must succeed before renaming to `.mp4`. The camera waits for the host's verified-completion receipt. This is completed-file transfer, not streaming playback, capture, buffering, or review extraction.

Invalid offsets, request IDs, sizes, ciphertext, and checksum terminate the peer and remove partial files. An inactive transfer times out after 30 seconds. Explicit stop, app backgrounding, and detected disconnect cancel the transfer. Retry starts from byte zero with a fresh request ID; resumable transfer is outside this experiment. Slow mode delays each data chunk by 0.5 seconds solely to make interruption testing practical. New transfers replace the previous received sample; cleanup deletes the current generated/received temporary files. iOS also manages the temporary directory; files are not added to Photos or persisted as product recordings.

### Transport protection

Version 2 retains mutual HMAC authentication and ordered frame sequences. Transfer offers, chunks, acknowledgements, and completion receipts are additionally encrypted with [CryptoKit AES-GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm). Direction-specific 256-bit keys are derived with HKDF-SHA256 from the random QR pairing secret, both fresh connection nonces, and a protocol/direction label. CryptoKit generates per-packet nonces; the request ID is authenticated associated data, and the outer HMAC covers the ciphertext. Cross-session/direction key separation and ordered authenticated frames reject replay. Status/ping diagnostics remain unencrypted. Authenticated transfer frames are bounded to 64 KiB; other frames remain bounded to 2 KiB.

This permits the synthetic video experiment without putting video bytes onto the diagnostic channel in plaintext. The custom protocol is not an audited production transport, has no forward secrecy, and does not establish Android interoperability. A reviewed cross-platform transport and pairing design remains a production prerequisite. No TLS validation bypass or ATS relaxation is introduced.

## Development checks

Passed on 2026-10-04: Angular production build; signed iOS Debug build; three encrypted loopback transfers with exact bytes, checksum gating, duration/throughput history, interrupted partial deletion, reconnect/retry, and explicit cleanup; AES-GCM corruption/request-ID rejection; authentication regressions; direct engine checksum/out-of-order/oversize rejection; generated MP4 playable with 20-second duration and no audio track on macOS.

```sh
xcrun swiftc ios/App/App/LocalSession.swift ios/App/App/PairingCode.swift \
  ios/App/App/SampleTransfer.swift tests/ConnectivityTests.swift \
  -o /private/tmp/cricket-connectivity-tests
/private/tmp/cricket-connectivity-tests
xcrun swiftc ios/App/App/SampleTransfer.swift ios/App/App/SampleVideo.swift \
  tests/TransferTests.swift -o /private/tmp/cricket-transfer-tests
/private/tmp/cricket-transfer-tests
```

The signed build was installed and launched successfully on both connected iPhones via CoreDevice on 2026-10-04. Mixed-phone generation, transfer/playback and slow-transfer retry subsequently passed by user report; see [Android physical results](android-transfer.md). iPhone-to-iPhone transfer, numerical timing evidence and remaining platform/network checks are still pending.
