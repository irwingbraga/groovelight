package dev.irwingbraga.groovelight.sync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

/**
 * Runs a sync in the background as a foreground job (with a notification, so Android lets it finish). The periodic
 * one first asks the Mac whether there is anything to do (its Sync button, songs sent to this device, or a while
 * since the last sync), so it costs almost nothing when nothing changed.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    companion object {
        const val NOW = "sync-now"
        const val AUTOMATIC = "sync-automatic"
        private const val CHANNEL = "sync"
        private const val NOTIFICATION = 1
        private const val PERIODIC = "periodic"

        fun syncNow(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(NOW, ExistingWorkPolicy.KEEP, request)
        }

        /** Turns the automatic sync on or off (on Wi-Fi only, and only while charging if asked). */
        fun schedule(context: Context, prefs: Prefs) {
            val work = WorkManager.getInstance(context)
            if (!prefs.autoSync || !prefs.isPaired) {
                work.cancelUniqueWork(AUTOMATIC)
                return
            }
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.UNMETERED)
                .setRequiresCharging(prefs.onlyWhileCharging)
                .setRequiresStorageNotLow(true)
                .build()
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .setInputData(workDataOf(PERIODIC to true))
                .build()
            work.enqueueUniquePeriodicWork(AUTOMATIC, ExistingPeriodicWorkPolicy.UPDATE, request)
        }
    }

    private val prefs = Prefs(applicationContext)

    override suspend fun doWork(): Result {
        if (!prefs.isPaired || prefs.folder == null) return Result.success()
        val engine = SyncEngine(applicationContext, prefs)
        if (inputData.getBoolean(PERIODIC, false)) {
            val due = runCatching {
                val status = engine.connect().status()
                status.optBoolean("syncRequested") || status.optInt("pendingSends") > 0 ||
                    System.currentTimeMillis() - prefs.lastSync > TimeUnit.HOURS.toMillis(6)
            }.getOrDefault(false)
            if (!due) return Result.success()
        }
        setForeground(foregroundInfo("Getting ready…", 0, 0))
        return try {
            val summary = engine.run { progress ->
                setProgressAsync(workDataOf("done" to progress.done, "total" to progress.total, "current" to progress.current))
                setForegroundAsync(foregroundInfo(progress.current, progress.done, progress.total))
            }
            Result.success(workDataOf("summary" to summary))
        } catch (error: Exception) {
            prefs.lastResult = error.message ?: "Sync failed"
            if (runAttemptCount < 2 && !inputData.getBoolean(PERIODIC, false)) Result.retry()
            else Result.failure(workDataOf("summary" to (error.message ?: "Sync failed")))
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo("Getting ready…", 0, 0)

    private fun foregroundInfo(text: String, done: Int, total: Int): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Syncing", NotificationManager.IMPORTANCE_LOW))
        }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(R.drawable.ic_sync_notification)
            .setContentTitle("Syncing with ${prefs.macName ?: "Groovelight"}")
            .setContentText(if (total > 0) "$done of $total · $text" else text)
            .setProgress(total, done, total == 0)
            .setOngoing(true)
            .setSilent(true)
            .build()
        return ForegroundInfo(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }
}
