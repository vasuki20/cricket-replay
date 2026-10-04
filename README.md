# cricket-replay
Offline cricket replay using nearby phones. Built for casual matches on Android and iPhone.

The P0 feasibility harness uses Angular, Capacitor, Swift and Kotlin. Development and local testing currently focus on iPhone; Android phone tests are deferred.

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

The iPhone P0-03 connection experiment and two-phone test procedure are in [connectivity.md](docs/feasibility/connectivity.md). Shared-Wi-Fi QR pairing and peer ping passed by user report. The iPhone [generated-video transfer experiment](docs/feasibility/transfer.md) adds encrypted MP4 transfer, checksum verification, progress, and native playback; its phone tests are pending.
