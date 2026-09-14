import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. The keystore is NOT part of this repository: CI writes
// android/key.properties and android/release/asset-tracker-release.keystore
// from repository secrets before building. Gradle signs with that legacy key
// so every APK keeps a v2 signature that older devices recognise, and
// release.yml then re-signs with apksigner to add the current key and its
// proof-of-rotation lineage in the v3 block.
// A stable signature is required either way: without it Flutter falls back to
// the per-machine debug keystore and Android rejects in-place updates
// ("an app with a conflicting signature has been installed").
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.assettracker.asset_tracker"
    // Pinned to 36: flutter_local_notifications (and its Android plugin)
    // requires compileSdk 36; keep in sync with plugin requirements.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by the flutter_local_notifications AAR (minSdk 24).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.assettracker.asset_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }

    dependencies {
        // Core library desugaring (required by flutter_local_notifications).
        coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
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
