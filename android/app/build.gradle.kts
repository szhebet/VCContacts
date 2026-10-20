plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.vccontacts.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // AGP 8.x требует Java 17 — согласовано с JDK в Docker-образе
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.vccontacts.app"
        // ML Kit Text Recognition v2 и camera требуют minSdk 21+
        minSdk = 21
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Флаг «приложение собирается с Google Play services»
        manifestPlaceholders["useGms"] = "true"
    }

    buildTypes {
        release {
            // MVP: подписываем debug-ключом, чтобы --split-per-abi сборка
            // работала в CI/Docker без секретов. Перед релизом заменить
            // на release-keystore (см. чеклист в ARCHITECTURE.md).
            signingConfig = signingConfigs.getByName("debug")
            // Правила R8: подавляем ссылки на опциональные классы ML Kit,
            // которых нет в latin-зависимости (см. proguard-rules.pro).
            proguardFiles.add(file("proguard-rules.pro"))
        }
    }

    flavorDimensions += "target"

    productFlavors {
        // Целевая сборка: Samsung S22 и новее (Google Play services на месте)
        create("samsung") {
            dimension = "target"
        }
        // Целевая сборка: Huawei без Google Play services.
        // On-device ML Kit (латиница, модель вшита в APK) работает без GMS,
        // поэтому базовая OCR функциональность сохраняется.
        create("huawei") {
            dimension = "target"
            applicationIdSuffix = ".huawei"
            manifestPlaceholders["useGms"] = "false"
        }
    }

    packagingOptions {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/*.kotlin_module"
            )
        }
    }
}

flutter {
    source = "../.."
}
