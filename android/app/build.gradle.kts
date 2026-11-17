plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.shiri.anniversary"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "26.3.11579264"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.shiri.anniversary"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets["main"].res.srcDir(layout.buildDirectory.dir("generated/shiri-fonts"))

    buildTypes {
        release {
            // Production signing is supplied by the release environment, never a debug key.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

// Reuse the reviewed offline font assets for native RemoteViews text.
val prepareWidgetFonts by tasks.registering(Copy::class) {
    from("../../assets/font") {
        include("*.otf")
        exclude("*bold.otf", "._*")
    }
    into(layout.buildDirectory.dir("generated/shiri-fonts/font"))
}
tasks.named("preBuild").configure { dependsOn(prepareWidgetFonts) }
