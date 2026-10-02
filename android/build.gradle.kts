allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some plugins (vibration, and other older ones) still compile against android-33, but the
// AndroidX libraries they pull in require 34+. Raise every plugin's compileSdk; this only
// changes which APIs they compile against, not their minSdk or runtime behaviour. Registered
// before evaluationDependsOn below so the hook exists before the plugins are evaluated.
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            extensions.getByName("android").withGroovyBuilder {
                "compileSdkVersion"(36)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
