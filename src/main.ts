import { Component, signal } from '@angular/core';
import { bootstrapApplication } from '@angular/platform-browser';
import { Capacitor } from '@capacitor/core';
import { Diagnostics, Feasibility } from './native';

@Component({
  selector: 'replay-app', standalone: true,
  template: `
    <main>
      <header><p class="eyebrow">CRICKET REPLAY · P0-02</p><h1>Feasibility harness</h1>
        <p>Local experiments on real phones. Players make the decisions.</p></header>
      <section><h2>Phone role</h2><div class="roles">
        <button [attr.aria-pressed]="role() === 'host'" (click)="role.set('host')">Host</button>
        <button [attr.aria-pressed]="role() === 'camera'" (click)="role.set('camera')">Camera</button>
      </div><p>{{ role() === 'host' ? 'Coordinates review requests and playback.' : 'Records footage and supplies recent clips.' }}</p>
      <p>Role selection is local to this screen; no session has started.</p></section>
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
      <section><h2>Experiment status</h2><dl>
        <dt>Connection</dt><dd>Not implemented — P0-03</dd>
        <dt>Local-network permission</dt><dd>Not tested — P0-03</dd>
        <dt>Capture</dt><dd>Not implemented — P0-05 / P0-06</dd>
        <dt>Buffer / review defaults</dt><dd>120 seconds / 20 seconds</dd>
      </dl><p>Window values are experiment defaults. Configuration and validated bounds follow later.</p></section>
    </main>`
})
class App {
  readonly runtime = Capacitor.getPlatform();
  readonly native = Capacitor.isNativePlatform();
  readonly role = signal<'host' | 'camera'>('host');
  readonly busy = signal(false);
  readonly diagnostics = signal<Diagnostics | null>(null);
  readonly error = signal('');
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
