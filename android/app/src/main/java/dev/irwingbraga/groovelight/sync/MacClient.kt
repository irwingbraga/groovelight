package dev.irwingbraga.groovelight.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors

/** What the app remembers: this device's id, the paired Mac and its key, the music folder, automatic sync. */
class Prefs(context: Context) {
    private val prefs = context.getSharedPreferences("sync", Context.MODE_PRIVATE)

    val deviceId: String = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("deviceId", it).apply()
    }

    var macId: String? by stringPref("macId")
    var macName: String? by stringPref("macName")
    var host: String? by stringPref("host")
    var port: Int
        get() = prefs.getInt("port", 0)
        set(value) = prefs.edit().putInt("port", value).apply()
    /** The key shared with the Mac (base64), set once pairing was allowed there. */
    var key: String? by stringPref("key")
    /** The music folder picked with the system folder picker (a tree URI). */
    var folder: String? by stringPref("folder")
    var autoSync: Boolean
        get() = prefs.getBoolean("autoSync", true)
        set(value) = prefs.edit().putBoolean("autoSync", value).apply()
    var onlyWhileCharging: Boolean
        get() = prefs.getBoolean("charging", false)
        set(value) = prefs.edit().putBoolean("charging", value).apply()
    var lastResult: String? by stringPref("lastResult")
    var lastSync: Long
        get() = prefs.getLong("lastSync", 0)
        set(value) = prefs.edit().putLong("lastSync", value).apply()

    val isPaired: Boolean get() = key != null && macId != null

    fun forgetMac() {
        prefs.edit().remove("macId").remove("macName").remove("host").remove("port").remove("key").apply()
    }

    private fun stringPref(name: String) = object : kotlin.properties.ReadWriteProperty<Any?, String?> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = prefs.getString(name, null)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: String?) {
            prefs.edit().putString(name, value).apply()
        }
    }
}

/** A Mac running Groovelight, found on the network. */
data class FoundMac(val id: String, val name: String, val host: String, val port: Int)

/** Finds Groovelight on the local network (Bonjour `_groovelight._tcp`). */
object Discovery {
    private const val SERVICE = "_groovelight._tcp."

    fun macs(context: Context): Flow<List<FoundMac>> = callbackFlow {
        val nsd = context.getSystemService(NsdManager::class.java)
        // Some Wi-Fi drivers drop multicast (which Bonjour uses) without this lock.
        val lock = context.applicationContext.getSystemService(WifiManager::class.java).createMulticastLock("groovelight").apply {
            setReferenceCounted(false)
            acquire()
        }
        val found = mutableMapOf<String, FoundMac>()
        val resolver = Executors.newSingleThreadExecutor()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                resolver.execute { resolve(nsd, info) { mac -> synchronized(found) { found[mac.name] = mac; trySend(found.values.toList()) } } }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                synchronized(found) {
                    found.remove(info.serviceName)
                    trySend(found.values.toList())
                }
            }

            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { close() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        nsd.discoverServices(SERVICE, NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose {
            runCatching { nsd.stopServiceDiscovery(listener) }
            lock.release()
            resolver.shutdown()
        }
    }

    /** One resolve at a time (older Android versions refuse parallel ones). */
    @Suppress("DEPRECATION")
    private fun resolve(nsd: NsdManager, info: NsdServiceInfo, done: (FoundMac) -> Unit) {
        val latch = java.util.concurrent.CountDownLatch(1)
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) { latch.countDown() }
            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.firstOrNull()?.hostAddress else info.host?.hostAddress
                val id = info.attributes["id"]?.let { String(it) } ?: info.serviceName
                if (host != null) done(FoundMac(id, info.serviceName.removePrefix("Groovelight on "), host, info.port))
                latch.countDown()
            }
        })
        latch.await(10, java.util.concurrent.TimeUnit.SECONDS)
    }
}

class MacError(message: String, val status: Int = 0) : IOException(message)

/** Requests to Groovelight on the Mac. After pairing every request is signed with the shared key. */
class MacClient(private val host: String, private val port: Int, private val deviceId: String, private val key: ByteArray?) {
    private fun url(path: String) = URL("http://${if (host.contains(':')) "[$host]" else host}:$port$path")

    fun info(): JSONObject = json("GET", "/info", signed = false)

    fun pair(name: String, model: String, publicKey: ByteArray): JSONObject = json("POST", "/pair", JSONObject()
        .put("deviceId", deviceId).put("name", name).put("model", model).put("publicKey", Pairing.base64(publicKey)), signed = false)

    fun pairStatus(): String = json("GET", "/pair/$deviceId", signed = false).getString("status")

    fun status(): JSONObject = json("GET", "/status")

    fun sync(request: JSONObject): JSONObject = json("POST", "/sync", request, timeout = 120_000)

    fun done(session: String, result: JSONObject): JSONObject = json("POST", "/sync/$session/done", result)

    /** Opens a file of a plan from `offset` (to resume a cut-off download). */
    fun download(session: String, index: Int, offset: Long): Pair<InputStream, HttpURLConnection> {
        val path = "/sync/$session/file/$index"
        val connection = open("GET", path, ByteArray(0), signed = true, timeout = 60_000)
        if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
        val status = connection.responseCode
        if (status != 200 && status != 206) throw MacError("Download failed ($status)", status)
        // The Mac ignored the range: start over.
        if (offset > 0 && status == 200) throw MacError("Range not honored", 416)
        return connection.inputStream to connection
    }

    private fun json(method: String, path: String, body: JSONObject? = null, signed: Boolean = true, timeout: Int = 15_000): JSONObject {
        val bytes = body?.toString()?.toByteArray() ?: ByteArray(0)
        val connection = open(method, path, bytes, signed, timeout)
        try {
            if (bytes.isNotEmpty()) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            val text = (if (status < 400) connection.inputStream else connection.errorStream)?.use { it.readBytes().decodeToString() } ?: "{}"
            if (status >= 400) {
                val message = runCatching { JSONObject(text).getString("error") }.getOrDefault("Error $status")
                throw MacError(message, status)
            }
            return JSONObject(text)
        } finally {
            connection.disconnect()
        }
    }

    private fun open(method: String, path: String, body: ByteArray, signed: Boolean, timeout: Int): HttpURLConnection {
        val connection = url(path).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 8_000
        connection.readTimeout = timeout
        connection.useCaches = false
        if (signed) {
            val key = key ?: throw MacError("Not paired")
            val time = System.currentTimeMillis() / 1000
            val nonce = UUID.randomUUID().toString()
            connection.setRequestProperty("X-GL-Device", deviceId)
            connection.setRequestProperty("X-GL-Time", time.toString())
            connection.setRequestProperty("X-GL-Nonce", nonce)
            connection.setRequestProperty("X-GL-Signature", Pairing.signature(method, path, time, nonce, body, key))
        }
        return connection
    }
}
