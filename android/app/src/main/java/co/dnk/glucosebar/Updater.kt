package co.dnk.glucosebar

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.net.HttpURLConnection
import java.net.URL
import java.time.Duration
import java.time.Instant

/**
 * Installs the latest GitHub release (its GlucoseBar.apk) when it's newer than this build: every 6 hours from the
 * service, or from Settings. The first update asks to confirm; after that Android lets the app update itself.
 */
object Updater {
    private const val API = "https://api.github.com/repos/dogfootruler-kr/glucose-bar/releases/latest"
    private const val ASSET = "GlucoseBar.apk"

    val version: String get() = BuildConfig.VERSION_NAME.let { if (it == "dev") it else "v$it" }
    val isDev get() = BuildConfig.VERSION_NAME == "dev"

    private val _status = MutableStateFlow<String?>(null)
    /** What the last install did, for Settings. */
    val status: StateFlow<String?> = _status

    @Serializable
    data class Release(
        @SerialName("tag_name") val tag: String,
        @SerialName("body") val rawNotes: String? = null,
        val assets: List<Asset> = emptyList(),
    ) {
        @Serializable
        data class Asset(val name: String, @SerialName("browser_download_url") val url: String)

        /** The CHANGELOG.md section for that version. */
        val notes get() = rawNotes.orEmpty().trim()
        val apk get() = assets.firstOrNull { it.name == ASSET }?.url
        val isNewer get() = versionCode(tag) > BuildConfig.VERSION_CODE
    }

    /** The same number the build gives a tag: v1.2.3 is 10203. */
    fun versionCode(tag: String): Int =
        Regex("""v?(\d+)\.(\d+)\.(\d+)""").matchEntire(tag)?.destructured
            ?.let { (major, minor, patch) -> major.toInt() * 10000 + minor.toInt() * 100 + patch.toInt() } ?: 0

    suspend fun latest(): Release? = withContext(Dispatchers.IO) {
        runCatching {
            val c = URL(API).openConnection() as HttpURLConnection
            c.connectTimeout = 10_000
            c.readTimeout = 20_000
            c.setRequestProperty("accept", "application/vnd.github+json")
            if (c.responseCode != 200) return@runCatching null
            Store.json.decodeFromString(Release.serializer(), c.inputStream.use { it.readBytes().decodeToString() })
        }.getOrNull()
    }

    suspend fun checkIfDue(context: Context) {
        if (isDev || Duration.between(Instant.ofEpochSecond(Store.pref("lastUpdateCheck")), Instant.now()) < Duration.ofHours(6)) return
        Store.setPref("lastUpdateCheck", Instant.now().epochSecond)
        val release = latest() ?: return
        if (release.isNewer && release.apk != null) install(context, release)
    }

    /** Downloads the release's APK and hands it to the package installer. */
    suspend fun install(context: Context, release: Release) {
        val url = release.apk ?: return
        _status.value = "Downloading ${release.tag}…"
        val installer = context.packageManager.packageInstaller
        var id = -1
        try {
            withContext(Dispatchers.IO) {
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(context.packageName)
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    val c = URL(url).openConnection() as HttpURLConnection
                    c.connectTimeout = 15_000
                    c.readTimeout = 60_000
                    c.inputStream.use { input ->
                        session.openWrite(ASSET, 0, c.contentLengthLong).use { out -> input.copyTo(out); session.fsync(out) }
                    }
                    val done = Intent(context, InstallReceiver::class.java).putExtra("tag", release.tag)
                    session.commit(PendingIntent.getBroadcast(context, id, done,
                        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT).intentSender)
                }
            }
            _status.value = "Installing ${release.tag}… GlucoseBar will restart."
        } catch (e: Exception) {
            if (id != -1) runCatching { installer.abandonSession(id) }
            _status.value = "Couldn't download ${release.tag}: ${e.message}"
        }
    }

    internal fun report(message: String) {
        _status.value = message
    }
}

/** Hears back from the package installer: asks to confirm the first update, or reports a failure. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val tag = intent.getStringExtra("tag") ?: "the update"
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) ?: return
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (Store.uiVisible) {
                    context.startActivity(confirm)
                } else {
                    val notification = Notification.Builder(context, Alerts.UPDATE_CHANNEL)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle("GlucoseBar $tag is ready to install")
                        .setContentText("Tap to install the update.")
                        .setContentIntent(PendingIntent.getActivity(context, 0, confirm,
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                        .setAutoCancel(true)
                        .build()
                    context.getSystemService(NotificationManager::class.java).notify(300, notification)
                }
                Updater.report("Confirm the install of $tag.")
            }
            PackageInstaller.STATUS_SUCCESS -> Updater.report("Installed $tag.")
            else -> Updater.report("Couldn't install $tag: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
        }
    }
}
