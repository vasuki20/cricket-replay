import { Component, OnDestroy, signal } from '@angular/core';
import { bootstrapApplication } from '@angular/platform-browser';
import { Capacitor } from '@capacitor/core';
import { Diagnostics, Feasibility, SessionStatus, SampleStatus, RecordingStatus } from './native';

@Component({
  selector: 'replay-app', standalone: true,
  template: `
    <main>
      <header><p class="eyebrow">CRICKET REPLAY · P0-05</p><h1>Feasibility harness</h1>
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
        <p>Status messages are authenticated; sample video packets are encrypted. Backgrounding stops the session; restart after returning.</p>
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
          <button [disabled]="session()?.transfer?.state !== 'ready' || !session()?.transfer?.checksumVerified || transferBusy()" (click)="sampleAction('play')">Play verified sample</button>
        }
        <button [disabled]="!networkSupported || transferBusy() || transferActive()" (click)="sampleAction('cleanup')">Delete temporary samples</button>
        @if (transferBusy()) { <p>Working…</p> }
        @if (session()?.transfer; as t) {
          <p>{{ t.state }} · {{ t.detail }}</p>
          <progress [value]="t.bytes" [max]="t.totalBytes || 1"></progress>
          <p>{{ t.bytes }} / {{ t.totalBytes }} bytes · Checksum: {{ t.checksumVerified ? 'verified' : 'pending' }}</p>
          @if (t.requestId) { <p>Request: <code>{{ t.requestId }}</code></p> }
          @if (t.sha256) { <details><summary>SHA-256</summary><code>{{ t.sha256 }}</code></details> }
          @for (attempt of t.attempts ?? []; track attempt.requestId) {
            <p>{{ attempt.requestId }}: {{ attempt.totalBytes }} bytes in {{ attempt.durationSeconds?.toFixed(2) }} s · {{ attempt.throughputMBps?.toFixed(2) }} MB/s</p>
          }
        }
        @if (transferError()) { <p class="error" role="alert">{{ transferError() }}</p> }
        <p>Repeat Send sample three times. To test interruption, enable slow transfer and stop the session partway through; reconnect and retry. Partial files cannot be played.</p>
        }
      </section>
      <section><h2>Rolling camera recording</h2>
      @if (!recordingSupported) { <p>Camera recording requires Android. iPhone implementation follows in P0-06.</p> } @else {
        <p>Hold the phone in landscape. Rear camera, no audio; target 1280×720 at 30 fps. Keep this app foreground. Wi-Fi is optional for recording.</p>
        <label>Retention seconds (30–180)<input type="number" min="30" max="180" step="1" [value]="retentionSeconds()" [disabled]="recordingActive() || recordingBusy()" (input)="retentionSeconds.set(+$any($event.target).value)"></label>
        <label>Review seconds (5–30)<input type="number" min="5" max="30" step="1" [value]="reviewSeconds()" [disabled]="recordingActive() || recordingBusy()" (input)="reviewSeconds.set(+$any($event.target).value)"></label>
        <p>Experiment defaults: 120 / 20 seconds. Review must be at least 10 seconds shorter than retention. Starting a new experiment deletes the previous recording and clip.</p>
        <button [disabled]="recordingActive() || recordingBusy() || networkBusy() || transferBusy()" (click)="recordingAction('start')">Start rear camera</button>
        <button [disabled]="!recordingActive()" (click)="recordingAction('stop')">Stop recording</button>
        <button [disabled]="recording()?.state !== 'recording' || recordingBusy() || (recording()?.elapsedSeconds ?? 0) < reviewSeconds()" (click)="recordingAction('extract')">Extract latest review clip</button>
        <button [disabled]="!recording()?.extraction?.ready || recordingBusy()" (click)="recordingAction('play')">Play recording clip</button>
        <button [disabled]="recordingActive() || recordingBusy()" (click)="recordingAction('cleanup')">Delete recording experiment</button>
        <button (click)="readRecordingReport()">Read full experiment report</button>
        @if (fullRecordingReport()) { <label>Metadata report — select and copy to preserve results<textarea readonly rows="12" [value]="fullRecordingReport()" (focus)="$any($event.target).select()"></textarea></label> }
        @if (recording(); as r) {
          <div aria-live="polite"><p [class.error]="r.state === 'failed'">{{ r.state }} · {{ r.detail }}</p>
          <dl><dt>Elapsed / buffered</dt><dd>{{ r.elapsedSeconds.toFixed(1) }} / {{ r.bufferedSeconds.toFixed(1) }} s</dd>
            <dt>Selected capture</dt><dd>{{ r.selection.width ?? '—' }} × {{ r.selection.height ?? '—' }} · AE {{ r.selection.aeRange ?? '—' }} fps</dd>
            <dt>Measured encoder / sensor fps</dt><dd>{{ r.effectiveFps.toFixed(2) }} / {{ r.sensorFps.toFixed(2) }}</dd>
            <dt>Encoded / sensor frames</dt><dd>{{ r.encodedFrames }} / {{ r.sensorFrames }}</dd>
            <dt>Largest encoded interval</dt><dd>{{ r.maxFrameDeltaMs.toFixed(2) }} ms · {{ r.intervalsOver50ms }} intervals above 50 ms</dd>
            <dt>Largest sensor interval / failed captures</dt><dd>{{ r.maxSensorDeltaMs.toFixed(2) }} ms / {{ r.captureFailures }}</dd>
            <dt>Storage / peak</dt><dd>{{ (r.storageBytes / 1048576).toFixed(2) }} / {{ (r.peakStorageBytes / 1048576).toFixed(2) }} MiB · cap {{ r.maxStorageBytes / 1048576 }} MiB</dd>
            <dt>Total encoded bytes written</dt><dd>{{ (r.totalVideoBytesWritten / 1048576).toFixed(2) }} MiB</dd>
            <dt>Closed / pinned segments</dt><dd>{{ r.closedSegments }} / {{ r.pinnedSegments }}</dd>
          </dl><p>{{ r.selection.fallback }}</p>
          <p [class.error]="r.extraction.state === 'failed'">Extraction: {{ r.extraction.state }} · {{ r.extraction.detail }}</p>
          @if (r.extraction.ready) { <p>{{ r.extraction.durationSeconds?.toFixed(2) }} s · {{ r.extraction.segments }} segments · {{ r.extraction.effectiveFps?.toFixed(2) }} fps · keyframe lead-in {{ r.extraction.leadInSeconds?.toFixed(2) }} s · {{ r.extraction.decodedFrames }} decoded smoke-check frames</p> }
          </div>
          <details><summary>Recording diagnostics (no footage or paths)</summary><pre>{{ recordingReport() }}</pre></details>
        }
        @if (recordingError()) { <p class="error" role="alert">{{ recordingError() }}</p> }
        <p>Timestamp intervals above 50 ms flag investigation; they do not prove a visible gap. Inspect a moving subject or timer across clip boundaries. Backgrounding stops capture. Clips stay on this phone.</p>
      }
      </section>
    </main>`
})
class App implements OnDestroy {
  readonly runtime = Capacitor.getPlatform();
  readonly native = Capacitor.isNativePlatform();
  readonly role = signal<'host' | 'camera'>('host');
  readonly busy = signal(false);
  readonly diagnostics = signal<Diagnostics | null>(null);
  readonly error = signal('');
  readonly networkSupported = this.native && ['ios', 'android'].includes(this.runtime);
  readonly transferSupported = this.networkSupported;
  readonly recordingSupported = this.native && this.runtime === 'android';
  readonly recording = signal<RecordingStatus | null>(null);
  readonly recordingBusy = signal(false);
  readonly recordingError = signal('');
  readonly fullRecordingReport = signal('');
  async readRecordingReport() {
    try { this.fullRecordingReport.set((await Feasibility.recordingReport()).report); }
    catch (error) { this.recordingError.set(error instanceof Error ? error.message : String(error)); }
  }
  readonly retentionSeconds = signal(120);
  readonly reviewSeconds = signal(20);
  recordingActive() { return ['starting', 'recording', 'stopping'].includes(this.recording()?.state ?? 'idle'); }
  recordingReport() { return JSON.stringify(this.recording(), null, 2); }
  async recordingAction(action: 'start' | 'stop' | 'extract' | 'play' | 'cleanup') {
    if (this.recordingBusy() && action !== 'stop') return;
    if (action !== 'stop') this.recordingBusy.set(true);
    this.recordingError.set('');
    try {
      if (action === 'start') {
        this.fullRecordingReport.set('');
        const retentionSeconds = this.retentionSeconds(), reviewSeconds = this.reviewSeconds();
        if (!Number.isInteger(retentionSeconds) || !Number.isInteger(reviewSeconds) || retentionSeconds < 30 || retentionSeconds > 180 || reviewSeconds < 5 || reviewSeconds > 30 || reviewSeconds > retentionSeconds - 10) throw new Error('Use retention 30–180 and review 5–30 whole seconds; review must be at least 10 seconds shorter.');
        await Feasibility.startRecording({ retentionSeconds, reviewSeconds });
      } else if (action === 'stop') await Feasibility.stopRecording();
      else if (action === 'extract') await Feasibility.extractRecording();
      else if (action === 'play') await Feasibility.playRecordingClip();
      else await Feasibility.cleanupRecording();
      this.recording.set(await Feasibility.recordingStatus());
    } catch (error) { this.recordingError.set(error instanceof Error ? error.message : String(error)); }
    finally { if (action !== 'stop') this.recordingBusy.set(false); }
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
  private readonly timer = this.networkSupported ? setInterval(() => void this.refresh(), 1000) : null;
  constructor() { if (this.networkSupported) void this.refresh(); }
  ngOnDestroy() { if (this.timer) clearInterval(this.timer); }
  sessionActive() { return !['stopped', 'failed'].includes(this.session()?.state ?? 'stopped'); }
  private async refresh() {
    if (this.polling) return;
    this.polling = true;
    try { this.session.set(await Feasibility.sessionStatus()); if (this.transferSupported) this.sample.set(await Feasibility.sampleStatus()); await this.refreshQR(); }
    catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally {
      if (this.recordingSupported) {
        try { this.recording.set(await Feasibility.recordingStatus()); }
        catch (error) { this.recordingError.set(error instanceof Error ? error.message : String(error)); }
      }
      this.polling = false;
    }
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
    if (this.role() !== 'host' || state?.state !== 'listening' || !this.secret()) {
      this.qrKey = ''; this.qrImage.set(''); return;
    }
    const candidates = state.addresses.map(value => value.split(': ')[1]).filter(Boolean);
    if (!candidates.includes(this.qrAddress())) this.qrAddress.set(candidates[0] ?? '');
    if (!this.qrAddress()) { this.qrKey = ''; this.qrImage.set(''); return; }
    const key = `${this.qrAddress()}:${state.port}:${this.secret()}`;
    if (key === this.qrKey) return;
    this.qrKey = key; this.qrImage.set('');
    try {
      const result = await Feasibility.createPairingQR({ address: this.qrAddress(), port: state.port ?? this.port(), secret: this.secret() });
      if (this.qrKey === key) this.qrImage.set(result.image);
    } catch (error) {
      if (this.qrKey === key) { this.qrKey = ''; this.networkError.set(error instanceof Error ? error.message : String(error)); }
    }
  }
  async scanAndConnect() {
    if (this.networkBusy()) return;
    this.networkBusy.set(true); this.networkError.set('');
    try {
      const options = await Feasibility.scanPairingQR();
      this.address.set(options.address); this.port.set(options.port); this.secret.set(options.secret);
      await Feasibility.connectCamera(options);
      await this.refresh();
    } catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.networkBusy.set(false); }
  }
  async networkAction(action: 'generate' | 'start' | 'stop' | 'ping' | 'status') {
    if (this.networkBusy()) return;
    this.networkBusy.set(true); this.networkError.set('');
    try {
      if (action === 'generate') this.secret.set((await Feasibility.generateSessionSecret()).secret);
      else if (action === 'stop') { await Feasibility.stopSession(); this.secret.set(''); this.qrKey = ''; this.qrImage.set(''); }
      else if (action === 'start') {
        if (this.role() === 'host') this.secret.set((await Feasibility.generateSessionSecret()).secret);
        const options = { secret: this.secret(), port: this.port() };
        if (this.role() === 'host') await Feasibility.startHost(options);
        else await Feasibility.connectCamera({ ...options, address: this.address().trim() });
      } else await Feasibility.sendSessionPing({ status: action === 'status' });
      await this.refresh();
    } catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.networkBusy.set(false); }
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
