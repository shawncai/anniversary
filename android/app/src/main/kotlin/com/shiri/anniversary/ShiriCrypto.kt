package com.shiri.anniversary

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Native cryptography only; ephemeral private keys never cross the Flutter channel. */
internal class ShiriCrypto {
    private val pairs = ConcurrentHashMap<String, KeyPair>()

    fun keyPair(): Map<String, Any> {
        check(pairs.size < 16) { "Too many unfinished pairing sessions" }
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val public = pair.public as ECPublicKey
        val handle = UUID.randomUUID().toString()
        pairs[handle] = pair
        return mapOf("handle" to handle, "publicKey" to byteArrayOf(4) + coordinate(public.w.affineX) + coordinate(public.w.affineY))
    }

    fun derive(handle: String, point: ByteArray, salt: ByteArray): ByteArray {
        val pair = pairs.remove(handle) ?: error("Pairing session expired")
        require(point.size == 65 && point[0] == 4.toByte()) { "Invalid P-256 public key" }
        require(salt.size == 32) { "Invalid transfer salt" }
        val parameters = AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec("secp256r1"))
        val curve = parameters.getParameterSpec(ECParameterSpec::class.java)
        val spec = ECPublicKeySpec(ECPoint(BigInteger(1, point.copyOfRange(1, 33)), BigInteger(1, point.copyOfRange(33, 65))), curve)
        val peer = KeyFactory.getInstance("EC").generatePublic(spec)
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(pair.private)
        agreement.doPhase(peer, true)
        val secret = agreement.generateSecret()
        val prk = hmac(salt, secret)
        return try { hmac(prk, "shiri-transfer-v1".toByteArray(Charsets.UTF_8) + byteArrayOf(1)) }
        finally { secret.fill(0); prk.fill(0) }
    }

    fun crypt(encrypt: Boolean, key: ByteArray, nonce: ByteArray, bytes: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == 32 && nonce.size == 12) { "Invalid AES-GCM key or nonce" }
        require(encrypt || bytes.size >= 16) { "Invalid authenticated ciphertext" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(bytes)
    }

    fun clear() { pairs.clear() }

    private fun coordinate(value: BigInteger): ByteArray {
        val encoded = value.toByteArray()
        return ByteArray(32).also { encoded.copyInto(it, 32 - minOf(encoded.size, 32), maxOf(encoded.size - 32, 0)) }
    }

    private fun hmac(key: ByteArray, bytes: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(bytes)
    }
}
