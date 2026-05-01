plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.fortress"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Core library desugaring : nécessaire pour `flutter_local_notifications`
        // (et plus largement les API Java 8+ utilisées sur des minSdk anciens).
        // Sans ça, le build Android échoue avec :
        //   "Dependency ':flutter_local_notifications' requires core library
        //    desugaring to be enabled for :app."
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.fortress"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk forcé à 21 (au lieu de `flutter.minSdkVersion`) :
        //   - flutter_local_notifications ^17.x exige min 21
        //   - core library desugaring exige min 21
        // Si une version Flutter ancienne renvoie minSdk=19, on garde 21.
        minSdk = maxOf(21, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pair de la conf `isCoreLibraryDesugaringEnabled = true` ci-dessus.
    // Fournit le runtime pour les API Java 8+ rétro-compatibles.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
