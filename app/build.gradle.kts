plugins { id("com.android.application"); id("org.jetbrains.kotlin.android"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace = "it.blackout.mesh"
    compileSdk = 35
    defaultConfig {
        applicationId = "it.darkproof.mesh"
        minSdk = 26; targetSdk = 34; versionCode = 4; versionName = "0.4"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildFeatures { compose = true }
    // Native libraries compressed inside the APK: the file people share offline (Quick Share, Bluetooth) is much smaller.
    packaging { jniLibs { useLegacyPackaging = true } }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
dependencies {
    implementation("com.google.android.gms:play-services-nearby:19.3.0")
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.1") // on-device AI (Gemma 4); needs Kotlin 2.4
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("com.google.zxing:core:3.5.3") // invite QR codes, offline
    implementation("org.maplibre.gl:android-sdk:12.3.1") // offline street maps (OpenFreeMap)
    implementation("com.squareup.okhttp3:okhttp:4.12.0") // MapLibre's HTTP client: User-Agent and 4-connection limit
    testImplementation("junit:junit:4.13.2")
}
