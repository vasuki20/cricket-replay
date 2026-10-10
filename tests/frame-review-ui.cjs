// Exercise the actual Angular controller with deferred native responses, without phone footage.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('typescript');
const pending = []; let App; let plays = 0;
let viewerConnections = 0, viewerRequests = 0, peerEnds = 0;
let status = { state: 'connected', authenticated: true, addresses: [], review: { requestId: 'replay', state: 'requesting' } };
const signal = value => Object.assign(() => value, { set: next => { value = next; }, update: change => { value = change(value); } });
const native = {
  inspectReceivedReviewFrame: ({ index }) => new Promise(resolve => pending.push({ index, resolve })),
  requestMatchReview: async () => {}, sessionStatus: async () => status,
  playReceivedReview: async () => { plays++; },
  scanPairingQR: async () => ({ address: '192.168.1.2', port: 8766, secret: 'a'.repeat(32) }),
  connectViewer: async () => { viewerConnections++; },
  fetchViewerReplay: async () => { viewerRequests++; status = { ...status, review: { requestId: 'viewer-replay', state: 'requesting' } }; },
  stopSession: async () => {}, cleanupSamples: async () => {},
  endPeerMatch: async () => { peerEnds++; },
  stopRecording: async () => {}, recordingStatus: async () => ({ state: 'stopped', extraction: {} })
};
const context = {
  exports: {}, console, performance, setTimeout, clearTimeout, setInterval, clearInterval,
  requestAnimationFrame: callback => setTimeout(callback, 0), cancelAnimationFrame: clearTimeout,
  localStorage: { getItem: () => null }, document: { hidden: false },
  window: { addEventListener() {}, removeEventListener() {} },
  require: name => {
    if (name === '@angular/core') return { signal, effect: () => {}, Component: () => target => target };
    if (name === '@angular/platform-browser') return { bootstrapApplication: target => { App = target; return Promise.resolve(); } };
    if (name === '@capacitor/core') return { Capacitor: { getPlatform: () => 'web', isNativePlatform: () => false } };
    if (name === './native') return { Feasibility: native, Diagnostics: {} };
    throw Error(name);
  }
};
const code = ts.transpileModule(fs.readFileSync('src/main.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, experimentalDecorators: true } }).outputText;
vm.runInNewContext(code, context);
const tick = () => new Promise(resolve => setImmediate(resolve));
const frame = index => ({ index, frameCount: 600, pngBase64: '', width: 1280, height: 720 });
(async () => {
  const app = new App();
  const opening = app.openFrameReview();
  assert.equal(pending.length, 1); assert.equal(pending[0].index, 0);
  app.requestFrame(10); app.requestFrame(250); app.requestFrame(500);
  assert.equal(pending.length, 1, 'scrubbing does not run concurrent native decoders');
  pending.shift().resolve(frame(0)); await tick();
  assert.equal(pending.length, 1); assert.equal(pending[0].index, 500, 'latest slider position wins');
  app.closeFrameReview(); pending.shift().resolve(frame(500)); await opening;
  assert.equal(app.framePanel(), false); assert.equal(app.hostFrame().index, 0, 'closed review ignores stale decode response');
  app.reviewMode.set('frames'); await app.requestMatchReview();
  app.reviewMode.set('video'); status = { ...status, review: { requestId: 'replay', state: 'ready' } };
  await app.refresh();
  assert.equal(app.framePanel(), true, 'completed replay opens the mode selected at request time');
  assert.equal(plays, 0); assert.equal(pending[0].index, 0);
  app.closeFrameReview(); pending.shift().resolve(frame(0)); await tick(); app.ngOnDestroy();
  app.cameraFullScreen.set(true);
  await app.recordingAction('stop');
  assert.equal(app.cameraFullScreen(), true, 'Stop stays on the single camera screen');
  app.showCameraControls(); assert.equal(app.cameraControlsVisible(), true);
  app.toggleCameraControls(); assert.equal(app.cameraControlsVisible(), false);
  app.toggleCameraControls(); assert.equal(app.cameraControlsVisible(), true);
  app.ngOnDestroy();
  const viewer = new App(); viewer.native = true;
  await viewer.chooseMatchRole('viewer');
  assert.equal(viewerConnections, 1, 'Viewer uses the viewer endpoint');
  assert.equal(viewer.cameraFullScreen(), false, 'Viewer never opens recording');
  await viewer.fetchViewerReplay(); assert.equal(viewerRequests, 1);
  status = { ...status, review: { requestId: 'viewer-replay', state: 'ready' } };
  await viewer.refresh(); await tick(); assert.equal(plays, 1, 'Viewer automatically opens completed video');
  await viewer.endMatch(); assert.equal(peerEnds, 0, 'Leaving viewer never ends the shared match');
  viewer.ngOnDestroy();
  console.log('PASS: full-screen frame review, coalesced scrubbing, stale-response rejection and request-time review mode');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Android Back leaves fullscreen review without backgrounding the activity.
const backApp = new App();
backApp.framePanel.set(true); backApp.replayBack();
if (backApp.framePanel()) throw Error('Back did not close frame fullscreen');
backApp.replayPanel.set(true); backApp.replayBack();
if (backApp.replayPanel()) throw Error('Back did not close replay progress');
console.log('PASS: Android Back closes fullscreen frame/progress views');
