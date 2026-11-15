package com.vccontacts.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground-service «якорь» для фоновой очереди распознавания.
 *
 * Сам OCR выполняется в Dart/Flutter; сервис нужен, чтобы Android не
 * усыплял процесс при свёрнутом приложении/выключенном экране.
 * PARTIAL_WAKE_LOCK держит CPU, foreground-нотификация — процесс.
 */
class ScanForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "vc_scan_queue"
        const val DONE_CHANNEL_ID = "vc_scan_done"
        const val NOTIFICATION_ID = 42
        const val COMPLETION_ID = 43
        const val ACTION_START = "start"
        const val ACTION_UPDATE = "update"
        const val ACTION_STOP = "stop"
        const val EXTRA_TEXT = "text"

        private fun intent(context: Context, action: String, text: String?): Intent =
            Intent(context, ScanForegroundService::class.java).apply {
                this.action = action
                if (text != null) putExtra(EXTRA_TEXT, text)
            }

        fun start(context: Context, text: String) {
            // Новая очередь — убираем старое уведомление о завершении.
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(COMPLETION_ID)
            val i = intent(context, ACTION_START, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun update(context: Context, text: String) {
            val i = intent(context, ACTION_UPDATE, text)
            // Обновление прогресса отправляем уже запущенному сервису.
            // startForegroundService из фона на Android 12+ запрещён.
            if (running) {
                context.startService(i)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun complete(context: Context, text: String) {
            showCompletion(context, text)
            context.stopService(intent(context, ACTION_STOP, null))
        }

        fun stop(context: Context) {
            context.stopService(intent(context, ACTION_STOP, null))
        }

        private fun showCompletion(context: Context, text: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            ensureDoneChannel(context, nm)
            nm.notify(COMPLETION_ID, buildCompletion(context, text))
        }

        private fun ensureDoneChannel(context: Context, nm: NotificationManager) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    DONE_CHANNEL_ID,
                    "Результаты распознавания",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Уведомление о завершении фоновой очереди"
                    setShowBadge(true)
                }
                nm.createNotificationChannel(channel)
            }
        }

        private fun buildCompletion(context: Context, text: String): Notification {
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, DONE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("VCContacts")
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setOngoing(false)
                .setOnlyAlertOnce(false)
                .setContentIntent(open)
                .build()
        }

        @Volatile
        private var running = false
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Распознавание визиток…"))
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "VCContacts:scan-queue",
        ).apply {
            setReferenceCounted(false)
            acquire(60 * 60 * 1000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Распознавание визиток…"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
        // Продлеваем бодрствование при обновлении прогресса.
        try {
            wakeLock?.acquire(60 * 60 * 1000L)
        } catch (_: Exception) {
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Распознавание визиток",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Фоновая очередь распознавания визиток"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("VCContacts")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
    }
}
