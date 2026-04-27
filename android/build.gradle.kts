// Toolchain floor:
//   * Android Gradle Plugin 8.6+   (required for compileSdk 36)
//   * Kotlin 2.1+                  (matches `settings.gradle` plugin pin)
//   * JDK 17                       (sourceCompatibility / jvmTarget below)
// Host Tauri apps pinning older AGP versions must upgrade before consuming
// this library.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.tauri.appauth"
    compileSdk = 36

    defaultConfig {
        minSdk = 24

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.browser:browser:1.8.0")
    implementation("net.openid:appauth:0.11.1")
    // Annotations carry no executable code, and the host Tauri runtime
    // brings a matching `jackson-annotations` in transitively via
    // `jackson-databind`. `compileOnly` avoids version skew with whatever
    // the host pins. Databind itself stays `implementation` because
    // `AuthEvent.Serializer` subclasses `JsonSerializer`, which must
    // resolve at runtime when this library is built in isolation.
    compileOnly("com.fasterxml.jackson.core:jackson-annotations:2.15.3")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.15.3")
    implementation(project(":tauri-android"))
}
