package com.example.comptech_portal_app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.UUID

object NfcPhoneKeyStore {
    private const val PROVIDER = "AndroidKeyStore"
    private const val CARD_PREFIX = "COMPTECH:NFC:CARD:V1:"

    private fun accountId(studentId: String): String {
        return UUID.fromString(studentId).toString()
    }

    private fun alias(studentId: String): String {
        return "comptech_nfc_phone_v1_${accountId(studentId)}"
    }

    private fun openStore(): KeyStore {
        return KeyStore.getInstance(PROVIDER).apply {
            load(null)
        }
    }

    private fun fingerprint(bytes: ByteArray): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") {
                "%02x".format(it.toInt() and 0xff)
            }
    }

    private fun signMessage(
        privateKey: PrivateKey,
        message: String
    ): String {
        val signature =
            Signature.getInstance("SHA256withECDSA").run {
                initSign(privateKey)
                update(message.toByteArray(Charsets.UTF_8))
                sign()
            }

        return Base64.encodeToString(
            signature,
            Base64.NO_WRAP
        )
    }

    @Synchronized
    fun hasKey(studentId: String): Boolean {
        return openStore().containsAlias(alias(studentId))
    }

    @Synchronized
    fun prepare(studentId: String, createIfMissing: Boolean = false): Map<String, Any> {
        val keyAlias = alias(studentId)
        val store = openStore()

        // Keep the same alias and reuse the existing key.
        if (!store.containsAlias(keyAlias)) {
            check(createIfMissing) {
                "LOCAL_PHONE_KEY_MISSING: Register explicitly or request authorized recovery."
            }
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                PROVIDER
            )

            generator.initialize(
                KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_SIGN or
                            KeyProperties.PURPOSE_VERIFY
                )
                    .setAlgorithmParameterSpec(
                        ECGenParameterSpec("secp256r1")
                    )
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build()
            )

            generator.generateKeyPair()
        }

        val privateKey =
            store.getKey(keyAlias, null) as? PrivateKey
                ?: error("Signing key is unavailable.")

        val publicKey =
            store.getCertificate(keyAlias)?.publicKey
                ?: error("Public key is unavailable.")

        val challenge = ByteArray(32).also {
            SecureRandom().nextBytes(it)
        }

        val signature =
            Signature.getInstance("SHA256withECDSA").run {
                initSign(privateKey)
                update(challenge)
                sign()
            }

        val valid =
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(publicKey)
                update(challenge)
                verify(signature)
            }

        check(valid) {
            "Local signature verification failed."
        }

        val changedChallenge = challenge.copyOf()
        changedChallenge[0] =
            (changedChallenge[0].toInt() xor 1).toByte()

        val changedMessageAccepted =
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(publicKey)
                update(changedChallenge)
                verify(signature)
            }

        check(!changedMessageAccepted) {
            "Modified-message verification failed."
        }

        return mapOf(
            "public_key" to Base64.encodeToString(
                publicKey.encoded,
                Base64.NO_WRAP
            ),
            "algorithm" to "ECDSA_P256_SHA256",
            "key_fingerprint" to fingerprint(publicKey.encoded),
            "self_test_passed" to true
        )
    }

    @Synchronized
    fun signRegistrationChallenge(
        studentId: String,
        message: String
    ): String {
        val id = accountId(studentId)
        val keyAlias = alias(studentId)
        val store = openStore()

        check(store.containsAlias(keyAlias)) {
            "Prepare the phone key first."
        }

        val privateKey =
            store.getKey(keyAlias, null) as? PrivateKey
                ?: error("Signing key is unavailable.")

        val publicKey =
            store.getCertificate(keyAlias)?.publicKey
                ?: error("Public key is unavailable.")

        require(message.toByteArray(Charsets.UTF_8).size <= 2048) {
            "Registration message is too large."
        }

        val lines = message.split('\n')

        require(lines.size == 5) {
            "Invalid registration message."
        }

        require(lines[0] == "COMPTECH:NFC:REGISTER:V1") {
            "Invalid registration purpose."
        }

        require(lines[1] == "student=$id") {
            "Student does not match."
        }

        require(lines[2].startsWith("challenge=")) {
            "Challenge ID is missing."
        }

        val challengeId =
            UUID.fromString(lines[2].removePrefix("challenge="))
                .toString()

        require(lines[2] == "challenge=$challengeId") {
            "Invalid challenge ID."
        }

        require(
            lines[3] == "key=${fingerprint(publicKey.encoded)}"
        ) {
            "Challenge does not match this phone key."
        }

        require(
            Regex("nonce=[0-9a-f]{64}").matches(lines[4])
        ) {
            "Invalid challenge nonce."
        }

        return signMessage(privateKey, message)
    }

    @Synchronized
    fun signCardAssignmentChallenge(
        studentId: String,
        challengeId: String,
        phoneCredentialId: String,
        cardUid: String,
        ndefPayload: String,
        message: String
    ): String {
        val id = accountId(studentId)
        val canonicalChallengeId =
            UUID.fromString(challengeId).toString()
        val canonicalCredentialId =
            UUID.fromString(phoneCredentialId).toString()

        require(challengeId == canonicalChallengeId) {
            "Invalid challenge ID."
        }

        require(phoneCredentialId == canonicalCredentialId) {
            "Invalid phone credential ID."
        }

        require(
            Regex("[0-9a-f]{8,32}").matches(cardUid) &&
                    cardUid.length % 2 == 0
        ) {
            "Invalid card UID."
        }

        require(
            Regex("COMPTECH:NFC:CARD:V1:[0-9a-f]{64}")
                .matches(ndefPayload)
        ) {
            "Invalid card payload."
        }

        require(message.toByteArray(Charsets.UTF_8).size <= 2048) {
            "Assignment message is too large."
        }

        val keyAlias = alias(studentId)
        val store = openStore()

        // Assignment signing never creates a replacement key.
        check(store.containsAlias(keyAlias)) {
            "The existing phone key is required."
        }

        val privateKey =
            store.getKey(keyAlias, null) as? PrivateKey
                ?: error("Signing key is unavailable.")

        val publicKey =
            store.getCertificate(keyAlias)?.publicKey
                ?: error("Public key is unavailable.")

        val token = ndefPayload.removePrefix(CARD_PREFIX)
        val tokenHash = fingerprint(
            token.toByteArray(Charsets.UTF_8)
        )
        val keyFingerprint = fingerprint(publicKey.encoded)

        val lines = message.split('\n')

        require(lines.size == 8) {
            "Invalid assignment message."
        }

        require(lines[0] == "COMPTECH:NFC:ASSIGN:V1") {
            "Invalid assignment purpose."
        }

        require(lines[1] == "student=$id") {
            "Student does not match."
        }

        require(lines[2] == "challenge=$canonicalChallengeId") {
            "Challenge does not match."
        }

        require(lines[3] == "credential=$canonicalCredentialId") {
            "Phone credential does not match."
        }

        require(lines[4] == "key=$keyFingerprint") {
            "Challenge does not match this phone key."
        }

        require(lines[5] == "uid=$cardUid") {
            "Card UID does not match."
        }

        require(lines[6] == "token=$tokenHash") {
            "Card token does not match."
        }

        require(
            Regex("nonce=[0-9a-f]{64}").matches(lines[7])
        ) {
            "Invalid challenge nonce."
        }

        return signMessage(privateKey, message)
    }

    @Synchronized
    fun signAttendanceChallenge(
        studentId: String,
        message: String,
        context: Map<String, String>
    ): String {
        val id = accountId(studentId)
        val names = listOf("challenge_id", "ready_id", "session_id", "class_id",
            "card_id", "credential_id", "scanner_id")
        val ids = names.associateWith { name ->
            val value = context[name] ?: error("Missing attendance context.")
            require(UUID.fromString(value).toString() == value) { "Invalid attendance context." }
            value
        }
        require(message.toByteArray(Charsets.UTF_8).size <= 2048) { "Attendance message is too large." }
        val lines = message.split('\n')
        require(lines.size == 11 && Regex("nonce=[0-9a-f]{64}").matches(lines[10])) {
            "Invalid attendance message."
        }
        val store = openStore()
        val keyAlias = alias(studentId)
        check(store.containsAlias(keyAlias)) { "The registered phone key is required." }
        val privateKey = store.getKey(keyAlias, null) as? PrivateKey
            ?: error("Signing key is unavailable.")
        val publicKey = store.getCertificate(keyAlias)?.publicKey
            ?: error("Public key is unavailable.")
        val expected = listOf(
            "COMPTECH:NFC:ATTEND:V1", "student=$id",
            "challenge=${ids.getValue("challenge_id")}", "ready=${ids.getValue("ready_id")}",
            "session=${ids.getValue("session_id")}", "class=${ids.getValue("class_id")}",
            "card=${ids.getValue("card_id")}", "credential=${ids.getValue("credential_id")}",
            "key=${fingerprint(publicKey.encoded)}", "scanner=${ids.getValue("scanner_id")}", lines[10]
        ).joinToString("\n")
        require(message == expected) { "Attendance challenge does not match the selected session and phone." }
        return signMessage(privateKey, message)
    }
    // Offline fallback (no internet). Separate signing domains, so these proofs
    // can't be submitted to any online API. The signed time must match this
    // phone's clock, so a proof can't be backdated after the fact. The server
    // reads every value from the signed message itself.
    //   COMPTECH:OFFLINE:QR:V1        student, key, upload, class, session,
    //                                 token (sha256 hex), time, location
    //   COMPTECH:OFFLINE:LOCATION:V1  student, key, upload, time, location
    // location is "none" or "lat,lng,accuracy,mock" (7, 7, 1 decimals; 0/1).
    @Synchronized
    fun signOfflineProof(studentId: String, message: String): String {
        val id = accountId(studentId)
        require(message.toByteArray(Charsets.UTF_8).size <= 1024) {
            "Offline proof is too large."
        }
        val store = openStore()
        val keyAlias = alias(id)
        check(store.containsAlias(keyAlias)) { "The registered phone key is required." }
        val privateKey = store.getKey(keyAlias, null) as? PrivateKey
            ?: error("Signing key is unavailable.")
        val publicKey = store.getCertificate(keyAlias)?.publicKey
            ?: error("Public key is unavailable.")

        val uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        val point = "-?[0-9]{1,3}\\.[0-9]{7},-?[0-9]{1,3}\\.[0-9]{7},[0-9]{1,6}\\.[0-9],[01]"
        val lines = message.split('\n')
        val shape = when (lines.firstOrNull()) {
            "COMPTECH:OFFLINE:QR:V1" -> listOf(
                "student=$id", "key=${fingerprint(publicKey.encoded)}", "upload=$uuid",
                "class=$uuid", "session=$uuid", "token=[0-9a-f]{64}", "time=[0-9]{10}",
                "location=(none|$point)",
            )
            "COMPTECH:OFFLINE:LOCATION:V1" -> listOf(
                "student=$id", "key=${fingerprint(publicKey.encoded)}", "upload=$uuid",
                "time=[0-9]{10}", "location=$point",
            )
            else -> error("Invalid offline proof purpose.")
        }
        require(lines.size == shape.size + 1) { "Invalid offline proof." }
        shape.forEachIndexed { index, pattern ->
            require(Regex(pattern).matches(lines[index + 1])) { "Invalid offline proof." }
        }

        val time = lines.first { it.startsWith("time=") }.removePrefix("time=").toLong()
        val now = System.currentTimeMillis() / 1000
        require(kotlin.math.abs(now - time) <= 120) { "Offline proof time does not match this phone." }

        return signMessage(privateKey, message)
    }

    // Separate signing domain: cannot be submitted to the existing CARD attendance API.
    @Synchronized
    fun signPhoneTapChallenge(studentId: String, expectedFingerprint: String, message: String): String {
        val id = accountId(studentId)
        val store = openStore()
        val keyAlias = alias(id)
        check(store.containsAlias(keyAlias)) { "Registered key is unavailable." }
        val publicKey = store.getCertificate(keyAlias)?.publicKey
            ?: error("Public key is unavailable.")
        check(fingerprint(publicKey.encoded) == expectedFingerprint) { "Phone key changed." }
        PhoneNfcProtocol.validate(message, id, expectedFingerprint, System.currentTimeMillis() / 1000)
        val privateKey = store.getKey(keyAlias, null) as? PrivateKey
            ?: error("Signing key is unavailable.")
        return signMessage(privateKey, message)
    }
}
