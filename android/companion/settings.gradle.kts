pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        // Robolectric's Android jars (150-200 MB each, tests only) from Google's mirror of Maven
        // Central: Central answers shared CI runners with 429 Too Many Requests for them.
        exclusiveContent {
            forRepository { maven("https://maven-central.storage-download.googleapis.com/maven2/") }
            filter { includeModule("org.robolectric", "android-all-instrumented") }
        }
        mavenCentral()
    }
}
rootProject.name = "OrbitCompanion"
include(":app")
