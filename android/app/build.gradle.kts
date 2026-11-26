import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Development builds use the same signing key across team computers.
// This APK signing key is separate from students' local NFC keys.
val teamDebugKeyFile = file(
    providers.environmentVariable("COMPTECH_DEBUG_KEYSTORE").orNull
        ?.takeIf { it.isNotBlank() }
        ?: "${System.getProperty("user.home")}/.android/comptech-team-debug.keystore"
)

val expectedDebugCertificateSha256 =
    "6AC381559A4CC1DC0709F1322C3AAD8BD492C32960894698E6DF52E96D8BB1F2"

if (!teamDebugKeyFile.isFile) {
    throw GradleException(
        "CompTech team development keystore is missing. " +
                "Copy the agreed existing keystore to ${teamDebugKeyFile.absolutePath}. " +
                "Do not generate a replacement key or uninstall the app."
    )
}

val actualDebugCertificateSha256: String = try {
    val keyStore = KeyStore.getInstance(
        teamDebugKeyFile,
        "android".toCharArray()
    )

    if (!keyStore.isKeyEntry("AndroidDebugKey")) {
        throw GradleException(
            "AndroidDebugKey private-key entry is missing."
        )
    }

    val certificate = keyStore.getCertificate("AndroidDebugKey")
        ?: throw GradleException(
            "AndroidDebugKey certificate is missing."
        )

    MessageDigest.getInstance("SHA-256")
        .digest(certificate.encoded)
        .joinToString("") { byte ->
            "%02X".format(byte.toInt() and 0xff)
        }
} catch (error: Exception) {
    throw GradleException(
        "Cannot read the CompTech development signing key. " +
                "Use the agreed original debug keystore; do not regenerate it.",
        error
    )
}

if (actualDebugCertificateSha256 != expectedDebugCertificateSha256) {
    throw GradleException(
        "Wrong CompTech development signing certificate. " +
                "Expected SHA-256: $expectedDebugCertificateSha256; " +
                "found: $actualDebugCertificateSha256. " +
                "Get the agreed keystore from the current development computer. " +
                "Do not change this fingerprint to bypass the check or uninstall the app."
    )
}

android {
    namespace = "com.example.comptech_portal_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.comptech_portal_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        getByName("debug") {
            storeFile = teamDebugKeyFile
            storePassword = "android"
            keyAlias = "AndroidDebugKey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }

        release {
            // Preserve existing development-only release signing.
            // Production distribution needs a separate signing plan.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}