plugins {
    id("com.android.application")
    id("kotlin-android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "systems.neolabs.neorecall.wear"
    compileSdk = 36

    signingConfigs {
        create("sharedDebug") {
            storeFile = file("../app/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    defaultConfig {
        applicationId = "systems.neolabs.neorecall"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures { compose = true }

    buildTypes {
        debug { signingConfig = signingConfigs.getByName("sharedDebug") }
        release {
            signingConfig = signingConfigs.getByName("sharedDebug")
            // A watch has far less storage than a phone and installs this over
            // Bluetooth or ADB. Compose, ProtoLayout and Play services together
            // are most of the APK, and almost none of it is reachable.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_11.toString() }
}

dependencies {
    implementation(project(":wear-protocol"))
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.compose.ui:ui:1.8.2")
    implementation("androidx.compose.ui:ui-tooling-preview:1.8.2")
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    implementation("androidx.wear.compose:compose-material3:1.5.6")
    implementation("androidx.wear.compose:compose-foundation:1.5.6")
    implementation("androidx.wear:wear-ongoing:1.1.0")
    implementation("androidx.wear.tiles:tiles:1.5.0")
    implementation("androidx.wear.protolayout:protolayout:1.3.0")
    implementation("androidx.wear.protolayout:protolayout-material3:1.3.0")
    implementation("androidx.wear.watchface:watchface-complications-data-source-ktx:1.2.1")
    implementation("com.google.android.gms:play-services-wearable:20.0.1")
    // play-services-wearable still drags in Fragment 1.1.0, whose FragmentActivity
    // mishandles the Activity Result APIs this app's permission prompt uses.
    // Nothing here uses fragments; this only keeps the stale copy off the classpath.
    implementation("androidx.fragment:fragment:1.8.9")
}
