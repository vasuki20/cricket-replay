# P0-01: Developer environment and test phones

Issue: [#7](https://github.com/vasuki20/cricket-replay/issues/7), parent [#1](https://github.com/vasuki20/cricket-replay/issues/1).
Inspected on 2026-10-03 (Asia/Singapore). Status: **in progress; prerequisites and physical installation remain incomplete**.

## Agreed development sequence

On 2026-10-03 the user chose iPhone for development and local testing: iPhone A now and iPhone B when available. Android phones are not available locally; testing with friends is planned for later, with models/OS and tester availability still unconfirmed. Defer Android toolchain preparation and physical Android/mixed-device verification. Keep the harness structured for both platforms while building and verifying iOS first.

Proceed with the iOS portion of P0-02 with these outstanding P0-01 prerequisites explicitly recorded. This does not complete P0-01 or remove Android support, the four-pairing matrix or any epic exit criterion. Android results stay **not run** until real-device evidence is collected. Verify the Android build toolchain and prepare installation/test instructions before providing a test build to friends.

## Observed developer machine

| Component | Observed result | Readiness |
| --- | --- | --- |
| macOS | 26.5, build 25F71; arm64 | Local iOS toolchain available; no alternate machine required by initial checks |
| Xcode | 26.6, build 17F113 | Unsigned iOS build passes; user reports physical installation/smoke-test success on 2026-10-04 |
| Selected developer directory | `/Applications/Xcode.app/Contents/Developer` | Full Xcode selected |
| Swift | 6.3.3, swiftlang-6.3.3.1.3 | Version check passes |
| iPhoneOS SDK | 26.5 | SDK query passes; installed missing matching iOS simulator component during P0-02, then full unsigned build passed |
| Node / npm | 22.17.0 / 10.9.2 | Compatible with Angular 21 and Capacitor 8; below Angular 22 minimum |
| Default Java | Oracle 11.0.22 | Do not use as the new harness Gradle JDK |
| Other detected JDKs | Oracle 20.0.1; IBM 11.0.21.0-m1; Corretto 11.0.20; Java 8 variants | No JDK selected or verified for the harness |
| Android SDK | `~/Library/Android/sdk` | Present, needs update |
| SDK platforms | API 28–34 plus preview/extension entries | API 36 absent |
| Build tools | 30.0.3, 31.0.0, 33.0.2, 34.0.0 | New harness requirements not installed/verified |
| SDK command-line tools | 12.0 (`latest` directory also reports 12.0) | Present, not on PATH |
| ADB | 1.0.41; platform-tools 34.0.5-10900879 | Binary runs by absolute path; not on PATH; device discovery not run |
| Android Studio | Not found in `/Applications` listing | Installation elsewhere not ruled out; version unknown |
| Available disk space | Approximately 90 GiB on data volume | Snapshot only |

Repository initially contains only README.md and no app, package manifest, lockfile or native projects. No applicable AGENTS.md was found in the repository or inspected ancestor directories.

## Framework candidate and official requirements

P0-02 now pins **Angular 21.2.25 (CLI/build 21.2.24) + Capacitor 8.5.2**, with Swift Package Manager for iOS. Dependencies are installed, and web and unsigned iOS builds pass. Real-device results are tracked in [harness.md](harness.md). The generated Android template targets Java 21; Android build verification remains deferred.

- [Angular compatibility](https://angular.dev/reference/versions): Angular 21 supports Node 22.12+ within major 22, TypeScript 5.9 and RxJS 7.4+. Angular 22 requires Node 22.22.3+ within major 22 and TypeScript 6.0. Existing Node can support the proposed Angular 21 baseline; upgrade it before selecting Angular 22.
- [Capacitor environment setup](https://capacitorjs.com/docs/getting-started/environment-setup): Capacitor 8 requires Node 22+, Xcode 26+, and Android Studio 2025.2.1+. Android Studio supplies an appropriate JDK. SPM is the default iOS package manager.
- [Capacitor 8 migration baseline](https://capacitorjs.com/docs/updating/8-0): iOS deployment target 15; Android minimum API 24, compile/target API 36, AGP 8.13.0 and Gradle 8.14.3. Verify the actual generated template before pinning build tools or selecting the Gradle JDK.
- [Capacitor 8.5 guidance](https://capacitorjs.com/docs/updating/8-5): account for the UIScene migration when selecting the precise Capacitor release and generating the iOS project.

These are framework installation floors, not proof that any phone can capture continuously, host an offline network or play extracted footage.

## Physical device inventory

| Slot | Model / OS | Availability and installation evidence | Capture evidence |
| --- | --- | --- | --- |
| iPhone A | iPhone 15 Pro (`iPhone16,1`); reported iOS 26.3.1 (a), build 23D771330a | User confirms connected in Xcode Devices and Simulators; CoreDevice confirms connected, paired, wired; Developer Mode enabled and developer disk-image services available | Not run: rear camera, landscape 720p/30, no audio, continuous capture and extraction |
| iPhone B | iPhone 15 (`iPhone15,4`); iOS 26.6, build 23G71 (queried 2026-10-04) | Connected in Xcode/CoreDevice, Developer Mode enabled, developer disk-image services available. User reports installation succeeded after switching Apple developer account; earlier registration-limit blocker resolved | Not run |
| Android A | Unknown | Not available locally; friend testing planned for later | Not run |
| Android B | Unknown | Not available locally; friend testing planned for later | Not run |

Physical discovery initially timed out inside the execution sandbox. Repeating outside the sandbox succeeded. Initial device-detail discovery returned a developer disk-image mounting warning with `ddiServicesAvailable: false`. After the user checked the connection in Xcode, repeated discovery on 2026-10-03 returned `ddiServicesAvailable: true`, Developer Mode enabled and install/launch capabilities, without the mounting warning. The earlier warning has cleared; the exact cause is undetermined. The user subsequently reports successful signed installation/testing on 2026-10-04; detailed checklist outcomes are not individually reported. No device serial numbers, UDIDs or credentials are stored here.

All four pairings remain **not run**: Android host/Android camera; iPhone host/iPhone camera; Android host/iPhone camera; iPhone host/Android camera. Two phones of each platform are needed for the complete matrix. Both iPhones are now identified as available; iPhone B still needs on-machine verification and both Android phones remain unidentified.

## Local installation and signing

Update 2026-10-04: user reports successful app installation/testing after signing setup. The local Xcode project now selects automatic signing and a development team. This establishes user-reported iPhone installation success; individual permission/offline checks and iPhone B installation are still unreported. Preserve the user's local signing edits.

For iOS, use Xcode automatic signing with an Apple Account and Personal Team if available. Paid distribution is not a prerequisite for this experiment. [Apple's account guidance](https://developer.apple.com/help/account/basics/about-your-developer-account) explains that Personal Team provisioning expires after seven days and requires rebuilding/reinstalling. Signing was pending on 2026-10-03 and the user reports successful installation/testing on 2026-10-04. Do not store account credentials, certificates or provisioning profiles in the repository.

For Android, use the debug APK and development debug certificate. [Android signing guidance](https://developer.android.com/studio/publish/app-signing) documents IDE debug signing; [physical-device setup](https://developer.android.com/studio/run/device) covers USB debugging and device selection. Enable USB debugging, authorize this computer on the phone, then verify installation using the P0-02 harness. No paid distribution or runtime account is required.

## Reproduce the inventory

```sh
sw_vers
uname -m
xcode-select -p
xcodebuild -version
xcrun swift --version
xcrun --sdk iphoneos --show-sdk-version
node --version
npm --version
java -version
/usr/libexec/java_home -V
ls "$HOME/Library/Android/sdk/platforms"
ls "$HOME/Library/Android/sdk/build-tools"
cat "$HOME/Library/Android/sdk/cmdline-tools/latest/source.properties"
"$HOME/Library/Android/sdk/platform-tools/adb" version
xcrun devicectl list devices
```

Device discovery needs access to the macOS CoreDevice service. To inspect OS and Developer Mode locally, use `xcrun devicectl device info details --device <identifier-from-list>`; redact personal identifiers before saving results.

## Remaining prerequisites and manual verification

1. Locate or install Android Studio 2025.2.1+, install API 36 and template-required build tools, update platform-tools, and configure the supplied Gradle JDK rather than default Java 11. Confirm SDK tools can be invoked reproducibly. No machine-wide tools have been changed by this inventory.
2. iPhone A connection and developer disk-image services are now verified. Connect iPhone B when available, record its OS version, enable Developer Mode and verify it in Xcode and CoreDevice.
3. Local signing/install is user-reported successful on iPhone A. Verify installation on iPhone B and record its OS and detailed manual results.
4. Identify Android A/B and iPhone B, recording exact model/OS and borrowing availability. For each Android phone, verify `adb devices -l` reports an authorized device; for each iPhone, verify Xcode destination selection.
5. Measure native capture capabilities once the harness exists: rear-camera formats, frame-rate ranges, encoder compatibility and fallback. Hardware specifications alone do not satisfy capture verification.

P0-01 remains open. Android build prerequisites, iPhone B installation readiness and the complete Android device inventory are unresolved. Proceed with the iOS portion of P0-02 under the agreed sequence above; the full P0-01 dependency and epic exit gate remain unsatisfied.
