plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "systems.neolabs.neorecall"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        getByName("debug") {
            // Fixed keystore committed to the repo (android/app/debug.keystore)
            // so every build machine and every CI run signs with the same
            // key. Without this, Android Gradle Plugin auto-generates a new
            // random debug key on any machine that lacks
            // ~/.android/debug.keystore (e.g. every fresh GitHub Actions
            // runner), so each CI-built APK gets a different signature and
            // can't be installed as an update over the previous one.
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "systems.neolabs.neorecall"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // opus_codec_android and the Plaud AAR both ship libopus.so. Keep one copy
    // so assembleRelease can merge native libs. Plaud's liblame.so is 4 KB
    // aligned; the app jniLibs copy is rebuilt for 16 KB pages.
    packaging {
        jniLibs {
            useLegacyPackaging = false
            pickFirsts += "**/libopus.so"
            pickFirsts += "**/liblame.so"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    implementation(project(":wear-protocol"))
    implementation("com.google.android.gms:play-services-wearable:20.0.1")
    testImplementation("junit:junit:4.13.2")
}
