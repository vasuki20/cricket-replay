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
export interface SessionStatus {
  transfer?: TransferStatus;
  state: string; detail: string; role: string; authenticated: boolean;
  addresses: string[]; port?: number; pingsReceived: number; repliesReceived: number;
  lastRoundTripMs?: number;
}
export const Feasibility = registerPlugin<{
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
