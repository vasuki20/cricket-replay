# cricket-replay
Offline cricket replay using nearby phones. Built for casual matches on Android and iPhone.

The P0 feasibility harness uses Angular, Capacitor, Swift and Kotlin. Development and local testing use two iPhones and a OnePlus Nord CE 3 Lite 5G (Android 14). Android build, installation, and native harness checks pass.

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

For a nontechnical tester using one iPhone and one OnePlus, open the [quick phone check](docs/testing/phone-test-sheet.html) in a browser. Allow about 15–20 minutes for preview, recent-clip playback, continued recording and a demonstration-video send in each direction. Tick Works/Problem; no technical numbers or experiment reports are required. Copy the simple results, save as text or print. Install the intended native app builds first. Detailed endurance and failure-scenario procedures remain in the feasibility documents for follow-up.

Android host/camera QR pairing and authenticated diagnostics pass by user report with an iPhone in both host directions; see [Android connectivity tests](docs/feasibility/android-connectivity.md) for mixed-phone checks. Android [encrypted sample transfer and native playback](docs/feasibility/android-transfer.md) are implemented; mixed-phone transfer/playback and interrupted-transfer retry pass by user report.

The [Android](docs/feasibility/android-recording.md) and [iPhone](docs/feasibility/ios-recording.md) continuous camera experiments add rear-camera capture, configurable retention/review windows and local extraction while encoding continues. Physical 30-minute recording and camera boundary continuity remain unverified; see each experiment's evidence and manual test instructions.

The [review timing and recorded-frame experiment](docs/feasibility/review-timing.md) adds native clock mapping, delayed review requests, actual-frame inspection and slow playback on both platforms. Automated development checks pass; physical timing/playback measurements remain pending. Requested recording clips stay on the camera pending #14 integration.

The iPhone P0-03 connection experiment and two-phone test procedure are in [connectivity.md](docs/feasibility/connectivity.md). Shared-Wi-Fi QR pairing and peer ping passed by user report. The iPhone [generated-video transfer experiment](docs/feasibility/transfer.md) adds encrypted MP4 transfer, checksum verification, progress, and native playback; mixed-phone tests pass by user report; iPhone-to-iPhone transfer and detailed timings remain pending.
