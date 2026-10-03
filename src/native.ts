import { registerPlugin } from '@capacitor/core';
export interface Diagnostics {
  platform: 'ios' | 'android'; appVersion: string; osVersion: string;
  cameraPermission: string;
}
export const Feasibility = registerPlugin<{
  ping(): Promise<Diagnostics>;
  requestCameraPermission(): Promise<Diagnostics>;
}>('Feasibility');
