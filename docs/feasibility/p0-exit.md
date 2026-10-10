# P0 exit recommendation — #15

> Historical P0 evidence snapshot, retained without inventing new physical results. On 10 October 2026 the user confirmed P0 complete and GitHub #1 is closed. Work now proceeds through interim #16 before #2. The open/closed recommendations below describe the earlier snapshot; the exact trial pairing still requires the [first-match readiness gate](../testing/first-match-readiness.md).

Updated 2026-10-10, Asia/Singapore. Evidence baseline: [`032026c`](https://github.com/vasuki20/cricket-replay/commit/032026c), integrated #14 implementation. Issue [#15](https://github.com/vasuki20/cricket-replay/issues/15), parent [#1](https://github.com/vasuki20/cricket-replay/issues/1).

**Recommendation: NO-GO for starting P1. Continue P0 physical validation.** The reusable implementation and automated evidence justify further testing; they do not establish the required phone-only offline topology, all four pairings, sustained capture or physical review timing. User review of this recommendation is pending. Keep #1 and #15 open; no P1 work begins from this report.

## Epic exit criteria and deliverables

| #1 requirement | Evidence | Status / explicit blocker |
| --- | --- | --- |
| Real-device results matrix for all four pairings | Matrix below; earlier connectivity/transfer reports in platform docs | Incomplete. Integrated reviews not run in every row; second Android unavailable |
| 30-minute capture and recent extraction without stopping; inspect boundaries | Swift generated continuous encoding/remux/decoded joins; Android extraction and buffer checks | Not run physically on either recording platform; short Android run failed late, cause not retained |
| Architecture and go/no-go before P1; record hotspot assumption changes | [ADRs](architecture-decisions.md), this recommendation | Written; user review pending. Host role separated from hotspot owner, no offline topology qualified yet |
| Developer machine supports chosen Android/iOS toolchains | Angular/signed iOS/app+test APK builds pass; [environment](environment.md), [install guide](harness.md) | Build capability demonstrated. Java 21 currently temporary: install/configure durable JDK before temporary runtime removal; no alternate machine presently required |
| Install minimal native apps on Android and iPhone; record prerequisites/device candidates | Historical OnePlus and both iPhone installs; final #14 installed on iPhone 15 Pro | Current #14 build not confirmed installed on OnePlus/iPhone 15; final iPhone launch blocked by lock |
| Mobile data off, phone-hotspot/local network, all four pairings; unsupported/fallback explicit | Earlier shared-Wi-Fi pairing reports | Phone-created network without cellular service not proved. Router does not replace phone-only criterion; iPhone hotspot restriction unresolved |
| Sample transfer, setup/throughput and interruption recovery | Mixed synthetic transfer/playback/retry user reports; native encrypted-loopback tests | Numerical physical setup/throughput absent; same-platform sample transfer not run |
| Sustained bounded rolling buffer/timestamps/extraction on both platforms | Native implementation and synthetic/JVM checks; short recording/playback user reports | 30-minute storage/heat/gap/endurance and actual capture-through-transfer continuity not measured |
| Permissions, offline hotspot, Host background, pairing protection, playback/frame extraction | ADRs and native regression checks; historical user lifecycle failures | Physical denial/regrant, current lifecycle recovery and #13 frame/timing controls not verified; Android background error unresolved |
| Product constraints: Android+iPhone, offline, configurable windows, players decide | Shared/native contracts; settings rejection/remux checks; no verdict feature | Preserved requirements. Physical defaults vs 60/10 comparison pending; no platform pairing removed |
| All children and exit criteria complete before epic closure | #7–#15 evidence documents | Incomplete. Implementation milestones do not close physical acceptance or authorize P1 |

## Physical results matrix

Historical passes apply only to the stated prototype features, not the integrated #14 flow. No pairing is declared unsupported merely because evidence is missing.

| Host → Camera | Earlier pairing / synthetic playback evidence | #14 ≥3 real reviews / ≤30 s / outdoor | Offline phone-created network | Limitation |
| --- | --- | --- | --- | --- |
| Android → Android | Not run | Not run / not run / not run | Not run | Only one Android owned; borrow a second and record model/OS |
| iPhone → iPhone | QR/ping user-reported pass; synthetic transfer/playback not run | Not run / not run / not run | Not run | iPhone 15 unavailable in latest discovery; no proven no-cellular topology |
| Android → iPhone | QR/ping and synthetic transfer/playback/retry user-reported pass | Not run / not run / not run | Not proved | OnePlus absent from latest discovery; exact prior network/model/timings not supplied |
| iPhone → Android | QR/ping and synthetic transfer/playback/retry user-reported pass | Not run / not run / not run | Not proved | Same limitation; reverse role must be tested separately |

Devices: OnePlus Nord CE 3 Lite 5G CPH2465, Android 14 / OxygenOS 14.0 (historical physical runs); iPhone 15 Pro, iOS 26.3.1 (a), build 23D771330a (latest discovery); iPhone 15, iOS 26.6/build 23G71 (queried 2026-10-04, currently unavailable). Rediscover OS before the next run. Do not publish identifiers, pairing secrets or personal footage.

## Evidence categories and reproducibility

**Automated:** final strict Angular production/sync, signed iOS Debug and Android app/test APK builds pass; five Android JVM tests pass. Swift connectivity, transfer, continuous encoding and integrated review suites pass with generated fixtures. They cover authentication/tamper/replay, three delayed reviews (0/2/5 s), native remux including 60/10, source timestamp/sample inspection, gap/wrong-tap/invalid-media rejection, leases, injected low storage, interruption/reconnect/retry and cleanup. Playback timing in loopback uses an event fixture, not a visible physical player. New Android review/frame/storage instrumented assertions compile but were **not run**. Historical executed Android instrumentation is described separately in the platform docs.

**User-reported:** earlier mixed-phone QR/ping, synthetic transfer/playback/interrupted retry, short recording/playback and iPhone preview behavior. Exact endurance, timing and full offline topology were not supplied. Reported OnePlus preview/background problems and iOS encoder-stop error remain evidence of failures; fixes/builds do not replace a physical rerun.

**Agent physical action:** final #14 signed app installed on iPhone 15 Pro. Launch failed because the device was locked. No #14 camera/review pass follows from installation.

**Not run:** all four integrated pairings/outdoor three-review measurements, visible ≤30-second target, #13 physical tap endpoint/frame controls, 30-minute capture on each platform, default/second-configuration comparison, actual low-storage and complete current lifecycle/failure matrix. Reconnect buffer availability and continuous capture during extraction/transfer remain physical checks.

Run exact build/native suite commands in [capture-to-review reproducible checks](capture-to-review.md#reproducible-developer-checks). Installation/signing prerequisites are in [harness.md](harness.md); use Java 21, not default Java 11. Existing logs/build artifacts in temporary directories are local aids, not committed acceptance evidence. This consolidation adds documentation only and does not claim new test runs.

For phone-only review, install the same baseline on both phones, disconnect runtime cables, turn mobile data off and follow the [simple Works/Problem phone sheet](../testing/phone-test-sheet.html). Use [detailed #14 procedures](capture-to-review.md#phone-only-test-procedure) for all four pairings, 30-minute runs, 60/10 comparison and Wi-Fi/background/process/storage/cleanup cases. Record model/OS, network owner, essential observations and exact errors. No JSON copying is required. A failed network setup is a Problem; an unperformed test is Not run.

## Reusable code and changes needed in later phases

| Phase | Reuse | Required changes informed by P0 |
| --- | --- | --- |
| P1 [#2](https://github.com/vasuki20/cricket-replay/issues/2) | Angular/Capacitor scaffold, typed native boundary, QR parsing/scanning, local listener/channel and authentication tests | After P0 exit approval: create match identity and expiring join secret, explicit OS Wi-Fi/permission guidance, distinct connected vs recording states, heartbeat/lifecycle recovery, reviewed transport protection and versioned plugin contracts. Qualify offline topology rather than promise automatic hotspot setup |
| P2 [#3](https://github.com/vasuki20/cricket-replay/issues/3) | Rolling encoders, keyframe segment rotation, timestamps, pin/eviction/remux, preview geometry, storage diagnostics | Persist settings; establish supported bounds/storage estimates from device measurements; pin expiry; thermal/storage/interruption handling; abandoned-session cleanup; resolve Android background failure and prove bounded gap-free 30-minute capture on both platforms |
| P3 [#4](https://github.com/vasuki20/cricket-replay/issues/4) | Mapped tap requests, immutable exports, encrypted transfer, verification gates, player leases, real-frame stepping and slow playback | Measured clock tolerance/freshness/drift; bounded user retry/cancel and unavailable/partial/inconclusive states; progress events; latest three temporary reviews, explicit save/export and cleanup; zoom; visible latency measurement and bitrate/cap tuning. Current single received review and fresh-tap retry do not implement those product features |

These are follow-up requirements, not permission to start downstream phases. Diagnostic UI and custom transport remain feasibility code even where engines are reusable.

## Conditions for reconsidering the recommendation

1. Obtain the second Android and both iPhones; install the intended builds and verify current permissions/lifecycle fixes. Resolve exact Android background error and rerun iOS lock/Home recovery.
2. Demonstrate phone-created networking without mobile data/internet and complete ≥3 integrated reviews for each of the four pairings, indoors and short-range outdoors. Record failures and feasible phone-owned fallbacks; resolve any unsupported required pairing explicitly with the user.
3. Record uninterrupted 30-minute runs on Android and iPhone; inspect joins and clips while capture continues, storage bounds and heat. Compare defaults with 60/10; document actual timing accuracy and visible tap-to-play against 30 seconds.
4. Complete Wi-Fi loss, background/lock, process death, storage, unavailable footage and cleanup checks; verify buffer availability/retry and that partial/unverified footage never appears ready.
5. Reconcile results into this matrix and child issues, settle production transport/topology decisions, then obtain user review of the revised exit recommendation before P1. Keep the epic open until its exit evidence and children are complete.

## Prepared GitHub exit summaries

These are reviewable text for #1 and #15; they have not been posted by this documentation change.

### Epic #1

P0 exit recommendation at `032026c`: **NO-GO for P1; continue P0 physical validation.** Integrated tap-anchored capture → encrypted transfer → verified Host playback/recorded-frame inspection is implemented, with passing Angular/native builds and generated Swift/JVM checks. Earlier mixed-phone pairing/synthetic transfer and short recording/playback passes are user-reported, not integrated acceptance. All four ≥3-review/outdoor/≤30-second rows, offline no-cellular phone-hotspot topology and 30-minute capture on both platforms remain unverified. One second Android is needed; OnePlus and iPhone 15 were absent from latest discovery. Android background-stop failure needs exact error/retest. ADRs and full evidence mapping: `docs/feasibility/architecture-decisions.md` and `docs/feasibility/p0-exit.md`. Keep epic open; user review and evidence are required before P1.

### Issue #15

Consolidated transport/pairing, native video format/pipeline, tap clocks, lifecycle/permissions, plugin ownership and experiment settings ADRs, plus every #1 exit criterion, four-pairing matrix and P1/P2/P3 changes. Baseline `032026c`; build/suite commands and phone-only install/test procedures linked in the report. Tested-device evidence separates historical OnePlus Android 14 and iPhone reports from generated checks and final iPhone 15 Pro installation (launch locked). New Android instrumentation and all integrated physical acceptance remain not run. Recommendation: NO-GO for P1 until physical blockers and user review resolve. No footage/credentials attached. Keep #15 open pending review and publication of the exit report.
