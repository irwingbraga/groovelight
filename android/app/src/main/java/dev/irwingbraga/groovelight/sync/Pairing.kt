package dev.irwingbraga.groovelight.sync

import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The device's side of pairing and request signing, matching WirelessProtocol in Groovelight on the Mac.
 *
 * X25519 key exchange; HKDF-SHA256 (RFC 5869) gives the signing key and the 6-digit code shown on both screens, both
 * bound to the two public keys. Requests are signed with HMAC-SHA256 over "METHOD\npath\ntime\nnonce\nsha256(body)".
 * Plain Kotlin (no Android APIs), so the JVM unit test checks it against the Mac's test vector.
 */
object Pairing {
    /** DER prefixes around a raw 32-byte X25519 key. */
    private val publicPrefix = hex("302a300506032b656e032100")
    private val privatePrefix = hex("302e020100300506032b656e04220420")
    private val salt = "groovelight-pair-v1".toByteArray()

    /** A fresh X25519 key pair ("XDH" defaults to X25519 on Android 12+ and desktop Java). */
    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("XDH").generateKeyPair()

    /** A key pair from a raw private key (tests). */
    fun keyPair(rawPrivate: ByteArray): Pair<PrivateKey, ByteArray> {
        val private = KeyFactory.getInstance("XDH").generatePrivate(PKCS8EncodedKeySpec(privatePrefix + rawPrivate))
        return private to publicFromPrivate(rawPrivate)
    }

    /** Raw 32-byte public key of a key pair. */
    fun rawPublic(pair: KeyPair): ByteArray = pair.public.encoded.takeLast(32).toByteArray()

    /** The signing key and the code, from our private key and the other side's raw public key. */
    fun derive(private: PrivateKey, peerPublic: ByteArray, devicePublic: ByteArray, macPublic: ByteArray): Pair<ByteArray, String> {
        val agreement = KeyAgreement.getInstance("XDH")
        agreement.init(private)
        agreement.doPhase(KeyFactory.getInstance("XDH").generatePublic(X509EncodedKeySpec(publicPrefix + peerPublic)), true)
        val secret = agreement.generateSecret()
        val key = hkdf(secret, "key".toByteArray() + macPublic + devicePublic, 32)
        val codeBytes = hkdf(secret, "code".toByteArray() + macPublic + devicePublic, 4)
        var number = 0L
        for (byte in codeBytes) number = (number shl 8) or (byte.toLong() and 0xff)
        return key to "%06d".format(number % 1_000_000)
    }

    fun hkdf(input: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, input)
        val okm = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            previous = hmac(prk, previous + info + byteArrayOf(counter.toByte()))
            val count = minOf(previous.size, length - offset)
            System.arraycopy(previous, 0, okm, offset, count)
            offset += count
            counter++
        }
        return okm
    }

    fun signature(method: String, path: String, time: Long, nonce: String, body: ByteArray, key: ByteArray): String {
        val bodyHash = MessageDigest.getInstance("SHA-256").digest(body).joinToString("") { "%02x".format(it) }
        val message = "${method.uppercase()}\n$path\n$time\n$nonce\n$bodyHash".toByteArray()
        return Base64.getEncoder().encodeToString(hmac(key, message))
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    /** X25519 public key = scalar multiplication of the base point (u = 9), via the provider's key agreement. */
    private fun publicFromPrivate(rawPrivate: ByteArray): ByteArray {
        val factory = KeyFactory.getInstance("XDH")
        val private = factory.generatePrivate(PKCS8EncodedKeySpec(privatePrefix + rawPrivate))
        val basePoint = ByteArray(32).also { it[0] = 9 }
        val agreement = KeyAgreement.getInstance("XDH")
        agreement.init(private)
        agreement.doPhase(factory.generatePublic(X509EncodedKeySpec(publicPrefix + basePoint)), true)
        return agreement.generateSecret()
    }

    fun hex(text: String): ByteArray = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    fun fromBase64(text: String): ByteArray = Base64.getDecoder().decode(text)
}
