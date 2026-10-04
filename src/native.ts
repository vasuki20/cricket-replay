import { registerPlugin } from '@capacitor/core';
export interface Diagnostics {
  platform: 'ios' | 'android'; appVersion: string; osVersion: string;
  cameraPermission: string;
}
export interface SessionStatus {
  state: string; detail: string; role: string; authenticated: boolean;
  addresses: string[]; port?: number; pingsReceived: number; repliesReceived: number;
  lastRoundTripMs?: number;
}
export const Feasibility = registerPlugin<{
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
