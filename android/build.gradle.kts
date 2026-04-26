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

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
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
    implementation("androidx.browser:browser:1.8.0")
    implementation("net.openid:appauth:0.11.1")
    // The shared Tauri runtime exposes Jackson at runtime via
    // `implementation`, so we need our own compile-time pull-in for the
    // `@JsonTypeInfo` / `@JsonSubTypes` annotations on `ConfigSource`.
    implementation("com.fasterxml.jackson.core:jackson-annotations:2.15.3")
    implementation(project(":tauri-android"))
}
