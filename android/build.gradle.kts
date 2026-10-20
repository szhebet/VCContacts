allprojects {
    repositories {
        google()
        // Maven Central через официальный хост repo1.maven.org
        // (см. settings.gradle.kts — сеть сборки недоступен repo.maven.apache.org)
        maven { url = uri("https://repo1.maven.org/maven2") }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
