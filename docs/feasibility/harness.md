# P0-02: Installable feasibility harness

Issue: [#8](https://github.com/vasuki20/cricket-replay/issues/8). See [P0-01 environment](environment.md) for the agreed iPhone-first sequence and deferred Android prerequisites.

## Implemented behavior

Angular diagnostic screen with host/camera role selection, runtime platform, native ping and camera permission request/status. The native ping returns platform, installed app version and OS version from Swift or Kotlin. Browser preview disables native actions instead of fabricating phone results. Local-network permission, connection and recording are explicitly marked unimplemented/not tested, pending their own tickets. Role selection does not start a network or recording session.

The app packages its web assets and needs no runtime account, backend, analytics or internet. Build dependencies require network access during initial installation. Audio permission is not requested. Buffer/review values (120s/20s) are experiment defaults only.

Pinned dependencies: Angular runtime/compiler 21.2.25; CLI/build 21.2.24 (the build package's available patch); Capacitor core/CLI/iOS/Android 8.5.2; TypeScript 5.9.3; RxJS 7.8.2. `package-lock.json` records transitive dependencies. SPM resolves Capacitor 8.5.2 with a checked-in `Package.resolved`. Native app version is 0.1.0 on both platforms.

## Build and run on iPhone

Prerequisites: Node compatible with the pinned Angular version, Xcode 26+, its iOS platform component, an Apple Account/team available in Xcode, connected trusted iPhone with Developer Mode enabled. Signing was pending on 2026-10-03; on 2026-10-04 the user reports successful installation and testing on iPhone.

```sh
npm ci
npm run sync:ios
npm run open:ios
```

In Xcode select project **App**, target **App**, **Signing & Capabilities**, enable automatic signing and select your team. If the bundle ID is unavailable for your team, choose a unique ID and record it locally. Select the connected iPhone as the run destination and press Run. Account credentials and signing artifacts stay out of the repository.

After Angular changes run `npm run sync:ios` before rebuilding in Xcode. Native Swift changes require an Xcode rebuild. Keep the generated native projects; do not run `cap add` again over them.

Unsigned compile verification (does not prove installation):

```sh
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/cricket-replay-derived \
  CODE_SIGNING_ALLOWED=NO build
```

If Xcode reports “iOS 26.5 is not installed”, open **Xcode → Settings → Components** and install the matching iOS platform. Command-line platform download is `xcodebuild -downloadPlatform iOS -architectureVariant arm64`. A SDK version query alone did not establish full platform readiness on this machine.

## Android path

Update 2026-10-04: OnePlus Nord CE 3 Lite 5G (CPH2465), Android 14 / OxygenOS 14.0, is now available. SDK platform 36 and build-tools 36.0.0 are installed. Java 21.0.12.1, Gradle Debug build, physical APK installation, launch, and a native diagnostics response passed. The on-device screen shows `android`, app version `0.1.0`, OS `14`, camera permission `granted`. This establishes the harness bridge, not connectivity or transfer. Denial/regrant and offline relaunch remain pending.

The current local build uses a temporary Java 21 runtime; a durable Java 21 installation/Android Studio Gradle JDK configuration is still needed for builds after temporary files are removed. Reproduce with the current runtime:

```sh
npm run sync:android
cd android
JAVA_HOME=/private/tmp/cricket-jdk21/jdk-21.0.12.1+1/Contents/Home ./gradlew :app:assembleDebug
```

ADB is at `~/Library/Android/sdk/platform-tools/adb`. Select the physical phone explicitly if an emulator is also listed; install with `adb -s <device> install --no-streaming -r app/build/outputs/apk/debug/app-debug.apk`. User authorization of USB debugging and any phone installation prompt is required. Generated Gradle/Kotlin caches and debug artifacts are ignored by Git.

Kotlin `FeasibilityPlugin` is registered by `MainActivity`. Gradle pins Kotlin 2.2.20 and uses JDK 21; the Capacitor template uses AGP 8.13.0, Gradle 8.14.3 and Android compile/target API 36. Install the missing P0-01 prerequisites before building. No Android build or device support is claimed yet.

```sh
npm ci
npm run sync:android
cd android
./gradlew assembleDebug
```

Install the resulting `android/app/build/outputs/apk/debug/app-debug.apk` using Android Studio or authorized ADB. Run the same manual checks below on the real phone. Record model/OS, native response and any failures when friends test later.

## Manual verification checklist

1. Install and launch on the physical phone. Verify the diagnostic screen is readable in portrait and landscape, including safe areas and all buttons.
2. Tap **Native ping**. Expect `ios` or `android`, app version `0.1.0`, actual OS version and camera permission state. A native error is a failed check, not a pass.
3. Switch host/camera roles. Verify the selected role and description change, while connection/capture remain unimplemented.
4. Request camera access. On first use, deny permission and verify `denied`. Change camera permission in phone settings, return and tap ping; verify `granted`. Verify no microphone prompt occurs. If camera access was already decided, document the starting state rather than claiming the first-use flow was tested.
5. Stop the app, disable mobile data and disconnect Wi-Fi, then relaunch from the phone home screen. Tap ping and verify the same diagnostics work with no computer or internet needed at runtime.
6. Repeat on iPhone B and later Android; document exact models/OS and results. No transport or capture test is satisfied by this harness.

## Evidence recorded on 2026-10-03

Follow-up on 2026-10-04: the user reports the app is installed and tested and “all looks okay.” Record this as a user-reported iPhone smoke-test pass, following signing setup. Exact native response, permission denial/regrant, offline relaunch and iPhone B checks have not been individually reported. Android acceptance remains deferred. The P0-03 screen and transport are now documented in [connectivity.md](connectivity.md); the original unimplemented-connection description above refers to the P0-02 build.

| Check | Result |
| --- | --- |
| Dependency installation / npm lockfile | Pass |
| Angular production build and strict template compilation | Pass outside execution sandbox; sandbox run crashed its build worker |
| TypeScript `tsc --noEmit` | Pass |
| iOS Info.plist and Xcode project syntax (`plutil -lint`) | Pass |
| Swift package resolution | Pass; Capacitor 8.5.2 |
| First unsigned iOS compile attempt | Blocked before compilation: missing iOS 26.5 platform component |
| iOS component installation | Pass; installed iOS 26.5 Simulator (23F77), arm64, using Xcode platform download |
| Full unsigned iOS build after installation | Pass; Xcode 26.6, generic iOS destination, Debug; Swift plugin, storyboards and bundled web assets compiled; output `/private/tmp/cricket-replay-derived/Build/Products/Debug-iphoneos/App.app` |
| Android project generation | Pass; automatic Gradle sync failed creating its sandbox-excluded cache; no Android build attempted after generation because toolchain work is deferred |
| Physical iPhone installation/smoke test | User-reported pass on 2026-10-04; exact native response, permission edge cases and offline relaunch not individually reported |
| Physical Android install/launch/ping | Pass on OnePlus CPH2465, Android 14 / OxygenOS 14.0 on 2026-10-04; native response and granted camera permission observed; edge cases pending |

P0-02 remains open until physical-phone acceptance criteria have evidence. The project has been opened in Xcode for selecting the user's signing team and iPhone and running the signed app. The successful unsigned build does not establish native ping, permissions or offline UI behavior on a physical phone. Issues remain open; iPhone B and Android acceptance evidence remain pending. The updated P0-03 build requires fresh installation on both phones.

## Native plugin contract and references

`src/native.ts` defines `ping()` and `requestCameraPermission()` returning `{ platform, appVersion, osVersion, cameraPermission }`. iOS implements and registers the plugin in `FeasibilityPlugin.swift` through a custom bridge controller, selected by both SceneDelegate and the storyboard. Android implements it in `FeasibilityPlugin.kt` and registers it before `BridgeActivity.onCreate`. Add later experiment methods to this contract as their tickets require.

Implementation follows [Capacitor's custom iOS code guide](https://capacitorjs.com/docs/ios/custom-code), [Android code guide](https://capacitorjs.com/docs/android/custom-code) and [iOS plugin guide](https://capacitorjs.com/docs/plugins/ios).
