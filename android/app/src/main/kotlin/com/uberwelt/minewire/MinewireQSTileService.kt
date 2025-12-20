package com.uberwelt.minewire

import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import com.uberwelt.libminewire.minewire.Minewire

@RequiresApi(Build.VERSION_CODES.N)
class MinewireQSTileService : TileService() {
    
    private val PREFS_NAME = "FlutterSharedPreferences"
    
    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        
        if (Minewire.isRunning()) {
            // Stop VPN
            val stopIntent = Intent(this, MinewireVpnService::class.java)
            stopIntent.action = "STOP"
            startService(stopIntent)
        } else {
            // Start VPN - need to get config from SharedPreferences
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val config = getActiveProfileConfig(prefs)
            
            if (config != null) {
                val intent = Intent(this, MinewireVpnService::class.java)
                intent.action = "START"
                intent.putExtra("localPort", extractYamlValue(config, "local_port") ?: ":1080")
                intent.putExtra("serverAddress", extractYamlValue(config, "server_address") ?: "")
                intent.putExtra("password", extractYamlValue(config, "password") ?: "")
                intent.putExtra("proxyType", extractYamlValue(config, "proxy_type") ?: "socks5")
                
                // Check VPN permission - if not granted, we can't start from tile
                val vpnIntent = android.net.VpnService.prepare(this)
                if (vpnIntent != null) {
                    // Need to request permission via Activity
                    // For now, just show that we need to open the app
                    // This is a limitation of TileService
                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                    launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivityAndCollapse(launchIntent)
                } else {
                    startForegroundService(intent)
                }
            }
        }
        
        // Update tile state after a short delay
        Thread {
            Thread.sleep(500)
            updateTileState()
        }.start()
    }
    
    private fun updateTileState() {
        val tile = qsTile ?: return
        val isRunning = Minewire.isRunning()
        
        tile.state = if (isRunning) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = if (isRunning) "VPN Active" else "Minewire"
        tile.subtitle = if (isRunning) "Tap to disconnect" else "Tap to connect"
        tile.updateTile()
    }
    
    private fun getActiveProfileConfig(prefs: SharedPreferences): String? {
        // Flutter SharedPreferences uses "flutter." prefix
        val activeProfileId = prefs.getString("flutter.active_profile_id", null)
        
        if (activeProfileId != null) {
            val profilesJson = prefs.getString("flutter.profiles", null)
            if (profilesJson != null) {
                try {
                    // Simple JSON parsing since we can't use full JSON library here easily
                    // Look for the profile with matching id
                    val profiles = org.json.JSONArray(profilesJson)
                    for (i in 0 until profiles.length()) {
                        val profile = profiles.getJSONObject(i)
                        if (profile.getString("id") == activeProfileId) {
                            return profile.getString("config_text")
                        }
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
        
        // Fallback to old config
        return prefs.getString("flutter.config", null)
    }
    
    private fun extractYamlValue(yaml: String, key: String): String? {
        val regex = Regex("""$key:\s*"?([^"\n]+)"?""")
        val match = regex.find(yaml)
        return match?.groupValues?.get(1)
    }
}
