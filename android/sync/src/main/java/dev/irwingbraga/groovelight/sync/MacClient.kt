package dev.irwingbraga.groovelight.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager
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
    /** The version (ETag) of the Mac's catalog the device holds. */
    var catalogTag: String? by stringPref("catalogTag")
    var lastSync: Long
        get() = prefs.getLong("lastSync", 0)
        set(value) = prefs.edit().putLong("lastSync", value).apply()
    /** How the music is listened to: [Mode.PLAYER] (Groovelight plays it) or [Mode.SYNC_ONLY] (another player app
     *  does); null until chosen. Devices paired before the player existed are Sync only (see [resolvedMode]). */
    var mode: Mode?
        get() = prefs.getString("mode", null)?.let { name -> Mode.entries.firstOrNull { it.name == name } }
        set(value) = prefs.edit().putString("mode", value?.name).apply()

    /** The mode, deciding it for a device that synced before modes existed: it stays as it was, Sync only. */
    val resolvedMode: Mode? get() = mode ?: if (isPaired || folder != null) Mode.SYNC_ONLY.also { mode = it } else null

    enum class Mode { PLAYER, SYNC_ONLY }

    val isPaired: Boolean get() = key != null && macId != null
    /** The Mac's HTTPS port (protocol v2), 0 when it serves HTTP only. */
    var tlsPort: Int
        get() = prefs.getInt("tlsPort", 0)
        set(value) = prefs.edit().putInt("tlsPort", value).apply()
    /** The pinned fingerprint (SHA-256, hex) of the Mac's certificate: once set, the Mac is only reached over HTTPS. */
    var certificate: String? by stringPref("certificate")

    fun forgetMac() {
        prefs.edit().remove("macId").remove("macName").remove("host").remove("port").remove("key").remove("tlsPort")
            .remove("certificate").apply()
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

/**
 * Requests to Groovelight on the Mac. After pairing every request is signed with the shared key. With `tls` (protocol
 * v2) it talks HTTPS to the Mac's HTTPS port, accepting only the certificate whose fingerprint was pinned (see [pin]).
 */
class MacClient(private val host: String, private val port: Int, private val deviceId: String, private val key: ByteArray?,
                private val tls: Tls? = null) {
    /** The HTTPS port and the pinned certificate's fingerprint: only that certificate is accepted. */
    class Tls(val port: Int, val fingerprint: String) {
        internal val socketFactory: SSLSocketFactory by lazy {
            val trust = object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException("not a server")
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                    val leaf = chain.firstOrNull() ?: throw CertificateException("no certificate")
                    if (!isPinned(leaf)) throw CertificateException("not the Mac's certificate")
                }
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            }
            SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }.socketFactory
        }

        /**
         * The Mac is reached by its address, which its certificate does not name: what identifies it is the pinned
         * certificate, checked again here for the connection's session.
         */
        internal val hostnameVerifier = HostnameVerifier { _, session ->
            (session.peerCertificates.firstOrNull() as? X509Certificate)?.let(::isPinned) == true
        }

        private fun isPinned(certificate: X509Certificate): Boolean {
            val actual = Pairing.hexString(MessageDigest.getInstance("SHA-256").digest(certificate.encoded))
            return MessageDigest.isEqual(actual.toByteArray(), fingerprint.toByteArray())
        }
    }

    private fun url(path: String): URL {
        val name = if (host.contains(':')) "[$host]" else host
        return if (tls != null) URL("https://$name:${tls.port}$path") else URL("http://$name:$port$path")
    }

    fun info(): JSONObject = json("GET", "/info", signed = false)

    /**
     * The fingerprint of the certificate the Mac's HTTPS port serves, to pin before connecting to it. Asked over HTTP:
     * the answer carries the Mac's proof, made with the pairing key, so no one else on the network can name another
     * certificate.
     */
    fun pinnedCertificate(): String {
        val key = key ?: throw MacError("Not paired")
        val nonce = UUID.randomUUID().toString()
        val answer = json("GET", "/certificate?nonce=$nonce", signedPath = "/certificate")
        val fingerprint = answer.getString("fingerprint")
        val proof = Pairing.certificateProof(fingerprint, nonce, key)
        if (fingerprint.length != 64 || !MessageDigest.isEqual(proof.toByteArray(), answer.getString("proof").toByteArray())) {
            throw MacError("Could not verify the Mac's secure connection")
        }
        return fingerprint
    }

    fun pair(name: String, model: String, publicKey: ByteArray): JSONObject = json("POST", "/pair", JSONObject()
        .put("deviceId", deviceId).put("name", name).put("model", model).put("publicKey", Pairing.base64(publicKey)), signed = false)

    fun pairStatus(): String = json("GET", "/pair/$deviceId", signed = false).getString("status")

    fun status(): JSONObject = json("GET", "/status")

    fun sync(request: JSONObject): JSONObject = json("POST", "/sync", request, timeout = 120_000)

    fun done(session: String, result: JSONObject): JSONObject = json("POST", "/sync/$session/done", result)

    /**
     * Opens a file of a plan from `offset` (to resume a cut-off download): with the plan's `token` over HTTPS (v2), else
     * signed. The connection's `X-GL-SHA256` header is the whole file's SHA-256 (v2).
     */
    fun download(session: String, index: Int, offset: Long, token: String? = null): Pair<InputStream, HttpURLConnection> =
        get("/sync/$session/file/$index", offset, token)

    /** The library snapshot of a Player-mode sync (v2), and its SHA-256. */
    fun snapshot(session: String, token: String): Pair<ByteArray, String?> = bytes("/sync/$session/snapshot", token)

    /** A cover (600 pixels, JPEG) the snapshot refers to (v2). */
    fun artwork(session: String, token: String, hash: String): Pair<ByteArray, String?> = bytes("/sync/$session/artwork/$hash", token)

    /**
     * The Mac's whole library (v2, HTTPS): its JSON and version, or null when the Mac's is still `tag` (nothing sent).
     * Arrives deflated; checked against its SHA-256 and, once inflated, against the version.
     */
    fun catalog(tag: String?): Pair<ByteArray, String>? {
        val connection = open("GET", "/catalog", ByteArray(0), signed = true, timeout = 120_000)
        try {
            if (tag != null) connection.setRequestProperty("If-None-Match", tag)
            val status = connection.responseCode
            if (status == 304) return null
            if (status == 404) throw MacError("Update Groovelight on the Mac to see its whole library here.", status)
            if (status != 200) throw MacError("The Mac's library could not be read ($status)", status)
            val body = connection.inputStream.use { it.readBytes() }
            if (connection.getHeaderField("X-GL-SHA256")?.let { it != hex(body) } == true) throw MacError("The Mac's library arrived damaged")
            val json = if (connection.getHeaderField("X-GL-Encoding") == "deflate") {
                java.util.zip.InflaterInputStream(body.inputStream(), java.util.zip.Inflater(true)).use { it.readBytes() }
            } else body
            val version = connection.getHeaderField("ETag") ?: hex(json)
            if (version != hex(json)) throw MacError("The Mac's library arrived damaged")
            return json to version
        } finally {
            connection.disconnect()
        }
    }

    /** A small cover (300 pixels, JPEG) of the catalog, checked against its SHA-256. */
    fun catalogArtwork(hash: String): ByteArray? {
        val connection = open("GET", "/catalog/artwork/$hash", ByteArray(0), signed = true, timeout = 30_000)
        try {
            if (connection.responseCode != 200) return null
            val data = connection.inputStream.use { it.readBytes() }
            return data.takeIf { it.isNotEmpty() && connection.getHeaderField("X-GL-SHA256") == hex(it) }
        } finally {
            connection.disconnect()
        }
    }

    /** Sends requests for the selection (`[{id, action, kind, key}]`); answers what the selection holds then. */
    fun requests(requests: JSONArray): JSONObject = json("POST", "/requests", JSONObject().put("requests", requests))

    private fun hex(data: ByteArray) = Pairing.hexString(MessageDigest.getInstance("SHA-256").digest(data))

    private fun bytes(path: String, token: String): Pair<ByteArray, String?> {
        val (input, connection) = get(path, 0, token)
        try {
            return input.use { it.readBytes() } to connection.getHeaderField("X-GL-SHA256")
        } finally {
            connection.disconnect()
        }
    }

    private fun get(path: String, offset: Long, token: String?): Pair<InputStream, HttpURLConnection> {
        val connection = open("GET", path, ByteArray(0), signed = token == null, timeout = 60_000)
        if (token != null) connection.setRequestProperty("X-GL-Token", token)
        if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
        val status = connection.responseCode
        if (status != 200 && status != 206) throw MacError("Download failed ($status)", status)
        // The Mac ignored the range: start over.
        if (offset > 0 && status == 200) throw MacError("Range not honored", 416)
        return connection.inputStream to connection
    }

    private fun json(method: String, path: String, body: JSONObject? = null, signed: Boolean = true, timeout: Int = 15_000,
                     signedPath: String = path): JSONObject {
        val bytes = body?.toString()?.toByteArray() ?: ByteArray(0)
        val connection = open(method, path, bytes, signed, timeout, signedPath)
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

    /** `signedPath`: the path without its query, which is what the Mac checks the signature against. */
    private fun open(method: String, path: String, body: ByteArray, signed: Boolean, timeout: Int, signedPath: String = path): HttpURLConnection {
        val connection = url(path).openConnection() as HttpURLConnection
        if (connection is HttpsURLConnection && tls != null) {
            connection.sslSocketFactory = tls.socketFactory
            connection.hostnameVerifier = tls.hostnameVerifier
        }
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
            connection.setRequestProperty("X-GL-Signature", Pairing.signature(method, signedPath, time, nonce, body, key))
        }
        return connection
    }
}
