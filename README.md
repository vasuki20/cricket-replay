# One More Look
Offline cricket replay using nearby phones. Built for casual matches on Android and iPhone.

Match mode now opens by default, with the P0 tools retained under Diagnostics. The app uses Angular, Capacitor, Swift and Kotlin. Development and local testing use two iPhones and a OnePlus Nord CE 3 Lite 5G (Android 14). Android build, installation, and native harness checks pass.

```sh
npm ci
npm run start
```

For the installed iPhone app:

```sh
npm run sync:ios
npm run open:ios
```

Select your signing team and connected phone in Xcode, then Run. The browser preview cannot execute native diagnostics.

See [environment inventory](docs/feasibility/environment.md) and [harness build and verification guide](docs/feasibility/harness.md) for prerequisites, manual checks and recorded results.

For a nontechnical tester using one iPhone and one OnePlus, open the [quick phone check](docs/testing/phone-test-sheet.html) in a browser. Allow about 20–30 minutes for preview, recording, three real camera reviews in each direction, host inspection and reconnect. Tick Works/Problem; no technical numbers or experiment reports are required. Copy the simple results, save as text or print. Install the intended native app builds first. Detailed endurance and failure-scenario procedures remain in the feasibility documents for follow-up.

Android host/camera QR pairing and authenticated diagnostics pass by user report with an iPhone in both host directions; see [Android connectivity tests](docs/feasibility/android-connectivity.md) for mixed-phone checks. Android [encrypted sample transfer and native playback](docs/feasibility/android-transfer.md) are implemented; mixed-phone transfer/playback and interrupted-transfer retry pass by user report.

The [Android](docs/feasibility/android-recording.md) and [iPhone](docs/feasibility/ios-recording.md) continuous camera experiments add rear-camera capture, configurable retention/review windows and local extraction while encoding continues. Physical 30-minute recording and camera boundary continuity remain unverified; see each experiment's evidence and manual test instructions.

The [review timing and recorded-frame experiment](docs/feasibility/review-timing.md) adds native clock mapping, delayed review requests, actual-frame inspection and slow playback on both platforms. Automated development checks pass; physical timing/playback measurements remain pending. The [capture-to-review integration](docs/feasibility/capture-to-review.md) now sends requested recording clips through encrypted transfer, verifies and decodes them on Host, and preserves original recording timestamps. Physical #14 acceptance remains pending.

The iPhone P0-03 connection experiment and two-phone test procedure are in [connectivity.md](docs/feasibility/connectivity.md). Shared-Wi-Fi QR pairing and peer ping passed by user report. The iPhone [generated-video transfer experiment](docs/feasibility/transfer.md) adds encrypted MP4 transfer, checksum verification, progress, and native playback; mixed-phone tests pass by user report; iPhone-to-iPhone transfer and detailed timings remain pending.

The [P0 exit recommendation](docs/feasibility/p0-exit.md) maps the epic criteria to evidence and blockers: **no-go for starting P1 pending physical validation and user review**. [Architecture decisions](docs/feasibility/architecture-decisions.md) record the provisional native pipeline, transport, clocks, lifecycle and settings decisions, with changes needed in P1/P2/P3.

The interim [first-match field trial #16](https://github.com/vasuki20/cricket-replay/issues/16) is the active work before P1 #2. Start with the [player guide](docs/testing/first-match-guide.md); the [readiness record](docs/testing/first-match-readiness.md) tracks the selected iPhone-camera → OnePlus-host pairing. The historical P0 no-go report above remains evidence of unperformed checks; user-confirmed P0 completion does not establish first-match readiness. The physical rehearsal and trial remain pending.

Brand sources live in `src/assets/brand/` (logo, ground illustration and app icon). Run `xcrun swift scripts/generate-brand-assets.swift` on macOS to regenerate native icon/splash sizes from those originals.
