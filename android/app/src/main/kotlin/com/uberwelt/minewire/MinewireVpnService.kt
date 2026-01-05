package com.uberwelt.minewire

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.service.quicksettings.TileService
import com.uberwelt.libminewire.minewire.Minewire
import com.uberwelt.libminewire.minewire.ProtectCallback

class MinewireVpnService : VpnService(), ProtectCallback {

    private var vpnInterface: ParcelFileDescriptor? = null
    private val CHANNEL_ID = "MinewireVPN"
    private var statsTimer: java.util.Timer? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopVpn()
            return START_NOT_STICKY
        }

        // 1. Получаем конфиг
        val localPort = intent?.getStringExtra("localPort") ?: ":1080"
        val serverAddr = intent?.getStringExtra("serverAddress") ?: ""
        val password = intent?.getStringExtra("password") ?: ""
        val proxyType = intent?.getStringExtra("proxyType") ?: "http" // Нас интересует только SOCKS для VPN

        // 2. Создаем уведомление (запускаем сразу базовое, потом обновим)
        createNotificationChannel()
        startForeground(1, buildNotification(serverAddr, 0, 0))

        // 3. Запускаем Go Backend и VPN интерфейс в фоновом потоке
        Thread {
            try {
                // Set Protect Callback
                Minewire.setProtectCallback(this)

                // 3.1 Запускаем SOCKS сервер (блокирующий вызов в Go, поэтому в треде)
                // Важно: Сначала запускаем SOCKS, потом VPN
                Minewire.start(localPort, serverAddr, password, "socks5") 
                
                // Poll for IsRunning (wait for storage/setup)
                var attempts = 0
                while (!Minewire.isRunning() && attempts < 20) {
                    Thread.sleep(100)
                    attempts++
                }
                if (!Minewire.isRunning()) {
                     throw Exception("Minewire backend failed to start (timeout)")
                }

                // Запускаем обновление статистики
                startStatsUpdater(serverAddr)
                
                // Notify QS Tile that VPN is starting
                requestTileUpdate()

                // 3.2 Поднимаем VPN интерфейс
                if (vpnInterface == null) {
                    val builder = Builder()
                    builder.setSession("Minewire")
                    builder.addAddress("10.0.0.2", 24) // Виртуальный IP телефона
                    builder.addRoute("0.0.0.0", 0)     // Перехватываем ВСЁ
                    builder.setMtu(1500)

                    try {
                        builder.addDisallowedApplication(packageName)
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }

                    // Это должно выполняться в треде, так как establish() может быть медленным
                    vpnInterface = builder.establish()
                }

                // 3.3 Отдаем FD в Go для обработки трафика
                vpnInterface?.let {
                    // ВАЖНО: detachFd() отвязывает дескриптор от Java объекта.
                    // Теперь Go владеет им и может спокойно закрыть его.
                    val fdLong = it.detachFd().toLong()
                    // Это тоже блокирующий вызов (вечный цикл чтения)
                    Minewire.startVpn(fdLong)
                }
            } catch (e: Exception) {
                e.printStackTrace()
                stopSelf() // Если что-то пошло не так, останавливаем сервис
            }
        }.start()

        return START_STICKY
    }

    // ... startStatsUpdater, stopStatsUpdater, buildNotification, formatBytes, stopVpn ...

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Minewire VPN Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun startStatsUpdater(serverAddr: String) {
        statsTimer?.cancel()
        statsTimer = java.util.Timer()
        statsTimer?.scheduleAtFixedRate(object : java.util.TimerTask() {
            override fun run() {
                if (!Minewire.isRunning()) {
                    return
                }
                val rx = Minewire.getRxBytes()
                val tx = Minewire.getTxBytes()
                // ONLY update if changed (simple heuristic)
                // In a real impl we'd store lastRx/lastTx, but for now just reducing frequency is huge.
                val notificationManager = getSystemService(NotificationManager::class.java)
                notificationManager.notify(1, buildNotification(serverAddr, rx, tx))
            }
        }, 1000, 5000)
    }

    private fun stopStatsUpdater() {
        statsTimer?.cancel()
        statsTimer = null
    }

    private fun buildNotification(serverAddr: String, rx: Long, tx: Long): Notification {
        val pendingIntent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        
        val stopIntent = Intent(this, MinewireVpnService::class.java)
        stopIntent.action = "STOP"
        val pendingStopIntent = PendingIntent.getService(this, 1, stopIntent, PendingIntent.FLAG_IMMUTABLE)
        
        val statsText = "↓ ${formatBytes(rx)}  ↑ ${formatBytes(tx)}"

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Minewire Connected")
            .setContentText(statsText)
            .setSubText("Tunneling to $serverAddr")
            .setSmallIcon(android.R.drawable.ic_menu_upload) // TODO: Use proper icon
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", pendingStopIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val exp = (Math.log(bytes.toDouble()) / Math.log(1024.0)).toInt()
        val pre = "KMGTPE"[exp - 1]
        return String.format("%.1f %sB", bytes / Math.pow(1024.0, exp.toDouble()), pre)
    }

    private fun stopVpn() {
        stopStatsUpdater()
        // Run Go stop in background to avoid blocking Main Thread (ANR)
        Thread {
            Minewire.stop()
        }.start()

        // vpnInterface?.close() // Don't close here, Go will close it!
        vpnInterface = null
        stopForeground(true)
        
        // Notify QS Tile to update its state
        requestTileUpdate()
        
        stopSelf()
    }
    
    private fun requestTileUpdate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            TileService.requestListeningState(
                this,
                ComponentName(this, MinewireQSTileService::class.java)
            )
        }
    }



    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun protect(fd: Long): Boolean {
        // Go passes `int` fd, but gomobile might map it to Long. 
        // VpnService.protect takes Int.
        return this.protect(fd.toInt())
    }
}
