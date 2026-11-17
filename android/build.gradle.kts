allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// An internal-disk output path avoids AppleDouble sidecars when source is on exFAT.
// Default remains Flutter's conventional build directory on supported filesystems.
val newBuildDir: Directory = rootProject.layout.dir(providers.provider {
    System.getenv("SHIRI_ANDROID_BUILD_DIR")?.let { file(it) } ?: file("../build")
}).get()
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
