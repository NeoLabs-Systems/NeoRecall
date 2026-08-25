plugins {
    id("com.android.application")
    id("kotlin-android")
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

    buildTypes {
        debug { signingConfig = signingConfigs.getByName("sharedDebug") }
        release { signingConfig = signingConfigs.getByName("sharedDebug") }
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
    implementation("com.google.android.gms:play-services-wearable:20.0.1")
}
