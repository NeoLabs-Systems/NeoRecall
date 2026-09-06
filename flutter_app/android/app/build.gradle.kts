plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "systems.neolabs.neorecall"
    compileSdk = flutter.compileSdkVersion
    // r28 defaults to 16 KB pages and pads GNU_RELRO to a 16 KB boundary.
    // Flutter 3.35 still pins r27, whose lld leaves RELRO on a 4 KB end.
    ndkVersion = "28.2.13676358"

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
            // Debug Impeller validation layer; not needed on device and fails
            // Pixel 16 KB RELRO checks.
            excludes += "**/libVkLayer_khronos_validation.so"
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
    // Plaud still declares conscrypt; 2.6.2 is the first Maven build whose
    // GNU_RELRO ends on a 16 KB page (2.5.3 only fixed LOAD alignment).
    implementation("org.conscrypt:conscrypt-android:2.6.2")
    implementation("androidx.datastore:datastore:1.2.1")
    implementation("androidx.datastore:datastore-preferences:1.2.1")
    testImplementation("junit:junit:4.13.2")
}

configurations.all {
    resolutionStrategy {
        force("org.conscrypt:conscrypt-android:2.6.2")
        force("androidx.datastore:datastore:1.2.1")
        force("androidx.datastore:datastore-android:1.2.1")
        force("androidx.datastore:datastore-core:1.2.1")
        force("androidx.datastore:datastore-core-android:1.2.1")
        force("androidx.datastore:datastore-preferences:1.2.1")
        force("androidx.datastore:datastore-preferences-android:1.2.1")
    }
}
