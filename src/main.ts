import { Component, OnDestroy, effect, signal } from '@angular/core';
import { bootstrapApplication } from '@angular/platform-browser';
import { Capacitor } from '@capacitor/core';
import { Diagnostics, Feasibility, SessionStatus, SampleStatus, RecordingStatus, RecordedFrame } from './native';

@Component({
  selector: 'replay-app', standalone: true,
  template: `
    <main [class.welcome]="!matchRoleChosen() && !diagnosticsMode()">
      @if (cameraFullScreen()) {
        <div class="camera-stage" [class.camera-stopped]="!recordingActive() && !recordingStarting()" role="dialog" aria-label="Camera" (click)="toggleCameraControls()">
          <div class="camera-stage-bar camera-top" [hidden]="!cameraControlsVisible()" (click)="$event.stopPropagation(); showCameraControls()"><button [disabled]="networkBusy() || recordingBusy()" (click)="endMatch()">End</button><p aria-live="polite">{{ recordingStarting() ? 'Opening…' : recordingActive() ? '● ' + (recording()?.elapsedSeconds ?? 0).toFixed(0) + ' s' : 'Stopped' }}</p><span class="connection-dot" [class.connected]="session()?.authenticated" [attr.aria-label]="session()?.authenticated ? 'Connected' : 'Reconnecting'"></span></div>
          <div class="camera-stage-area"><div id="camera-full-preview" class="recording-preview"></div></div>
          @if (recordingError()) { <p class="camera-error" role="alert">{{ recordingError() }}</p> }
          <div class="camera-stage-bar camera-bottom" [hidden]="!cameraControlsVisible()" (click)="$event.stopPropagation(); showCameraControls()">@if (recordingActive() || recordingStarting()) { <button [disabled]="recordingBusy() && !recordingStarting()" (click)="recordingAction('stop')">Stop</button> } @else { <button class="primary" [disabled]="!native || recordingBusy()" (click)="startMatchRecording()">Record</button> }</div>
        </div>
      }
      @if (framePanel()) {
        <div class="frame-stage" role="dialog" aria-label="Frame review" (click)="toggleFrameControls()">
          <div class="frame-toolbar frame-top" [hidden]="!frameControlsVisible()" (click)="$event.stopPropagation(); showFrameControls()"><button [disabled]="hostReviewBusy()" (click)="closeFrameReview(); playHostReview()">Video</button><span>Frames</span><button (click)="closeFrameReview()">Close</button></div>
          <div class="frame-stage-image">@if (hostFrame(); as f) { <img [src]="'data:image/png;base64,' + f.pngBase64" alt="Replay frame" [style.transform]="'scale(' + frameZoom() + ')'"> } @else { <span>{{ hostReviewBusy() ? 'Loading…' : 'No frame' }}</span> }</div>
          @if (timingError()) { <p role="alert" class="error">{{ timingError() }}</p> }
          <div class="frame-controls" [hidden]="!frameControlsVisible()" (click)="$event.stopPropagation(); showFrameControls()">@if (hostFrame(); as f) { <input aria-label="Frame position" type="range" min="0" [max]="f.frameCount - 1" [value]="frameRequested()" (input)="scrubFrame(+$any($event.target).value)" (change)="scrubFrame(+$any($event.target).value, true)"><div class="frame-toolbar"><button [disabled]="hostReviewBusy() || frameRequested() === 0" (click)="requestFrame(frameRequested() - 1)" aria-label="Previous frame">Prev</button><span aria-live="polite">{{ f.index + 1 }} / {{ f.frameCount }}{{ hostReviewBusy() ? ' · …' : '' }}</span><button [disabled]="hostReviewBusy() || frameRequested() >= f.frameCount - 1" (click)="requestFrame(frameRequested() + 1)">Next</button><button (click)="frameZoom.set(frameZoom() === 3 ? 1 : frameZoom() + 1)">{{ frameZoom() }}×</button></div> }</div>
        </div>
      }
      @if (replayPanel() && !framePanel()) {
        <div class="replay-stage" role="dialog" aria-label="Replay" aria-live="polite">
          <button class="replay-back" (click)="replayPanel.set(false)">Close</button>
          <div class="replay-stage-content"><h1>{{ replayHeading() }}</h1>
            @if (replayInProgress()) { <progress [attr.value]="session()?.transfer?.state === 'receiving' ? session()?.transfer?.bytes : null" [max]="session()?.transfer?.totalBytes || 1"></progress><p>{{ replayWaitSeconds() }} s</p> }
            @if (timingError()) { <p class="error" role="alert">{{ timingError() }}</p> }
            @if (session()?.review?.state === 'failed') { <p class="error">{{ session()?.review?.detail }}</p> }
            @if (!replayInProgress() && !hostReviewReady()) { <button class="primary" [disabled]="!session()?.authenticated || hostReviewBusy()" (click)="role() === 'viewer' ? fetchViewerReplay() : requestMatchReview()">Retry</button> }
            @if (session()?.hasPlayableReview && !replayInProgress()) { <button [disabled]="hostReviewBusy()" (click)="playHostReview()">Play</button><button [disabled]="hostReviewBusy()" (click)="openFrameReview()">Frames</button> }
          </div>
        </div>
      }
      <nav class="match-nav"><img class="brand-logo" src="assets/brand/logo.png" alt="One More Look"><button class="utility-button" aria-label="Diagnostics" [attr.aria-label]="diagnosticsMode() ? 'Back to match' : 'Diagnostics'" (click)="toggleDiagnostics()"><svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3" fill="currentColor" stroke="none"/><circle cx="15" cy="17" r="3" fill="currentColor" stroke="none"/></svg></button></nav>
      <div [hidden]="diagnosticsMode()" class="match">
        @if (!matchRoleChosen()) {
          <div class="role-cards"><button (click)="chooseMatchRole('host')"><strong>Host</strong></button><button (click)="chooseMatchRole('camera')"><strong>Camera</strong></button><button (click)="chooseMatchRole('viewer')"><strong>Viewer</strong></button></div>
        } @else {
          <header class="match-header"><h1>{{ role() === 'host' ? 'Host' : role() === 'viewer' ? 'Viewer' : 'Camera' }}</h1><span class="status-chip" [class.connected]="session()?.authenticated">{{ session()?.authenticated ? '● Connected' : networkBusy() ? 'Connecting…' : 'Waiting…' }}</span></header>
          <section class="network-setup" [class.connected-network]="session()?.authenticated && !showHostQR()">
            @if (role() === 'host') {
              <div class="pairing-types"><button [attr.aria-pressed]="!viewerQR()" (click)="viewerQR.set(false); qrKeyReset()">Camera QR</button><button [attr.aria-pressed]="viewerQR()" (click)="viewerQR.set(true); showHostQR.set(true); qrKeyReset()">Viewer QR</button></div>
              @if (session()?.authenticated) { <button (click)="showHostQR.update(toggleQR)">{{ showHostQR() ? 'Hide QR' : 'Pairing QR' }}</button> }
              @if (!sessionActive()) { <button class="primary" [disabled]="!native || networkBusy()" (click)="networkAction('start')">Retry pairing</button> }
              @if (sessionActive() && (!session()?.authenticated || showHostQR())) {
                <div class="pairing-heading"><h2>{{ viewerQR() ? 'Join as viewer' : 'Pair camera' }}</h2><p>Same Wi-Fi or hotspot</p></div>
                @if (session()!.addresses.length > 1) { <select aria-label="Wi-Fi address" [value]="qrAddress()" (change)="qrAddress.set($any($event.target).value); refreshQR()">@for (candidate of session()!.addresses; track candidate) { <option [value]="candidate.split(': ')[1]">{{ candidate }}</option> }</select> }
                @if (qrImage()) { <figure class="pairing-qr"><img [src]="qrImage()" alt="Pairing QR"></figure> } @else { <p>Preparing QR…</p> }
              }
            } @else {
              @if (!session()?.authenticated) { <button class="primary" [disabled]="!native || networkBusy() || recordingActive()" (click)="scanAndConnect()">Scan QR</button> }
              @if (session()?.authenticated && role() === 'camera') { <button (click)="enterCameraView()">Open camera</button> }
            }
            @if (networkError()) { <p class="error" role="alert">{{ networkError() }}</p> }
          </section>
          @if (role() === 'host' && (session()?.authenticated || session()?.hasPlayableReview)) {
            <section class="host-review"><button class="primary review-button" [disabled]="!session()?.authenticated || networkBusy() || matchReviewBusy() || reviewPending() || transferActive() || hostReviewBusy() || !cameraReadyForReview()" (click)="requestMatchReview()">{{ replayInProgress() ? 'Preparing…' : 'Review last ' + effectiveReviewSeconds() + ' s' }}</button><p aria-live="polite">{{ matchProgress() }}</p>
              @if (replayInProgress()) { <button (click)="replayPanel.set(true)">Progress</button> }
              @if (timingError()) { <p class="error" role="alert">{{ timingError() }}</p> }
              @if (session()?.hasPlayableReview && !reviewPending() && !transferActive()) { @if (!hostReviewReady()) { <p>Previous replay</p> }<div class="replay-actions"><button [disabled]="hostReviewBusy()" (click)="playHostReview()">Replay</button><button [disabled]="hostReviewBusy()" (click)="saveReview()">Save</button></div>@if (saveMessage()) { <p role="status">{{ saveMessage() }}</p> } }
            </section>
            <details><summary>Settings</summary><p>Review {{ effectiveReviewSeconds() }} s</p><p>Buffer {{ session()?.peerRecording?.retentionSeconds ?? retentionSeconds() }} s</p></details>
          }
          @if (role() === 'viewer') {
            <section class="host-review"><button class="primary review-button" [disabled]="!session()?.authenticated || hostReviewBusy() || matchReviewBusy() || reviewPending() || transferActive()" (click)="fetchViewerReplay()">Latest replay</button>
            @if (session()?.hasPlayableReview && !reviewPending() && !transferActive()) { <button [disabled]="hostReviewBusy()" (click)="playHostReview()">Replay</button> }
            @if (session()?.review?.state === 'failed') { <p role="status">{{ session()?.review?.detail }}</p> }
            </section>
          }
          <button class="end-match" [disabled]="networkBusy() || recordingBusy() || matchReviewBusy()" (click)="endMatch()">{{ role() === 'viewer' ? 'Leave' : 'End match' }}</button>
        }
        @if (endMessage()) { <p role="status">{{ endMessage() }}</p> }
        @if (!native) { <p>Phone app required.</p> }
      </div>
      <div [hidden]="!diagnosticsMode()">
      <header><p class="eyebrow">ONE MORE LOOK · P0-08</p><h1>Feasibility harness</h1>
        <p>Local experiments on real phones. Players make the decisions.</p></header>
      <section><h2>Phone role</h2><div class="roles">
        <button [disabled]="sessionActive() || networkBusy()" [attr.aria-pressed]="role() === 'host'" (click)="role.set('host')">Host</button>
        <button [disabled]="sessionActive() || networkBusy()" [attr.aria-pressed]="role() === 'camera'" (click)="role.set('camera')">Camera</button>
      </div><p>{{ role() === 'host' ? 'Coordinates review requests and playback.' : 'Records footage and supplies recent clips.' }}</p>
      <p>Stop the session before changing roles.</p></section>
      <section><h2>Native diagnostics</h2><p>Runtime: {{ runtime }}</p>
        <button (click)="run('ping')" [disabled]="busy() || !native">{{ busy() ? 'Checking…' : 'Native ping' }}</button>
        <button (click)="run('permission')" [disabled]="busy() || !native">Request camera permission</button>
        @if (!native) { <p>Browser preview only. Native checks require the installed phone app.</p> }
        <div aria-live="polite">
          @if (diagnostics(); as d) {
            <dl><dt>Native platform</dt><dd>{{ d.platform }}</dd><dt>App version</dt><dd>{{ d.appVersion }}</dd>
              <dt>OS version</dt><dd>{{ d.osVersion }}</dd><dt>Camera permission</dt><dd>{{ d.cameraPermission }}</dd></dl>
          }
          @if (error()) { <p class="error" role="alert">{{ error() }}</p> }
        </div>
        <p>Permission denial can be changed in the phone’s app settings. Microphone access is not requested.</p>
      </section>
      <section><h2>Offline connection</h2>
        <p>Join the same local Wi-Fi network manually. Keep both apps foreground. No computer coordinates this session.</p>
        @if (!networkSupported) { <p>Connection checks require an installed iPhone or Android app.</p> }
        @if (role() === 'host') {
          <button [disabled]="!networkSupported || sessionActive() || networkBusy()" (click)="networkAction('start')">Start host & show QR</button>
          @if (session()?.state === 'listening') {
            @if (session()!.addresses.length > 1) {
              <label>Host network address<select [value]="qrAddress()" (change)="qrAddress.set($any($event.target).value); refreshQR()">
                @for (candidate of session()!.addresses; track candidate) { <option [value]="candidate.split(': ')[1]">{{ candidate }}</option> }
              </select></label>
            }
            @if (qrImage()) { <figure class="pairing-qr"><img [src]="qrImage()" alt="Scan this code from the camera phone to pair"><figcaption>Camera phone: tap Scan host QR & connect.</figcaption></figure> }
          }
        } @else {
          <button [disabled]="!networkSupported || sessionActive() || networkBusy() || recordingActive() || recordingBusy()" (click)="scanAndConnect()">Scan host QR & connect</button>
        }
        <p>QR pairing works on the Wi-Fi network you already joined. Start a new host session to replace its code.</p>
        <details><summary>Manual connection options</summary>
        <label>Session secret (32 lowercase hex characters)
          <input type="password" autocomplete="off" autocapitalize="off" spellcheck="false" [value]="secret()"
            [disabled]="sessionActive() || networkBusy()" (input)="secret.set($any($event.target).value)">
        </label>
        @if (role() === 'host') {
          <button [disabled]="!networkSupported || sessionActive() || networkBusy()" (click)="networkAction('generate')">Generate secret</button>
          @if (secret()) { <details><summary>Show secret for manual pairing</summary><code>{{ secret() }}</code></details> }
        }
        <label>Port<input type="number" min="1024" max="65535" [value]="port()" [disabled]="sessionActive() || networkBusy()" (input)="port.set(+$any($event.target).value)"></label>
        @if (role() === 'camera') {
          <label>Host IPv4 address<input type="text" inputmode="decimal" placeholder="Address shown on host" autocomplete="off" [value]="address()"
            [disabled]="sessionActive() || networkBusy()" (input)="address.set($any($event.target).value)"></label>
        }
        <button [disabled]="!networkSupported || sessionActive() || networkBusy()" (click)="networkAction('start')">{{ role() === 'host' ? 'Start host' : 'Connect camera' }}</button>
        </details>
        <button [disabled]="!networkSupported || networkBusy()" (click)="networkAction('stop')">Stop session</button>
        <button [disabled]="!session()?.authenticated || networkBusy()" (click)="networkAction('ping')">Send peer ping</button>
        <button [disabled]="!session()?.authenticated || networkBusy()" (click)="networkAction('status')">Request peer status</button>
        <div aria-live="polite">
          @if (session(); as s) {
            <dl><dt>Connection</dt><dd>{{ s.state }}</dd><dt>Peer authenticated</dt><dd>{{ s.authenticated ? 'Yes' : 'No' }}</dd>
              <dt>Requests received</dt><dd>{{ s.pingsReceived }}</dd><dt>Replies received</dt><dd>{{ s.repliesReceived }}</dd>
              <dt>Last round trip</dt><dd>{{ s.lastRoundTripMs === undefined ? 'Not measured' : s.lastRoundTripMs.toFixed(1) + ' ms' }}</dd></dl>
            <p>{{ s.detail }}</p>
            @if (role() === 'host') {
              <p>Candidate host addresses (enter only the IP on camera):</p>
              @for (candidate of s.addresses; track candidate) { <p><code>{{ candidate }}</code></p> }
              @if (!s.addresses.length) { <p>No Wi-Fi/hotspot IPv4 address found. Check the network and restart host.</p> }
            }
          }
          @if (networkError()) { <p class="error" role="alert">{{ networkError() }}</p> }
        </div>
        @if (runtime === 'ios') { <p>Local Network access is requested by outgoing connections; a listening host alone may not show a prompt. Permission errors require checking Settings.</p> }
        @else { <p>Join Wi-Fi manually. Android camera connections use the Wi-Fi network; QR scanning requires camera permission.</p> }
        <p>Status messages are authenticated; sample and recording video packets are encrypted. Backgrounding stops the session; restart after returning.</p>
      </section>
      <section><h2>Camera-to-host review</h2>
        @if (session()?.transfer; as t) { @if (t.durationSeconds) { <p>Transfer {{ ((t.dataMs ?? 0) / 1000).toFixed(2) }} s · Verify {{ ((t.verificationMs ?? 0) / 1000).toFixed(2) }} s · {{ t.windowChunks ?? 1 }} chunks per acknowledgement</p> } }
        <p>Pair first, then start recording on the Camera phone. Clock measurement uses eight authenticated exchanges. Review stays anchored to the native tap timestamp, even with delivery delay.</p>
        <button [disabled]="!session()?.authenticated || reviewPending()" (click)="timingAction('measure')">Measure phone clocks</button>
        @if (session()?.clock; as c) { <p>{{ c.samples }} samples · peer minus this phone {{ (c.offsetUs / 1000).toFixed(2) }} ms · network uncertainty ±{{ (c.uncertaintyUs / 1000).toFixed(2) }} ms</p> }
        @if (role() === 'host') {
          <label>Injected request delay<select [value]="reviewDelayMs()" (change)="reviewDelayMs.set(+$any($event.target).value)"><option value="0">None</option><option value="2000">2 seconds</option><option value="5000">5 seconds</option></select></label>
          <button [disabled]="!session()?.authenticated || (session()?.clock?.samples ?? 0) < 4 || reviewPending() || transferActive() || hostReviewBusy()" (click)="timingAction('review')">Request review at this tap</button>
          <label><input type="checkbox" [checked]="autoPlayReview()" (change)="autoPlayReview.set($any($event.target).checked)"> Play automatically when the recording is verified</label>
          <label>Host playback speed<select [value]="hostPlaybackRate()" (change)="hostPlaybackRate.set(+$any($event.target).value)"><option value="1">1×</option><option value="0.5">0.5×</option><option value="0.25">0.25×</option></select></label>
          <button [disabled]="!hostReviewReady() || hostReviewBusy()" (click)="playHostReview()">Play verified recording review</button>
          <button [disabled]="!hostReviewReady() || hostReviewBusy()" (click)="inspectHostFrame(0)">Inspect host first frame</button>
          <button [disabled]="!hostReviewReady() || !hostFrame() || hostReviewBusy()" (click)="inspectHostFrame(hostFrame()!.frameCount - 1)">Host last frame</button>
          <button [disabled]="!hostReviewReady() || !hostFrame() || hostReviewBusy() || hostFrame()!.index === 0" (click)="inspectHostFrame(hostFrame()!.index - 1)">Host previous frame</button>
          <button [disabled]="!hostReviewReady() || !hostFrame() || hostReviewBusy() || hostFrame()!.index + 1 >= hostFrame()!.frameCount" (click)="inspectHostFrame(hostFrame()!.index + 1)">Host next frame</button>
          @if (hostFrame(); as f) { <figure><img style="max-width:100%" [src]="'data:image/png;base64,' + f.pngBase64" alt="Actual recorded frame received from Camera"><figcaption>Frame {{ f.index + 1 }} / {{ f.frameCount }} · clip PTS {{ f.timestampUs }} µs · original Camera PTS {{ f.sourceTimestampUs }} µs</figcaption></figure> }
          <p>Camera keeps recording during extraction and encrypted transfer. Host playback waits for the checksum and recorded-frame decoding checks. Close playback before another request.</p>
        }
        @if (session()?.transfer?.media === 'recording') {
          <p>{{ session()?.transfer?.state }} · {{ session()?.transfer?.detail }}</p>
          <progress [value]="session()?.transfer?.bytes ?? 0" [max]="session()?.transfer?.totalBytes || 1"></progress>
          <p>{{ session()?.transfer?.bytes }} / {{ session()?.transfer?.totalBytes }} bytes · Checksum: {{ session()?.transfer?.checksumVerified ? 'verified' : 'pending' }}</p>
          @if (session()?.transfer?.recording; as m) { <p>Camera source {{ m.sourceFirstUs }}–{{ m.sourceLastUs }} µs · final frame minus mapped tap {{ m.endpointErrorUs }} µs · configuration {{ m.retentionSeconds }} / {{ m.reviewSeconds }} s</p> }
        }
        @if (session()?.review; as r) { <p>{{ r.detail ?? r.state }} · tap {{ r.peerTapUs }} µs · injected delay {{ r.injectedDelayMs ?? 0 }} ms</p> }
        @if (session()?.review?.verifiedElapsedMs != null) { <p>Tap → verified host clip: {{ (session()!.review!.verifiedElapsedMs! / 1000).toFixed(2) }} s</p> }
        @if (session()?.review?.tapToPlayMs != null) { <p>Tap → playback started: {{ (session()!.review!.tapToPlayMs! / 1000).toFixed(2) }} s · target ≤30 s (includes delivery delay and any wait before Play)</p> }
        <p>If a review fails, close playback, reconnect if needed, measure clocks and request again. Retry uses a new tap and transfers from the beginning; unavailable footage is an error.</p>
        @if (timingError()) { <p class="error" role="alert">{{ timingError() }}</p> }
        <p>Measure again after reconnect or after 30 seconds. Network uncertainty excludes sensor exposure/clock drift and bridge scheduling; this is not frame-perfect synchronization.</p>
      </section>
      <section><h2>Sample video transfer</h2>
        @if (!transferSupported) { <p>Video transfer requires the installed Android or iPhone app.</p> } @else {
        <p>Generate a synthetic 20-second MP4 on the camera phone, send it, then play the verified file on the host.</p>
        @if (role() === 'camera') {
          <button [disabled]="!networkSupported || transferBusy() || transferActive() || recordingActive() || recordingBusy()" (click)="sampleAction('generate')">Generate 20-second sample</button>
          <p>{{ sample().ready ? 'Sample ready: ' + sample().bytes + ' bytes' : 'No generated sample' }}</p>
          <label><input type="checkbox" [checked]="slowTransfer()" [disabled]="transferActive()" (change)="slowTransfer.set($any($event.target).checked)"> Slow transfer for interruption test</label>
          <button [disabled]="!sample().ready || !session()?.authenticated || transferBusy() || transferActive()" (click)="sampleAction('send')">Send sample to host</button>
        } @else {
          <button [disabled]="reviewPending() || hostReviewBusy() || session()?.transfer?.media !== 'sample' || session()?.transfer?.state !== 'ready' || !session()?.transfer?.checksumVerified || transferBusy()" (click)="sampleAction('play')">Play verified sample</button>
        }
        <button [disabled]="!networkSupported || transferBusy() || transferActive() || reviewPending() || hostReviewBusy()" (click)="sampleAction('cleanup')">Delete temporary samples and reviews</button>
        @if (transferBusy()) { <p>Working…</p> }
        @if (session()?.transfer?.media !== 'recording') { @if (session()?.transfer; as t) {
          <p>{{ t.state }} · {{ t.detail }}</p>
          <progress [value]="t.bytes" [max]="t.totalBytes || 1"></progress>
          <p>{{ t.bytes }} / {{ t.totalBytes }} bytes · Checksum: {{ t.checksumVerified ? 'verified' : 'pending' }}</p>
          @if (t.requestId) { <p>Request: <code>{{ t.requestId }}</code></p> }
          @if (t.sha256) { <details><summary>SHA-256</summary><code>{{ t.sha256 }}</code></details> }
          @for (attempt of t.attempts ?? []; track attempt.requestId) {
            <p>{{ attempt.requestId }}: {{ attempt.totalBytes }} bytes in {{ attempt.durationSeconds?.toFixed(2) }} s · {{ attempt.throughputMBps?.toFixed(2) }} MB/s</p>
          }
        }
        }
        @if (transferError()) { <p class="error" role="alert">{{ transferError() }}</p> }
        <p>Repeat Send sample three times. To test interruption, enable slow transfer and stop the session partway through; reconnect and retry. Partial files cannot be played.</p>
        }
      </section>
      <section><h2>Rolling camera recording</h2>
      @if (!recordingSupported) { <p>Camera recording requires an installed Android or iPhone app.</p> } @else {
        <p>Use the live preview to position the phone. Rear camera, no audio; keep this app on screen.</p>
        <div id="recording-preview" class="recording-preview"><span>{{ recordingActive() ? 'Live rear camera' : recordingStarting() ? 'Opening rear camera…' : 'Live camera view appears here when you start' }}</span></div>
        <p aria-live="polite"><strong>{{ recordingStarting() ? 'Starting camera…' : recording()?.state === 'recording' ? '● Recording — live camera active' : recording()?.state === 'stopping' ? 'Stopping recording…' : 'Camera stopped' }}</strong></p>
        @if (recordingError()) { <p class="error" role="alert">{{ recordingError() }}</p> }
        <label>Retention seconds (30–180)<input type="number" min="30" max="180" step="1" [value]="retentionSeconds()" [disabled]="recordingActive() || recordingBusy()" (input)="retentionSeconds.set(+$any($event.target).value)"></label>
        <label>Review seconds (5–30)<input type="number" min="5" max="30" step="1" [value]="reviewSeconds()" [disabled]="recordingActive() || recordingBusy()" (input)="reviewSeconds.set(+$any($event.target).value)"></label>
        <p>Experiment defaults: 120 / 20 seconds. Review must be at least 10 seconds shorter than retention. Starting a new experiment deletes the previous recording and clip.</p>
        <button [disabled]="recordingActive() || recordingBusy() || networkBusy() || transferBusy()" (click)="recordingAction('start')">Start rear camera</button>
        <button [disabled]="!recordingActive() && !recordingStarting()" (click)="recordingAction('stop')">Stop recording</button>
        <button [disabled]="recording()?.state !== 'recording' || recordingBusy() || (recording()?.elapsedSeconds ?? 0) < reviewSeconds()" (click)="recordingAction('extract')">Extract latest review clip</button>
        <label>Clip playback speed<select [value]="playbackRate()" (change)="playbackRate.set(+$any($event.target).value)"><option value="1">1×</option><option value="0.5">0.5×</option><option value="0.25">0.25×</option></select></label>
        <button [disabled]="!recording()?.extraction?.ready || recordingBusy() || frameBusy()" (click)="recordingAction('play')">Play recording clip</button>
        <p>Recorded-frame inspection (close playback first)</p>
        <button [disabled]="!recording()?.extraction?.ready || frameBusy()" (click)="inspectFrame(0)">Inspect first frame</button>
        <button [disabled]="!frame() || frameBusy()" (click)="inspectFrame(frame()!.frameCount - 1)">Last frame</button>
        <button [disabled]="!frame() || frameBusy() || frame()!.index === 0" (click)="inspectFrame(frame()!.index - 1)">Previous frame</button>
        <button [disabled]="!frame() || frameBusy() || frame()!.index + 1 >= frame()!.frameCount" (click)="inspectFrame(frame()!.index + 1)">Next frame</button>
        @if (frameBusy()) { <p>Decoding recorded frame…</p> }
        @if (frame(); as f) { <figure><img style="max-width:100%" [src]="'data:image/png;base64,' + f.pngBase64" alt="Decoded frame from this recording clip"><figcaption>Frame {{ f.index + 1 }} / {{ f.frameCount }} · recorded PTS {{ (f.timestampUs / 1000).toFixed(3) }} ms</figcaption></figure> }
        @if (frameError()) { <p class="error" role="alert">{{ frameError() }}</p> }
        <button [disabled]="recordingActive() || recordingBusy()" (click)="recordingAction('cleanup')">Delete recording experiment</button>
        <button (click)="readRecordingReport()">Read full experiment report</button>
        @if (fullRecordingReport()) { <label>Metadata report — select and copy to preserve results<textarea readonly rows="12" [value]="fullRecordingReport()" (focus)="$any($event.target).select()"></textarea></label> }
        @if (recording(); as r) {
          <div aria-live="polite"><p [class.error]="r.state === 'failed'">{{ r.state }} · {{ r.detail }}</p>
          <dl><dt>Elapsed / buffered</dt><dd>{{ r.elapsedSeconds.toFixed(1) }} / {{ r.bufferedSeconds.toFixed(1) }} s</dd>
            <dt>Selected capture</dt><dd>{{ r.selection.width ?? '—' }} × {{ r.selection.height ?? '—' }} · AE {{ r.selection.aeRange ?? '—' }} fps</dd>
            <dt>Measured encoder / capture input fps</dt><dd>{{ r.effectiveFps.toFixed(2) }} / {{ r.sensorFps.toFixed(2) }}</dd>
            <dt>Encoded / capture input frames</dt><dd>{{ r.encodedFrames }} / {{ r.sensorFrames }}</dd>
            <dt>Largest encoded interval</dt><dd>{{ r.maxFrameDeltaMs.toFixed(2) }} ms · {{ r.intervalsOver50ms }} intervals above 50 ms</dd>
            <dt>Largest capture input interval / failures or drops</dt><dd>{{ r.maxSensorDeltaMs.toFixed(2) }} ms / {{ r.captureFailures }}</dd>
            <dt>Storage / peak</dt><dd>{{ (r.storageBytes / 1048576).toFixed(2) }} / {{ (r.peakStorageBytes / 1048576).toFixed(2) }} MiB · cap {{ r.maxStorageBytes / 1048576 }} MiB</dd>
            <dt>Total encoded bytes written</dt><dd>{{ (r.totalVideoBytesWritten / 1048576).toFixed(2) }} MiB</dd>
            <dt>Closed / pinned segments</dt><dd>{{ r.closedSegments }} / {{ r.pinnedSegments }}</dd>
          </dl><p>{{ r.selection.fallback }}</p><p>{{ r.selection.sensorMetric }}</p>
          <p [class.error]="r.extraction.state === 'failed'">Extraction: {{ r.extraction.state }} · {{ r.extraction.detail }}</p>
          @if (r.extraction.ready) { <p>{{ r.extraction.durationSeconds?.toFixed(2) }} s · {{ r.extraction.segments }} segments · {{ r.extraction.effectiveFps?.toFixed(2) }} fps · keyframe lead-in {{ r.extraction.leadInSeconds?.toFixed(2) }} s · {{ r.extraction.decodedFrames }} decoded smoke-check frames</p> }
          </div>
          @if (r.extraction.endpointErrorUs !== undefined) { <p>Actual final frame minus mapped tap: {{ (r.extraction.endpointErrorUs! / 1000).toFixed(3) }} ms</p> }
          <details><summary>Recording diagnostics (no footage or paths)</summary><pre>{{ recordingReport() }}</pre></details>
        }
        <p>Timestamp intervals above 50 ms flag investigation; they do not prove a visible gap. Inspect a moving subject or timer across clip boundaries. Backgrounding stops capture. Host review requests send the extracted clip over the paired local connection.</p>
      }
      </section>
      </div>
    </main>`
})
class App implements OnDestroy {
  readonly cameraFullScreen = signal(false);
  readonly cameraControlsVisible = signal(true);
  private cameraHideTimer: ReturnType<typeof setTimeout> | null = null;
  showCameraControls() {
    this.cameraControlsVisible.set(true);
    if (this.cameraHideTimer) clearTimeout(this.cameraHideTimer);
    this.cameraHideTimer = setTimeout(() => this.cameraControlsVisible.set(false), 3500);
  }
  toggleCameraControls() {
    if (this.cameraControlsVisible()) { this.cameraControlsVisible.set(false); if (this.cameraHideTimer) clearTimeout(this.cameraHideTimer); }
    else this.showCameraControls();
  }
  readonly replayPanel = signal(false);
  readonly replayWaitSeconds = signal(0);
  private replayTappedAt = 0;
  async enterCameraView() { this.showCameraControls(); this.cameraFullScreen.set(true); await new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))); await this.updateRecordingPreview(); }
  async startMatchRecording() {
    await this.recordingAction('start');
  }
  leaveCameraView() { this.cameraFullScreen.set(false); this.previewLayoutChanged(); }
  cameraReadyForReview() { const camera = this.session()?.peerRecording; return camera?.state === 'recording' && (camera.bufferedSeconds ?? camera.elapsedSeconds) >= this.effectiveReviewSeconds() + 1; }
  replayInProgress() { return this.matchReviewBusy() || this.reviewPending() || this.transferActive(); }
  replayHeading() {
    if (this.matchReviewBusy()) return 'Preparing…';
    if (this.timingError() || this.session()?.review?.state === 'failed') return 'Unavailable';
    if (this.hostReviewReady()) return 'Ready';
    if (this.session()?.transfer?.state === 'receiving') return 'Receiving…';
    return 'Preparing…';
  }
  replayExplanation() {
    if (this.matchReviewBusy()) return 'Checking the phone connection and matching the moment you tapped.';
    if (this.timingError()) return 'Check the message below, then try a new replay.';
    if (this.session()?.review?.state === 'failed') return this.session()?.review?.detail || 'Check the camera and connection, then retry.';
    if (this.hostReviewReady()) return 'The recent footage is verified. Playback opens automatically; use Watch replay to open it again.';
    if (this.session()?.transfer?.state === 'receiving') return 'The camera is sending the recorded footage. Playback opens when verification finishes.';
    if (this.matchReviewBusy()) return 'Checking the phone connection and matching the moment you tapped.';
    return 'The camera is preparing footage ending at your tap. Keep both apps open.';
  }
  readonly diagnosticsMode = signal(false);
  readonly matchRoleChosen = signal(false);
  readonly matchReviewBusy = signal(false);
  readonly settingsMessage = signal('');
  readonly frameZoom = signal(1);
  readonly saveMessage = signal('');
  async saveReview() {
    if (this.hostReviewBusy()) return;
    this.hostReviewBusy.set(true); this.saveMessage.set('Saving replay…');
    try { await Feasibility.saveReceivedReview(); this.saveMessage.set('Saved'); }
    catch (error) { this.saveMessage.set(error instanceof Error ? error.message : String(error)); }
    finally { this.hostReviewBusy.set(false); }
  }
  readonly endMessage = signal('');
  readonly showHostQR = signal(false);
  readonly viewerQR = signal(false);
  readonly viewerSecret = signal('');
  qrKeyReset() { this.qrKey = ''; void this.refreshQR(); }
  async fetchViewerReplay() {
    if (this.matchReviewBusy() || this.hostReviewBusy()) return;
    this.matchReviewBusy.set(true); this.timingError.set(''); this.pendingReviewMode = 'video';
    this.replayTappedAt = performance.now(); this.replayWaitSeconds.set(0); this.replayPanel.set(true);
    try { await Feasibility.fetchViewerReplay(); await this.refresh(); this.autoReviewId = this.session()?.review?.requestId ?? ''; }
    catch (error) { this.timingError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.matchReviewBusy.set(false); }
  }

  readonly toggleQR = (value: boolean) => !value;
  private openCameraAfterPairing = false;
  private reconnectAt = 0;
  private reconnectDelay = 2000;
  private matchEnding = false;
  async chooseMatchRole(role: 'host' | 'camera' | 'viewer') {
    this.matchEnding = false; this.reconnectAt = 0; this.reconnectDelay = 2000;
    this.role.set(role); this.matchRoleChosen.set(true); this.showHostQR.set(false);
    if (!this.native) return;
    if (role === 'host') await this.networkAction('start');
    else await this.scanAndConnect();
  }
  private openPairedCamera() {
    if (!this.openCameraAfterPairing || !this.session()?.authenticated || this.networkBusy() || this.recordingBusy()) return;
    this.openCameraAfterPairing = false;
    if (this.role() === 'camera' && !this.recordingActive()) void this.startMatchRecording();
  }
  toggleDiagnostics() { this.diagnosticsMode.update(value => !value); this.previewLayoutChanged(); }
  effectiveReviewSeconds() { return this.session()?.peerRecording?.reviewSeconds ?? this.session()?.transfer?.recording?.reviewSeconds ?? this.reviewSeconds(); }
  matchProgress() {
    const s = this.session();
    if (s?.review?.state === 'failed') return s.review.detail || 'Replay unavailable. Check recording and connection, then retry.';
    if (s?.transfer?.state === 'receiving') return 'Receiving…';
    if (this.hostReviewReady()) return '';
    if (this.matchReviewBusy() || this.reviewPending()) return 'Preparing…';
    const camera = s?.peerRecording;
    if (camera?.state !== 'recording') return this.session()?.authenticated ? 'Camera stopped' : '';
    const remaining = Math.max(0, Math.ceil(this.effectiveReviewSeconds() + 1 - (camera.bufferedSeconds ?? camera.elapsedSeconds)));
    return remaining > 0 ? 'Ready in ' + remaining + ' s' : '';
  }
  saveMatchSettings() {
    if (this.recordingActive() || this.recordingBusy()) return;
    const retentionSeconds = this.retentionSeconds(), reviewSeconds = this.reviewSeconds();
    if (!Number.isInteger(retentionSeconds) || !Number.isInteger(reviewSeconds) || retentionSeconds < 30 || retentionSeconds > 180 || reviewSeconds < 5 || reviewSeconds > 30 || reviewSeconds > retentionSeconds - 10) { this.settingsMessage.set('Use whole seconds: retention 30–180, review 5–30, with a 10-second gap.'); return; }
    try { localStorage.setItem('cricket-match-settings', JSON.stringify({ retentionSeconds, reviewSeconds })); this.settingsMessage.set('Saved for the next recording.'); } catch { this.settingsMessage.set('Settings apply now; this phone could not save them.'); }
  }
  async requestMatchReview() {
    if (this.matchReviewBusy() || this.reviewPending() || this.transferActive()) return;
    this.pendingReviewMode = this.reviewMode();
    this.replayPanel.set(true); this.replayTappedAt = performance.now(); this.replayWaitSeconds.set(0);
    this.matchReviewBusy.set(true); this.timingError.set(''); this.hostFrame.set(null); this.autoReviewId = '';
    try {
      await Feasibility.requestMatchReview();
      const status = await Feasibility.sessionStatus(); this.session.set(status);
      this.autoReviewId = status.review?.requestId ?? '';
    } catch (error) { this.timingError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.matchReviewBusy.set(false); }
  }
  async endMatch() {
    if (this.role() === 'viewer') {
      if (this.hostReviewBusy()) return;
      this.closeFrameReview(); await Feasibility.stopSession(); await Feasibility.cleanupSamples();
      this.secret.set(''); this.matchRoleChosen.set(false); this.session.set(null); return;
    }
    if (!window.confirm('End match and delete temporary footage?')) return;
    if (this.networkBusy()) return;
    this.matchEnding = true; this.openCameraAfterPairing = false; this.cameraFullScreen.set(false); this.closeFrameReview();
    this.networkBusy.set(true); this.endMessage.set('Ending…');
    try {
      const peer = await Feasibility.endPeerMatch();
      await Feasibility.stopRecording(); await Feasibility.stopSession();
      await Feasibility.cleanupRecording(); await Feasibility.cleanupSamples();
      this.secret.set(''); this.qrImage.set(''); this.autoReviewId = ''; this.hostFrame.set(null);
      await this.refresh(); this.matchRoleChosen.set(false);
      this.endMessage.set(peer.acknowledged ? 'Match ended' : 'Ended here. End the other phone too.');
    } catch (error) { this.endMessage.set('Cleanup unfinished: ' + (error instanceof Error ? error.message : String(error)) + '. Close playback and retry End match.'); }
    finally { this.networkBusy.set(false); this.openPairedCamera(); }
  }
  readonly runtime = Capacitor.getPlatform();
  readonly native = Capacitor.isNativePlatform();
  readonly role = signal<'host' | 'camera' | 'viewer'>('host');
  readonly busy = signal(false);
  readonly diagnostics = signal<Diagnostics | null>(null);
  readonly error = signal('');
  readonly networkSupported = this.native && ['ios', 'android'].includes(this.runtime);
  readonly transferSupported = this.networkSupported;
  readonly recordingSupported = this.networkSupported;
  readonly recording = signal<RecordingStatus | null>(null);
  readonly playbackRate = signal(1);
  readonly reviewDelayMs = signal(0);
  readonly timingError = signal('');
  readonly autoPlayReview = signal(true);
  readonly hostPlaybackRate = signal(1);
  readonly hostFrame = signal<RecordedFrame | null>(null);
  readonly hostReviewBusy = signal(false);
  private autoReviewId = '';
  reviewPending() { return ['requesting', 'transferring'].includes(this.session()?.review?.state ?? ''); }
  hostReviewReady() { const s = this.session(); return s?.review?.state === 'ready' && s.transfer?.media === 'recording' && s.transfer.state === 'ready' && s.transfer.checksumVerified && s.review.requestId === s.transfer.reviewId; }
  async playHostReview() {
    if (this.hostReviewBusy()) return;
    this.hostReviewBusy.set(true); this.timingError.set('');
    try { this.videoPanel.set(true); await Feasibility.playReceivedReview({ rate: this.hostPlaybackRate() }); }
    catch (error) { this.videoPanel.set(false); this.timingError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.hostReviewBusy.set(false); }
  }
  readonly reviewMode = signal<'video' | 'frames'>('video');
  private pendingReviewMode: 'video' | 'frames' = 'video';
  readonly framePanel = signal(false);
  readonly videoPanel = signal(false);
  readonly frameControlsVisible = signal(true);
  private frameHideTimer: ReturnType<typeof setTimeout> | null = null;
  showFrameControls() {
    this.frameControlsVisible.set(true);
    if (this.frameHideTimer) clearTimeout(this.frameHideTimer);
    this.frameHideTimer = setTimeout(() => this.frameControlsVisible.set(false), 3500);
  }
  toggleFrameControls() { if (this.frameControlsVisible()) { this.frameControlsVisible.set(false); if (this.frameHideTimer) clearTimeout(this.frameHideTimer); } else this.showFrameControls(); }

  readonly frameRequested = signal(0);
  private queuedFrame: number | null = null;
  private frameGeneration = 0;
  private frameScrubTimer: ReturnType<typeof setTimeout> | null = null;
  async openFrameReview() {
    this.showFrameControls(); this.replayPanel.set(false); this.frameZoom.set(1); this.framePanel.set(true);
    await this.inspectHostFrame(0);
  }
  closeFrameReview() {
    if (this.frameHideTimer) clearTimeout(this.frameHideTimer);
    this.framePanel.set(false); this.queuedFrame = null; this.frameGeneration++;
    if (this.frameScrubTimer) clearTimeout(this.frameScrubTimer); this.frameScrubTimer = null;
  }
  scrubFrame(index: number, immediate = false) {
    this.frameRequested.set(index);
    if (this.frameScrubTimer) clearTimeout(this.frameScrubTimer);
    if (immediate) { this.frameScrubTimer = null; this.requestFrame(index); }
    else this.frameScrubTimer = setTimeout(() => { this.frameScrubTimer = null; this.requestFrame(index); }, 120);
  }
  requestFrame(index: number) { void this.inspectHostFrame(index); }
  async inspectHostFrame(index: number) {
    this.frameRequested.set(index); this.queuedFrame = index;
    if (this.hostReviewBusy()) return;
    this.hostReviewBusy.set(true); this.timingError.set('');
    const generation = this.frameGeneration;
    try {
      while (this.queuedFrame !== null && generation === this.frameGeneration) {
        const target = this.queuedFrame; this.queuedFrame = null;
        const frame = await Feasibility.inspectReceivedReviewFrame({ index: target });
        if (generation === this.frameGeneration) this.hostFrame.set(frame);
      }
    } catch (error) { this.queuedFrame = null; this.timingError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.hostReviewBusy.set(false); }
  }
  readonly frame = signal<RecordedFrame | null>(null);
  readonly frameBusy = signal(false);
  readonly frameError = signal('');
  async timingAction(action: 'measure' | 'review') {
    this.timingError.set('');
    try {
      if (action === 'measure') await Feasibility.measureReviewClock();
      else {
        this.pendingReviewMode = 'video';
        this.hostFrame.set(null); this.autoReviewId = '';
        await Feasibility.requestTimedReview({ delayMs: this.reviewDelayMs() });
        const status = await Feasibility.sessionStatus(); this.session.set(status);
        if (this.autoPlayReview()) this.autoReviewId = status.review?.requestId ?? '';
      }
    } catch (error) { this.timingError.set(error instanceof Error ? error.message : String(error)); }
  }
  async inspectFrame(index: number) {
    if (this.frameBusy()) return;
    this.frameBusy.set(true); this.frameError.set('');
    try { this.frame.set(await Feasibility.inspectRecordingFrame({ index })); }
    catch (error) { this.frameError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.frameBusy.set(false); }
  }
  readonly recordingBusy = signal(false);
  readonly recordingStarting = signal(false);
  readonly recordingError = signal('');
  readonly fullRecordingReport = signal('');
  private recordingStartAttempt = 0;
  async readRecordingReport() {
    try { this.fullRecordingReport.set((await Feasibility.recordingReport()).report); }
    catch (error) { this.recordingError.set(error instanceof Error ? error.message : String(error)); }
  }
  readonly retentionSeconds = signal(120);
  readonly reviewSeconds = signal(20);
  recordingActive() { return ['starting', 'recording', 'stopping'].includes(this.recording()?.state ?? 'idle'); }
  recordingReport() { return JSON.stringify(this.recording(), null, 2); }
  async recordingAction(action: 'start' | 'stop' | 'extract' | 'play' | 'cleanup') {
    if ((this.recordingBusy() || this.frameBusy()) && action !== 'stop') return;
    if (['start', 'extract', 'cleanup'].includes(action)) this.frame.set(null);
    if (action !== 'stop') this.recordingBusy.set(true);
    this.recordingError.set('');
    const attempt = action === 'start' || action === 'stop' ? ++this.recordingStartAttempt : this.recordingStartAttempt;
    try {
      if (action === 'start') {
        this.fullRecordingReport.set('');
        const retentionSeconds = this.retentionSeconds(), reviewSeconds = this.reviewSeconds();
        if (!Number.isInteger(retentionSeconds) || !Number.isInteger(reviewSeconds) || retentionSeconds < 30 || retentionSeconds > 180 || reviewSeconds < 5 || reviewSeconds > 30 || reviewSeconds > retentionSeconds - 10) throw new Error('Use retention 30–180 and review 5–30 whole seconds; review must be at least 10 seconds shorter.');
        const permission = await Feasibility.requestCameraPermission();
        this.diagnostics.set(permission);
        if (permission.cameraPermission !== 'granted') throw new Error('Camera permission is needed. Allow Camera in the phone’s app settings, then try again.');
        this.recordingStarting.set(true);
        if (!this.diagnosticsMode()) await this.enterCameraView();
        if (!this.cameraFullScreen()) document.getElementById(this.diagnosticsMode() ? 'recording-preview' : 'match-preview')?.scrollIntoView({ block: 'center' });
        await this.updateRecordingPreview();
        if (attempt !== this.recordingStartAttempt) return;
        await Feasibility.startRecording({ retentionSeconds, reviewSeconds });
      } else if (action === 'stop') { await Feasibility.stopRecording(); if (this.diagnosticsMode()) this.cameraFullScreen.set(false); }
      else if (action === 'extract') await Feasibility.extractRecording();
      else if (action === 'play') await Feasibility.playRecordingClip({ rate: this.playbackRate() });
      else await Feasibility.cleanupRecording();
      this.recording.set(await Feasibility.recordingStatus());
    } catch (error) { this.recordingError.set(error instanceof Error ? error.message : String(error)); if (action === 'start' && this.diagnosticsMode()) this.cameraFullScreen.set(false); }
    finally {
      if (action === 'start') this.recordingStarting.set(false);
      if (action !== 'stop') this.recordingBusy.set(false);
      try { this.recording.set(await Feasibility.recordingStatus()); await this.updateRecordingPreview(); }
      catch (error) { if (!this.recordingError()) this.recordingError.set(error instanceof Error ? error.message : String(error)); }
    }
  }
  private previewFrame: number | null = null;
  private readonly previewLayoutChanged = () => {
    if (this.previewFrame !== null) return;
    this.previewFrame = requestAnimationFrame(() => {
      this.previewFrame = null;
      void this.updateRecordingPreview().catch(error => this.recordingError.set(error instanceof Error ? error.message : String(error)));
    });
  };
  private async updateRecordingPreview() {
    if (!this.recordingSupported) return;
    const rect = document.getElementById(this.cameraFullScreen() ? 'camera-full-preview' : this.diagnosticsMode() ? 'recording-preview' : 'match-preview')?.getBoundingClientRect();
    if (!rect) return;
    await Feasibility.setRecordingPreview({ x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      viewportWidth: window.innerWidth, visible: this.recordingStarting() || this.recordingActive(), fullscreen: this.cameraFullScreen() });
  }
  readonly secret = signal('');
  readonly port = signal(8765);
  readonly address = signal('');
  readonly session = signal<SessionStatus | null>(null);
  readonly networkBusy = signal(false);
  readonly networkError = signal('');
  readonly sample = signal<SampleStatus>({ ready: false });
  readonly transferBusy = signal(false);
  readonly transferError = signal('');
  readonly slowTransfer = signal(false);
  readonly qrImage = signal('');
  readonly qrAddress = signal('');
  private qrKey = '';
  private polling = false;
  private statusPoll = 0;
  private readonly timer = this.networkSupported ? setInterval(() => void this.refresh(), 1000) : null;
  private readonly replayBack = () => {
    if (this.framePanel()) this.closeFrameReview();
    else if (this.replayPanel()) this.replayPanel.set(false);
    else if (this.cameraFullScreen()) this.cameraFullScreen.set(false);
  };
  constructor() {
    window.addEventListener('replayBack', this.replayBack);
    effect(() => { const enabled = this.cameraFullScreen() || this.framePanel(); if (this.native) void Feasibility.setFullscreen({ enabled }); });
    if (this.native) void Feasibility.addListener('reviewFrames', () => { this.videoPanel.set(false); void this.openFrameReview(); });

    try {
      const settings = JSON.parse(localStorage.getItem('cricket-match-settings') ?? 'null');
      if (settings && Number.isInteger(settings.retentionSeconds) && Number.isInteger(settings.reviewSeconds) && settings.retentionSeconds >= 30 && settings.retentionSeconds <= 180 && settings.reviewSeconds >= 5 && settings.reviewSeconds <= 30 && settings.reviewSeconds <= settings.retentionSeconds - 10) { this.retentionSeconds.set(settings.retentionSeconds); this.reviewSeconds.set(settings.reviewSeconds); }
    } catch { /* Defaults remain usable when storage is unavailable. */ }
    if (this.networkSupported) void this.refresh();
    window.addEventListener('scroll', this.previewLayoutChanged, { passive: true });
    window.addEventListener('resize', this.previewLayoutChanged);
  }
  ngOnDestroy() {
    if (this.timer) clearInterval(this.timer);
    if (this.frameScrubTimer) clearTimeout(this.frameScrubTimer);
    if (this.frameHideTimer) clearTimeout(this.frameHideTimer);
    if (this.cameraHideTimer) clearTimeout(this.cameraHideTimer);
    if (this.previewFrame !== null) cancelAnimationFrame(this.previewFrame);
    window.removeEventListener('replayBack', this.replayBack);
    window.removeEventListener('scroll', this.previewLayoutChanged);
    window.removeEventListener('resize', this.previewLayoutChanged);
  }
  sessionActive() { return !['stopped', 'failed'].includes(this.session()?.state ?? 'stopped'); }
  private async refresh() {
    if (this.replayInProgress() && this.replayTappedAt) this.replayWaitSeconds.set(Math.floor((performance.now() - this.replayTappedAt) / 1000));
    if (this.polling) return;
    this.polling = true;
    try {
      const status = await Feasibility.sessionStatus();
      if (this.role() === 'host' && status.authenticated && !this.matchReviewBusy() && !this.reviewPending() && ++this.statusPoll % 5 === 0) await Feasibility.requestMatchStatus();
      if (status.review?.requestId !== this.session()?.review?.requestId || status.transfer?.requestId !== this.session()?.transfer?.requestId) this.hostFrame.set(null);
      this.session.set(status);
      if (status.authenticated) { this.reconnectDelay = 2000; this.reconnectAt = 0; }
      if (this.autoReviewId && status.review?.requestId === this.autoReviewId) {
        if (status.review.state === 'ready') { this.autoReviewId = ''; this.replayPanel.set(false); if (this.pendingReviewMode === 'frames') void this.openFrameReview(); else void this.playHostReview(); }
        else if (status.review.state === 'failed') this.autoReviewId = '';
      } if (this.transferSupported) this.sample.set(await Feasibility.sampleStatus()); await this.refreshQR(); }
    catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally {
      if (this.recordingSupported) {
        try {
          const next = await Feasibility.recordingStatus();
          if (next.extraction.sourceLastUs !== this.recording()?.extraction.sourceLastUs) this.frame.set(null);
          this.recording.set(next);
          if (this.cameraFullScreen() && !this.recordingStarting() && next.state === 'failed') this.recordingError.set(next.detail || 'Recording stopped');
          await this.updateRecordingPreview();
        }
        catch (error) { this.recordingError.set(error instanceof Error ? error.message : String(error)); }
      }
      this.polling = false;
      this.openPairedCamera();
      void this.reconnectMatch();
    }
  }
  private async reconnectMatch() {
    if (!this.native || !this.matchRoleChosen() || this.diagnosticsMode() || this.matchEnding || this.networkBusy() || !this.secret() || document.hidden) return;
    const state = this.session();
    if (!state || !(state.state === 'failed' || state.state === 'stopped' && state.detail.startsWith('App backgrounded'))) return;
    if (!this.reconnectAt) { this.reconnectAt = performance.now() + this.reconnectDelay; return; }
    if (performance.now() < this.reconnectAt) return;
    this.reconnectAt = performance.now() + this.reconnectDelay; this.reconnectDelay = Math.min(15000, this.reconnectDelay * 2);
    this.networkBusy.set(true);
    try {
      const options = { secret: this.secret(), port: this.port(), viewerSecret: this.viewerSecret() || undefined };
      if (this.role() === 'host') await Feasibility.startHost(options);
      else if (this.address()) { const connection = { ...options, address: this.address() }; if (this.role() === 'viewer') await Feasibility.connectViewer(connection); else await Feasibility.connectCamera(connection); }
    } catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.networkBusy.set(false); }
  }
  transferActive() { return ['offer', 'sending', 'receiving', 'finishing'].includes(this.session()?.transfer?.state ?? 'idle'); }
  async sampleAction(action: 'generate' | 'send' | 'play' | 'cleanup') {
    if (this.transferBusy()) return;
    this.transferBusy.set(true); this.transferError.set('');
    try {
      if (action === 'generate') this.sample.set(await Feasibility.generateSample());
      else if (action === 'send') await Feasibility.sendSample({ slow: this.slowTransfer() });
      else if (action === 'play') await Feasibility.playReceivedSample();
      else await Feasibility.cleanupSamples();
      await this.refresh();
    } catch (error) { this.transferError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.transferBusy.set(false); }
  }
  async refreshQR() {
    const state = this.session();
    if (this.role() !== 'host' || !['listening', 'connected'].includes(state?.state ?? '') || !this.secret()) {
      this.qrKey = ''; this.qrImage.set(''); return;
    }
    const candidates = state!.addresses.map(value => value.split(': ')[1]).filter(Boolean);
    if (!candidates.includes(this.qrAddress())) this.qrAddress.set(candidates[0] ?? '');
    if (!this.qrAddress()) { this.qrKey = ''; this.qrImage.set(''); return; }
    const qrSecret = this.viewerQR() ? this.viewerSecret() : this.secret();
    const qrPort = (state!.port ?? this.port()) + (this.viewerQR() ? 1 : 0);
    const key = `${this.qrAddress()}:${qrPort}:${qrSecret}`;
    if (key === this.qrKey) return;
    this.qrKey = key; this.qrImage.set('');
    try {
      const result = await Feasibility.createPairingQR({ address: this.qrAddress(), port: qrPort, secret: qrSecret });
      if (this.qrKey === key) this.qrImage.set(result.image);
    } catch (error) {
      if (this.qrKey === key) { this.qrKey = ''; this.networkError.set(error instanceof Error ? error.message : String(error)); }
    }
  }
  async scanAndConnect() {
    if (this.networkBusy()) return;
    this.openCameraAfterPairing = false;
    this.networkBusy.set(true); this.networkError.set('');
    try {
      const options = await Feasibility.scanPairingQR();
      this.address.set(options.address); this.port.set(options.port); this.secret.set(options.secret);
      this.openCameraAfterPairing = this.role() === 'camera' && !this.diagnosticsMode();
      if (this.role() === 'viewer') await Feasibility.connectViewer(options); else await Feasibility.connectCamera(options);
      await this.refresh();
    } catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.networkBusy.set(false); this.openPairedCamera(); }
  }
  async networkAction(action: 'generate' | 'start' | 'stop' | 'ping' | 'status') {
    if (this.networkBusy()) return;
    this.networkBusy.set(true); this.networkError.set('');
    try {
      if (action === 'generate') this.secret.set((await Feasibility.generateSessionSecret()).secret);
      else if (action === 'stop') { await Feasibility.stopSession(); this.secret.set(''); this.qrKey = ''; this.qrImage.set(''); }
      else if (action === 'start') {
        if (this.role() === 'host') { this.secret.set((await Feasibility.generateSessionSecret()).secret); this.viewerSecret.set((await Feasibility.generateSessionSecret()).secret); }
        const options = { secret: this.secret(), port: this.port(), viewerSecret: this.viewerSecret() || undefined };
        if (this.role() === 'host') await Feasibility.startHost(options);
        else await Feasibility.connectCamera({ ...options, address: this.address().trim() });
      } else await Feasibility.sendSessionPing({ status: action === 'status' });
      await this.refresh();
    } catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.networkBusy.set(false); this.openPairedCamera(); }
  }
  async run(action: 'ping' | 'permission') {
    if (this.busy()) return;
    this.busy.set(true); this.error.set(''); this.diagnostics.set(null);
    try {
      const result = await (action === 'ping' ? Feasibility.ping() : Feasibility.requestCameraPermission());
      this.diagnostics.set(result);
    } catch (error) {
      this.error.set(error instanceof Error ? error.message : String(error));
    } finally { this.busy.set(false); }
  }
}
bootstrapApplication(App).catch(console.error);
