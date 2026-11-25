plugins { java }

// Compile the same pure Java encoder for Gradle and the app: package codes cannot drift.
sourceSets.main {
    java.srcDir("../app/src/main/java")
    java.include("net/fledgewing/orbitcompanion/AndroidVersionCode.java")
}
