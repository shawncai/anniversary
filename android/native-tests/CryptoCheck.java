package com.shiri.anniversary;

import java.util.Arrays;
import java.util.Map;

/** Standalone JVM checks against the same native class shipped in the Android app. */
public final class CryptoCheck {
    private static byte[] hex(String value) {
        byte[] result = new byte[value.length() / 2];
        for (int i = 0; i < result.length; i++) result[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        return result;
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        ShiriCrypto crypto = new ShiriCrypto();
        byte[] key = new byte[32];
        byte[] nonce = new byte[12];
        byte[] ciphertext = crypto.crypt(true, key, nonce, new byte[0], new byte[0]);
        check(Arrays.equals(ciphertext, hex("530f8afbc74536b9a963b4f1c4cb738b")), "AES-256-GCM empty-message known-answer vector");
        byte[] block = crypto.crypt(true, key, nonce, new byte[16], new byte[0]);
        check(Arrays.equals(block, hex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")), "AES-256-GCM one-block known-answer vector");
        check(Arrays.equals(crypto.crypt(false, key, nonce, block, new byte[0]), new byte[16]), "Authenticated decryption");
        block[0] ^= 1;
        try { crypto.crypt(false, key, nonce, block, new byte[0]); throw new AssertionError("Tampered ciphertext accepted"); }
        catch (Exception expected) { check(expected instanceof javax.crypto.AEADBadTagException, "Tamper rejection uses AEAD authentication error"); }
        Map<String, Object> alice = crypto.keyPair();
        Map<String, Object> bob = crypto.keyPair();
        check(((byte[]) alice.get("publicKey")).length == 65 && ((byte[]) alice.get("publicKey"))[0] == 4, "ANSI X9.63 public point");
        byte[] aliceKey = crypto.derive((String) alice.get("handle"), (byte[]) bob.get("publicKey"), new byte[32]);
        byte[] bobKey = crypto.derive((String) bob.get("handle"), (byte[]) alice.get("publicKey"), new byte[32]);
        check(aliceKey.length == 32 && Arrays.equals(aliceKey, bobKey), "P-256 and HKDF agreement");
        try { crypto.derive((String) alice.get("handle"), (byte[]) bob.get("publicKey"), new byte[32]); throw new AssertionError("Ephemeral key was reused"); }
        catch (IllegalStateException expected) { }
        System.out.println("PASS: native AES-GCM vectors, authentication rejection, X9.63 P-256/HKDF agreement, ephemeral-key destruction");
    }
}
