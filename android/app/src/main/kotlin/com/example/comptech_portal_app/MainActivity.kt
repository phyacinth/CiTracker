package com.example.comptech_portal_app

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var phoneReader: PhoneNfcReader? = null

    // While the app is on screen, NFC taps come here instead of Android's
    // "New tag collected" screen, which otherwise opens when a card is tapped
    // between scans (the pause after a student, the points window, etc.) and
    // interrupts scanning. Active scans use reader mode, which takes priority
    // over this, so scanning itself is unchanged.
    override fun onResume() {
        super.onResume()
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return
        val intent = Intent(this, javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        try {
            adapter.enableForegroundDispatch(
                this,
                PendingIntent.getActivity(this, 0, intent, flags),
                null,
                null,
            )
        } catch (_: Exception) {
            // NFC off or unavailable: nothing to intercept.
        }
    }

    // Taps caught between scans are ignored.
    override fun onNewIntent(intent: Intent) {
        if (intent.action in NFC_TAP_ACTIONS) return
        super.onNewIntent(intent)
    }

    override fun onPause() {
        try {
            NfcAdapter.getDefaultAdapter(this)?.disableForegroundDispatch(this)
        } catch (_: Exception) {
            // Not enabled.
        }
        phoneReader?.stop()
        super.onPause()
    }

    override fun onDestroy() {
        phoneReader?.stop()
        super.onDestroy()
    }
    companion object {
        private val NFC_TAP_ACTIONS = setOf(
            NfcAdapter.ACTION_NDEF_DISCOVERED,
            NfcAdapter.ACTION_TECH_DISCOVERED,
            NfcAdapter.ACTION_TAG_DISCOVERED,
        )
        private const val NFC_CHANNEL = "comptech/nfc_credential"
    }

    private fun runKeyTask(
        result: MethodChannel.Result,
        operation: () -> Any
    ) {
        Thread({
            try {
                val response = operation()

                runOnUiThread {
                    result.success(response)
                }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "PHONE_KEY_OPERATION_FAILED",
                        "The phone key operation could not be completed.",
                        null
                    )
                }
            }
        }, "nfc-key-operation").start()
    }

    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)
        phoneReader?.stop()
        val reader = PhoneNfcReader(this)
        phoneReader = reader
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "comptech/phone_nfc_reader")
            .setMethodCallHandler(reader)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "comptech/phone_nfc_tap")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(PhoneNfcState.status(this))
                    "disable" -> {
                        PhoneNfcState.disable(this)
                        result.success(null)
                    }
                    "enable" -> {
                        val id = call.argument<String>("studentId")
                        val fp = call.argument<String>("fingerprint")
                        if (id.isNullOrBlank() || fp.isNullOrBlank()) {
                            result.error("INVALID_ACCOUNT", "Student and fingerprint required.", null)
                        } else {
                            runKeyTask(result) {
                                val prepared = NfcPhoneKeyStore.prepare(id)
                                check(prepared["key_fingerprint"] == fp) { "Phone key changed." }
                                PhoneNfcState.enable(this, id, fp)
                                PhoneNfcState.status(this)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NFC_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "supportsCardEmulation" -> {
                    result.success(
                        packageManager.hasSystemFeature(
                            PackageManager.FEATURE_NFC_HOST_CARD_EMULATION
                        )
                    )
                }

                "hasPhoneKey" -> {
                    val id = call.argument<String>("studentId")
                    if (id.isNullOrBlank()) {
                        result.error("INVALID_ACCOUNT", "Student account required.", null)
                    } else {
                        runKeyTask(result) { NfcPhoneKeyStore.hasKey(id) }
                    }
                }

                "preparePhoneKey", "createPhoneKey" -> {
                    val studentId =
                        call.argument<String>("studentId")

                    if (studentId.isNullOrBlank()) {
                        result.error(
                            "INVALID_ACCOUNT",
                            "A student account is required.",
                            null
                        )
                    } else {
                        runKeyTask(result) {
                            NfcPhoneKeyStore.prepare(
                                studentId,
                                createIfMissing = call.method == "createPhoneKey"
                            )
                        }
                    }
                }

                "signRegistrationChallenge" -> {
                    val studentId =
                        call.argument<String>("studentId")
                    val message =
                        call.argument<String>("message")

                    if (
                        studentId.isNullOrBlank() ||
                        message.isNullOrBlank()
                    ) {
                        result.error(
                            "INVALID_REQUEST",
                            "A student account and challenge are required.",
                            null
                        )
                    } else {
                        runKeyTask(result) {
                            NfcPhoneKeyStore.signRegistrationChallenge(
                                studentId,
                                message
                            )
                        }
                    }
                }

                "signCardAssignmentChallenge" -> {
                    val studentId =
                        call.argument<String>("studentId")
                    val challengeId =
                        call.argument<String>("challengeId")
                    val phoneCredentialId =
                        call.argument<String>("phoneCredentialId")
                    val cardUid =
                        call.argument<String>("cardUid")
                    val ndefPayload =
                        call.argument<String>("ndefPayload")
                    val message =
                        call.argument<String>("message")

                    if (
                        studentId.isNullOrBlank() ||
                        challengeId.isNullOrBlank() ||
                        phoneCredentialId.isNullOrBlank() ||
                        cardUid.isNullOrBlank() ||
                        ndefPayload.isNullOrBlank() ||
                        message.isNullOrBlank()
                    ) {
                        result.error(
                            "INVALID_REQUEST",
                            "Complete card-assignment details are required.",
                            null
                        )
                    } else {
                        runKeyTask(result) {
                            NfcPhoneKeyStore.signCardAssignmentChallenge(
                                studentId,
                                challengeId,
                                phoneCredentialId,
                                cardUid,
                                ndefPayload,
                                message
                            )
                        }
                    }
                }

                "signOfflineProof" -> {
                    val studentId = call.argument<String>("studentId")
                    val message = call.argument<String>("message")
                    if (studentId.isNullOrBlank() || message.isNullOrBlank()) {
                        result.error("INVALID_REQUEST", "Offline proof is required.", null)
                    } else {
                        runKeyTask(result) {
                            NfcPhoneKeyStore.signOfflineProof(studentId, message)
                        }
                    }
                }
                "signAttendanceChallenge" -> {
                    val studentId = call.argument<String>("studentId")
                    val message = call.argument<String>("message")
                    val context = call.argument<Map<String, String>>("context")
                    if (studentId.isNullOrBlank() || message.isNullOrBlank() || context == null) {
                        result.error("INVALID_REQUEST", "Attendance context is required.", null)
                    } else {
                        runKeyTask(result) {
                            NfcPhoneKeyStore.signAttendanceChallenge(studentId, message, context)
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}