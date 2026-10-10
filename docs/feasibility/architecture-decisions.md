# P0 architecture decisions — #15

Recorded 2026-10-10 against `032026c`. Parent [#1](https://github.com/vasuki20/cricket-replay/issues/1). These decisions describe the feasibility implementation; production choices remain provisional until the [exit gate](p0-exit.md) is satisfied. Android and iPhone, phone-only offline operation, configurable windows and player-made decisions remain requirements.

## ADR 01: Local transport and network ownership

Use a phone Host listening on local TCP and a Camera-initiated authenticated connection. Reuse `LocalSession` on Kotlin/Swift. This provides ordered bounded messages and completed-file transfer without a backend, runtime account or internet. One Camera and one active review are experiment limits.

Joining Wi-Fi is an explicit OS step; QR pairing does not create a network. **Host role and hotspot owner are separate.** Permit a Camera-owned hotspot and manually select a reachable Host address. This relaxes the original assumption that the reviewing Host must create the hotspot, without relaxing phone-only offline networking. Router Wi-Fi is an isolation test, not proof of a phone-created network. No phone-hotspot topology with cellular data off is currently qualified for all four pairings. If iPhone hotspot cannot operate in that condition, record the failure and test another phone-owned topology; do not declare iPhone/iPhone supported using a laptop/router fallback. Unrestricted background hosting is not promised.

Alternatives: cloud rendezvous violates core offline operation; platform-specific peer networking adds cross-platform risk; a router alone does not meet the phone-only criterion. Reconsider transport/network setup if the physical matrix cannot pass. Evidence: [connectivity](connectivity.md), [Android connectivity](android-connectivity.md).

## ADR 02: Pairing and protection

Retain protocol 2 for P0: QR/manual address, port and random 128-bit session secret; fresh connection nonces, mutual HMAC-SHA256 authentication, directional ordered frames, and AES-GCM transfer packets with HKDF-derived directional keys. Recording offers and timing metadata travel in encrypted transfer packets. Status/ping diagnostics are authenticated plaintext. Secret possession is trust; protect the QR and invalidate session state when ending it. No certificate-validation bypass or global ATS relaxation is permitted.

This custom protocol has no forward secrecy and is not audited. P1 must choose and verify a reviewed cross-platform encrypted transport/pairing design, with scoped peer trust, secret expiry and match identity. Evaluate pinned TLS or compatible TLS-PSK rather than assuming interoperability. Do not call the current experiment production security. Evidence: [transfer protection and regressions](transfer.md), [Android transfer](android-transfer.md). Preserve tamper, replay, wrong-secret and interrupted-transfer checks during replacement.

## ADR 03: Continuous video and file format

Keep a single camera/encoder running while rotating only MP4 writers at sync frames. Kotlin uses Camera2 → MediaCodec → MediaMuxer; Swift uses AVCaptureSession → VideoToolbox → compressed AVAssetWriter inputs. Use silent H.264, landscape, target 720p/30 with disclosed device-capability fallback; no audio permission. Avoid capture restart at every segment boundary. Pin sealed inputs, remux without interpolation/transcoding, preserve original monotonic timestamps in metadata, and export an independent snapshot for transfer. A preceding keyframe can add disclosed lead-in; the end must remain anchored to the tap.

Ready requires exact bytes/SHA-256, matching request/metadata, monotonic sample timestamps and beginning/middle/end decode. Internal gaps over 100 ms and endpoint errors outside the experiment gate fail explicitly. These gates do not prove visual continuity, physical clock accuracy or all-frame decode. Native media leases prevent replacement/deletion during playback or inspection. Whole-segment retention and pins can exceed the requested duration; storage watchdogs bound the experiment, subject to physical measurement.

Alternatives: stop/restart capture risks gaps; sending the rolling buffer wastes bandwidth; transcoding risks latency and frame alteration. Reconsider codec/bitrate and transfer bounds after measured outdoor throughput. Evidence: [Android recording](android-recording.md), [iOS recording](ios-recording.md), [integrated flow](capture-to-review.md).

## ADR 04: Tap clocks and inspection

Capture tap time at native method entry before delivery delay. Use eight authenticated monotonic-clock exchanges to estimate Host→Camera offset and network uncertainty; invalidate calibration on reconnect. Extract at the mapped endpoint, preserve source timestamps through transfer, and inspect actual decoded samples. Offer 1×/0.5×/0.25× playback without generated frames or automatic decisions.

Network uncertainty excludes sensor exposure, bridge latency and drift. `requestedHostUs` currently means the mapped Camera monotonic tap despite its name; document it and migrate/version the contract before production. Native prepared/start timing includes polling and optional user wait; it is not first visible pixel latency. P3 needs measured timing tolerance, calibration freshness/drift policy and visible tap-to-play evidence. Receipt-time extraction and wall clocks are unsuitable substitutes. Evidence: [review timing](review-timing.md), [integrated measurement limitations](capture-to-review.md).

## ADR 05: Permissions, lifecycle and recovery

Request Camera access for capture/scanning and iOS local-network access for local connections. Join the network through OS settings. Keep capture foreground, landscape and awake; background/lock stops capture/session visibly and requires explicit restart/reconnect. Network loss alone does not intentionally stop the independent recorder. QR scanning cannot share active camera capture; use manual reconnect or disclose buffer loss from stopping to scan.

A failed transfer discards partial files; retry recalibrates and uses a new tap, from byte zero. Process death does not recover a ready clip or unfinished buffer. Private stale transfer/snapshot files are purged by new native owners; cleanup requires released playback/extraction ownership. Low storage and unavailable footage fail explicitly. The reported Android background-stop error is unresolved; the iOS encoder invalidation fix has synthetic coverage but no physical rerun. P1/P2 must define reliable user-visible recovery and validate denial/regrant, lock, process death and storage behavior. Do not infer background capability from builds. Evidence: platform recording docs and [failure procedures](capture-to-review.md#interruption-and-retry-behavior).

## ADR 06: Shared controls and native ownership

Keep controls/layout in Angular `src/main.ts`, the typed Capacitor contract in `src/native.ts`, and transport, camera, clocks, media/file processing and player ownership native. Kotlin and Swift expose equivalent status/metadata; paths and video bytes do not cross the bridge. Decoded inspection stills cross locally as PNG. Browser preview cannot validate native behavior. Polling is acceptable for P0 but adds about one second to automatic playback scheduling.

Reuse native engines and contract semantics, not the diagnostic screen as finished match UI. P1 should add explicit match/connection/recording states, versioned contracts and lifecycle/error ownership. P3 should consider native events for progress/ready/playback timing, keeping failure gates authoritative native-side. Preserve signing, application ID `com.aadhinitinytales.cricketreplay` and Android package despite its historical source-directory name.

## ADR 07: Settings and resource bounds

Current defaults: retention 120 s / review 20 s. Both native implementations validate integer retention 30–180 s, review 5–30 s and review ≤ retention − 10 s. Compare 60/10 physically as well as defaults. These are experiment bounds, not permanent product limits. Recording watchdog ceiling is 256 MiB with 64 MiB free-space floor; received clips are at most 32 MiB and require offered bytes plus 64 MiB reserve. Segment sealing, transfer inactivity and overall review have finite timeouts; see implementation/integration docs for exact behavior.

P2 must measure supported ranges and storage estimates, persist settings locally, define pin expiry and respond to thermal/storage signals. P3 must reconcile supported review duration/bitrate with the clip cap and latency target. Wider user settings must never silently truncate or publish partial footage as ready. Validation tests establish rejection behavior, not sustained hardware capacity.

## FT extension: read-only viewers (build 12)

Added after P0, for the 11 October field trial: one Host owns review requests, one Camera records, and up to four Viewers fetch the latest completed replay. A separate Viewer QR has an independent random secret and listener at the camera port + 1. Each viewer connection owns its authentication, encrypted transfer and snapshot files; viewer traffic cannot invoke camera extraction or End match. Host copies a verified artifact on demand, including during host playback, and viewers apply the existing checksum/metadata/decode gates before opening independent Video/Frames playback. No continuous video, automatic push, replay history, multiple cameras or shared playback position is introduced.

To reuse protocol 2 without changing its cryptographic transcript, the viewer transfer sender uses the legacy wire `camera` direction and the receiving viewer uses `host`; product roles and permissions are enforced by the dedicated listener and separate secret. This is a scoped experiment, not the production role/match-identity protocol required by ADR 02. Native loopback tests cover concurrent viewers and denied End commands; physical three-phone/offline/load checks remain pending in [first-match readiness](../testing/first-match-readiness.md).

## FT extension: bounded transfer bursts (build 15)

Investigation found a 16 KiB stop-and-wait transfer: every chunk incurred another network round trip. Sender and receiver now negotiate eight ordered chunks before acknowledging, limiting raw outstanding data to 128 KiB. Missing capability falls back to the legacy single chunk; encrypted packet format, file cap, ordering and verification gates remain unchanged. This also applies to viewer downloads. The deliberately slow diagnostic mode retains single chunks. Transfer and final verification durations are exposed in Diagnostics.

The encrypted 10 MB controlled benchmark with simulated 20 ms round trips improved from 15.57 s to 2.28 s, with exact-byte verification. Native OnePlus transfer/review regressions passed. These establish the mechanism and compatibility, not real hotspot performance; see [build 15 evidence and pending physical timing](../testing/first-match-readiness.md#build-15-transfer-investigation). Offline versus cloud deployment should be reconsidered using measured extraction, transfer and playback costs rather than treating this round-trip bottleneck as a local-network limit.

## FT extension: latency and background return (build 17)

Both updated peers negotiate 32 chunks (512 KiB raw outstanding); build-15 peers use eight and older peers use one. Native readers process bounded blocks; Android verification retains the same timestamp/decode gates without unused PNG encoding. Clock probes run 80 ms apart, and automatic review proceeds once replies arrive instead of unconditionally waiting 3.5 seconds. Original native tap anchoring and the calibration deadline remain enforced.

Host/viewer sessions and verified replay state are retained on ordinary background/return. Android restores decoder position and play/pause state; frame UI remains mounted, and Back closes fullscreen review. iOS retains and pauses/resumes its player. Camera capture still stops in background; socket failure can require same-match reconnection. This is in-process lifecycle preservation, not persistence/recovery after OS process eviction. See [evidence and remaining physical checks](../testing/first-match-readiness.md#builds-16–17-latency-and-background-return).

## Official platform references

Existing pipeline choices follow [Camera2 capture sessions](https://developer.android.com/media/camera/camera2/capture-sessions-requests), [MediaMuxer](https://developer.android.com/reference/android/media/MediaMuxer), [Apple dropped-frame guidance](https://developer.apple.com/library/archive/technotes/tn2445/_index.html), [VideoToolbox](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection) and [compressed writer inputs](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/outputsettings). These are references already used in the experiments, not new physical evidence or a newly validated pipeline.
