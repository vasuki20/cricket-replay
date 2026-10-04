import { Component, OnDestroy, signal } from '@angular/core';
import { bootstrapApplication } from '@angular/platform-browser';
import { Capacitor } from '@capacitor/core';
import { Diagnostics, Feasibility, SessionStatus } from './native';

@Component({
  selector: 'replay-app', standalone: true,
  template: `
    <main>
      <header><p class="eyebrow">CRICKET REPLAY · P0-03</p><h1>Feasibility harness</h1>
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
        @if (!networkSupported) { <p>Connection experiment currently supports installed iPhone apps. Android verification is deferred.</p> }
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
          <button [disabled]="!networkSupported || sessionActive() || networkBusy()" (click)="scanAndConnect()">Scan host QR & connect</button>
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
        <p>Local Network access is requested by outgoing connections; a listening host alone may not show a prompt. Permission errors require checking Settings.</p>
        <p>Status-only experiment: messages are authenticated but unencrypted. Do not send footage. Backgrounding stops the session; restart after returning.</p>
      </section>
      <section><h2>Experiment status</h2><dl>
        <dt>Capture</dt><dd>Not implemented — P0-05 / P0-06</dd>
        <dt>Buffer / review defaults</dt><dd>120 seconds / 20 seconds</dd>
      </dl><p>Window values are experiment defaults. Configuration and validated bounds follow later.</p></section>
    </main>`
})
class App implements OnDestroy {
  readonly runtime = Capacitor.getPlatform();
  readonly native = Capacitor.isNativePlatform();
  readonly role = signal<'host' | 'camera'>('host');
  readonly busy = signal(false);
  readonly diagnostics = signal<Diagnostics | null>(null);
  readonly error = signal('');
  readonly networkSupported = this.native && this.runtime === 'ios';
  readonly secret = signal('');
  readonly port = signal(8765);
  readonly address = signal('');
  readonly session = signal<SessionStatus | null>(null);
  readonly networkBusy = signal(false);
  readonly networkError = signal('');
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
    try { this.session.set(await Feasibility.sessionStatus()); await this.refreshQR(); }
    catch (error) { this.networkError.set(error instanceof Error ? error.message : String(error)); }
    finally { this.polling = false; }
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
