plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "it.blackout.mesh"
    compileSdk = 35
    defaultConfig {
        applicationId = "it.blackout.mesh"
        minSdk = 26; targetSdk = 34; versionCode = 3; versionName = "0.3"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation("com.google.android.gms:play-services-nearby:19.3.0")
    implementation("com.google.mediapipe:tasks-genai:0.10.27")
    testImplementation("junit:junit:4.13.2")
}
