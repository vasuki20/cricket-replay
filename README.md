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

Android host/camera QR pairing and authenticated diagnostics pass by user report with an iPhone in both host directions; see [Android connectivity tests](docs/feasibility/android-connectivity.md) for mixed-phone checks. Android [encrypted sample transfer and native playback](docs/feasibility/android-transfer.md) are implemented; mixed-phone transfer/playback and interrupted-transfer retry pass by user report.

Android [continuous camera and rolling-buffer experiment](docs/feasibility/android-recording.md) adds rear-camera capture, configurable retention/review windows and local extraction while encoding continues. Physical 30-minute recording and visible boundary continuity remain unverified; iPhone camera recording follows in #12.

The iPhone P0-03 connection experiment and two-phone test procedure are in [connectivity.md](docs/feasibility/connectivity.md). Shared-Wi-Fi QR pairing and peer ping passed by user report. The iPhone [generated-video transfer experiment](docs/feasibility/transfer.md) adds encrypted MP4 transfer, checksum verification, progress, and native playback; mixed-phone tests pass by user report; iPhone-to-iPhone transfer and detailed timings remain pending.
