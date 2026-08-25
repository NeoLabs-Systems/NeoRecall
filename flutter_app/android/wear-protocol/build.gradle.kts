plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "systems.neolabs.neorecall.wear.protocol"
    compileSdk = 36

    defaultConfig { minSdk = 26 }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_11.toString() }
}
