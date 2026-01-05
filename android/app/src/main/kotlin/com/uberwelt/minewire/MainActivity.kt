package com.uberwelt.minewire

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.uberwelt.libminewire.minewire.Minewire

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.minewire.tunnel/control"
    private val VPN_REQUEST_CODE = 0x0F

    // Храним конфиг временно, пока не получим права
    private var pendingConfig: Intent? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "start") {
                val intent = Intent(this, MinewireVpnService::class.java)
                intent.action = "START"
                intent.putExtra("localPort", call.argument<String>("localPort"))
                intent.putExtra("serverAddress", call.argument<String>("serverAddress"))
                intent.putExtra("password", call.argument<String>("password"))
                intent.putExtra("proxyType", call.argument<String>("proxyType"))

                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null) {
                    pendingConfig = intent
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    startService(intent)
                }
                result.success(true)

            } else if (call.method == "stop") {
                val intent = Intent(this, MinewireVpnService::class.java)
                intent.action = "STOP"
                startService(intent)
                result.success(true)
            } else if (call.method == "isActive") {
                // Minewire.IsRunning() is exposed by gomobile from the Go package
                val running = Minewire.isRunning()
                result.success(running)
            } else if (call.method == "ping") {
                val serverAddress = call.argument<String>("serverAddress") ?: ""
                // Run ping in background thread to avoid blocking UI
                Thread {
                    val pingMs = Minewire.ping(serverAddress)
                    runOnUiThread {
                        result.success(pingMs.toInt())
                    }
                }.start()
            } else if (call.method == "parseLink") {
                val link = call.argument<String>("link") ?: ""
                try {
                    val json = Minewire.parseConnectionLink(link)
                    result.success(json)
                } catch (e: Exception) {
                    result.error("PARSE_ERROR", e.message, null)
                }

            } else if (call.method == "updateConfig") {
                val rules = call.argument<String>("rules") ?: ""
                Minewire.updateConfig(rules)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE && resultCode == Activity.RESULT_OK) {
            pendingConfig?.let {
                startService(it)
                pendingConfig = null
            }
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
