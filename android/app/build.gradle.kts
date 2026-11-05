plugins {
    id("com.android.application")
    // Chaquopy: ejecuta Python dentro de la app (sin servidor)
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dosimetro.dosimetro"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dosimetro.dosimetro"
        minSdk = maxOf(24, flutter.minSdkVersion) // Chaquopy requiere API 24+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // arm64-v8a: teléfonos reales; x86_64: emuladores
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // Firmado con la llave de depuración: basta para instalar el APK a mano.
            signingConfig = signingConfigs.getByName("debug")
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

chaquopy {
    defaultConfig {
        // Debe coincidir con un Python 3.13 instalado en el PC (se busca con "py -3.13")
        version = "3.13"
        pip {
            install("reportlab==4.2.5")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
