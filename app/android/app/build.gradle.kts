import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-Signierung: PAPERBUDDY_SIGNING (Pfad zu einer key.properties mit
// storeFile, storePassword, keyAlias, keyPassword), sonst
// ~/PaperBuddy/keys/android/key.properties. Ohne sie signieren
// Release-Builds mit dem Debug-Schlüssel.
val signingProperties = Properties().apply {
    val file = file(
        System.getenv("PAPERBUDDY_SIGNING")
            ?: "${System.getProperty("user.home")}/PaperBuddy/keys/android/key.properties",
    )
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "de.status403.paperbuddy"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "de.status403.paperbuddy"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildFeatures {
        resValues = true
    }

    // prod = PaperBuddy, dev = eigene App daneben (tool/dev.sh android).
    flavorDimensions += "env"
    productFlavors {
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "PaperBuddy")
        }
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "PaperBuddy Dev")
        }
    }

    signingConfigs {
        if (signingProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
