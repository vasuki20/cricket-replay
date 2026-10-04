import { registerPlugin } from '@capacitor/core';
export interface Diagnostics {
  platform: 'ios' | 'android'; appVersion: string; osVersion: string;
  cameraPermission: string;
}
export interface TransferStatus {
  state: string; detail?: string; requestId?: string; bytes: number; totalBytes: number;
  sha256?: string; checksumVerified: boolean; durationSeconds?: number; throughputMBps?: number; attempts?: TransferStatus[];
}
export interface SampleStatus { ready: boolean; bytes?: number; sha256?: string; durationSeconds?: number; }
// Shared experiment contract for Android #11 and iOS #12. Paths/footage stay native.
export interface RecordingConfig { retentionSeconds: number; reviewSeconds: number; }
export interface RecordingClipStatus {
  state: string; ready: boolean; detail?: string; bytes?: number; durationSeconds?: number;
  frames?: number; effectiveFps?: number; segments?: number; leadInSeconds?: number;
  sourceFirstUs?: number; sourceLastUs?: number; maxFrameDeltaMs?: number;
  intervalsOver50ms?: number; decodedFrames?: number;
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
export interface SessionStatus {
  transfer?: TransferStatus;
  state: string; detail: string; role: string; authenticated: boolean;
  addresses: string[]; port?: number; pingsReceived: number; repliesReceived: number;
  lastRoundTripMs?: number;
}
export const Feasibility = registerPlugin<{
  recordingStatus(): Promise<RecordingStatus>;
  recordingReport(): Promise<{ report: string }>;
  startRecording(options: RecordingConfig): Promise<void>;
  stopRecording(): Promise<void>;
  extractRecording(): Promise<void>;
  playRecordingClip(): Promise<void>;
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
