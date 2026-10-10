import { registerPlugin } from '@capacitor/core';
export interface Diagnostics {
  platform: 'ios' | 'android'; appVersion: string; osVersion: string;
  cameraPermission: string;
}
export interface ReviewClipMetadata extends RecordingConfig {
  sourceFirstUs: number; sourceLastUs: number; requestedHostUs: number;
  requestedSourceUs: number; endpointErrorUs: number; frames: number;
}
export interface TransferStatus {
  media?: "sample" | "recording"; reviewId?: string; recording?: ReviewClipMetadata;
  state: string; detail?: string; requestId?: string; bytes: number; totalBytes: number;
  sha256?: string; checksumVerified: boolean; durationSeconds?: number; throughputMBps?: number; attempts?: TransferStatus[];
}
export interface SampleStatus { ready: boolean; bytes?: number; sha256?: string; durationSeconds?: number; }
// Shared recording/review experiment contract. Files stay native; decoded stills cross the local bridge.
export interface RecordingConfig { retentionSeconds: number; reviewSeconds: number; }
// CSS viewport coordinates. Native preview stays attached while hidden/offscreen; no capture restart.
export interface RecordingPreviewBounds { x: number; y: number; width: number; height: number; viewportWidth: number; visible: boolean; }
export interface RecordingClipStatus {
  state: string; ready: boolean; detail?: string; bytes?: number; durationSeconds?: number;
  frames?: number; effectiveFps?: number; segments?: number; leadInSeconds?: number;
  sourceFirstUs?: number; sourceLastUs?: number; maxFrameDeltaMs?: number;
  intervalsOver50ms?: number; decodedFrames?: number; requestedHostUs?: number; requestedSourceUs?: number; endpointErrorUs?: number;
}
export interface RecordingStatus extends RecordingConfig {
  state: string; detail: string; elapsedSeconds: number; encodedFrames: number; sensorFrames: number;
  effectiveFps: number; sensorFps: number; maxFrameDeltaMs: number; intervalsOver50ms: number;
  maxSensorDeltaMs: number; sensorIntervalsOver50ms: number; captureFailures: number;
  droppedInputFrames?: number; droppedEncoderFrames?: number;
  firstPtsUs: number; lastPtsUs: number; bufferedSeconds: number; closedSegments: number; pinnedSegments: number;
  storageBytes: number; peakStorageBytes: number; totalVideoBytesWritten: number; maxStorageBytes: number;
  selection: { width?: number; height?: number; encodedWidth?: number; encodedHeight?: number; requestedFps?: number; aeRange?: string; encoder?: string;
    rotationDegrees?: number; fallback?: string; sensorMetric?: string; supportedSizes?: string[]; supportedFpsRanges?: string[] };
  extraction: RecordingClipStatus;
}
export interface RecordedFrame { index: number; frameCount: number; timestampUs: number; sourceTimestampUs?: number; width: number; height: number; pngBase64: string; }
export interface SessionStatus {
  clock?: { samples: number; offsetUs: number; uncertaintyUs: number; measuredAtUs: number };
  review?: { requestId?: string; verifiedElapsedMs?: number; tapToPlayMs?: number; state?: string; ok?: boolean; detail?: string; tapUs?: number; peerTapUs?: number; uncertaintyUs?: number; injectedDelayMs?: number; replyElapsedMs?: number };
  transfer?: TransferStatus;
  state: string; detail: string; role: string; authenticated: boolean;
  addresses: string[]; port?: number; pingsReceived: number; repliesReceived: number;
  lastRoundTripMs?: number;
}
export const Feasibility = registerPlugin<{
  playReceivedReview(options: { rate: number }): Promise<void>;
  inspectReceivedReviewFrame(options: { index: number }): Promise<RecordedFrame>;
  measureReviewClock(): Promise<void>;
  requestTimedReview(options: { delayMs: number }): Promise<void>;
  inspectRecordingFrame(options: { index: number }): Promise<RecordedFrame>;
  recordingStatus(): Promise<RecordingStatus>;
  recordingReport(): Promise<{ report: string }>;
  setRecordingPreview(options: RecordingPreviewBounds): Promise<void>;
  startRecording(options: RecordingConfig): Promise<void>;
  stopRecording(): Promise<void>;
  extractRecording(): Promise<void>;
  playRecordingClip(options?: { rate: number }): Promise<void>;
  cleanupRecording(): Promise<void>;
  generateSample(): Promise<SampleStatus>;
  sampleStatus(): Promise<SampleStatus>;
  sendSample(options: { slow: boolean }): Promise<void>;
  playReceivedSample(): Promise<void>;
  cleanupSamples(): Promise<void>;
  ping(): Promise<Diagnostics>;
  requestCameraPermission(): Promise<Diagnostics>;
  generateSessionSecret(): Promise<{ secret: string }>;
  startHost(options: { secret: string; port: number }): Promise<void>;
  connectCamera(options: { address: string; secret: string; port: number }): Promise<void>;
  sessionStatus(): Promise<SessionStatus>;
  sendSessionPing(options: { status: boolean }): Promise<void>;
  stopSession(): Promise<void>;
  createPairingQR(options: { address: string; secret: string; port: number }): Promise<{ image: string }>;
  scanPairingQR(): Promise<{ address: string; secret: string; port: number }>;
}>('Feasibility');
