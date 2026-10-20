pluginManagement {
    val flutterSdkPath = run {
        // local.properties создаёт flutter tool автоматически на dev-машине.
        // В Docker-сборке файла ещё нет на этапе gradle wrapper — тогда
        // берём FLUTTER_HOME из окружения образа.
        val localProps = file("local.properties")
        val properties = java.util.Properties()
        if (localProps.exists()) {
            localProps.inputStream().use { properties.load(it) }
        }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
            ?: System.getenv("FLUTTER_HOME")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        return@run flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        // Maven Central: официальный хост repo1.maven.org (тот же Central,
        // что и repo.maven.apache.org). Plugin-marker'ы Kotlin и AGP
        // доступны в google() + Central, gradlePluginPortal не нужен.
        maven { url = uri("https://repo1.maven.org/maven2") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.3.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}

include(":app")
