// Maven Central answers shared CI runners with 429 Too Many Requests. Google's mirror of Central
// comes first, so Central itself is asked only for what the mirror lacks (a 404 there falls
// through; any other error fails the build). CI also restores ~/.gradle from the Actions cache.
pluginManagement {
    repositories {
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        mavenCentral()
    }
}
rootProject.name = "OrbitCompanion"
include(":app")
