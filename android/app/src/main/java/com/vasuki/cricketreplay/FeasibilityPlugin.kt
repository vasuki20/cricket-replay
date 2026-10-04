package com.aadhinitinytales.cricketreplay

import android.Manifest
import android.os.Build
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback

@CapacitorPlugin(name = "Feasibility", permissions = [
    Permission(alias = "camera", strings = [Manifest.permission.CAMERA])
])
class FeasibilityPlugin : Plugin() {
    private fun diagnostics(): JSObject = JSObject().apply {
        put("platform", "android")
        put("appVersion", context.packageManager.getPackageInfo(context.packageName, 0).versionName)
        put("osVersion", Build.VERSION.RELEASE)
        put("cameraPermission", when (getPermissionState("camera")) {
            PermissionState.GRANTED -> "granted"
            PermissionState.DENIED -> "denied"
            PermissionState.PROMPT_WITH_RATIONALE -> "prompt with rationale"
            else -> "not requested"
        })
    }

    @PluginMethod
    fun ping(call: PluginCall) { call.resolve(diagnostics()) }

    @PluginMethod
    fun requestCameraPermission(call: PluginCall) {
        requestPermissionForAlias("camera", call, "cameraPermissionResult")
    }

    @PermissionCallback
    private fun cameraPermissionResult(call: PluginCall) { call.resolve(diagnostics()) }
}
