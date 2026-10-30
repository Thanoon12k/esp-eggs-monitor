plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.thanoon.egg_incubator"
    // flutter_local_notifications needs compileSdk 36 or newer
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // needed by flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.thanoon.egg_incubator"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The release build is signed with android/app/upload.jks when the build machine provides it,
    // so every build has the same signature and updates install over the old version.
    val uploadKey = file("upload.jks")
    signingConfigs {
        if (uploadKey.exists()) {
            create("upload") {
                storeFile = uploadKey
                storePassword = System.getenv("UPLOAD_STORE_PASSWORD") ?: "incubator"
                keyAlias = "incubator"
                keyPassword = System.getenv("UPLOAD_KEY_PASSWORD") ?: "incubator"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
        }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
