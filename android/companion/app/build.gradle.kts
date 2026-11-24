import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release builds pass -PorbitVersion=<tag without "v"> (.github/workflows/release.yml).
// versionCode = MAJOR*10000 + MINOR*100 + PATCH, so every release tag installs over the last.
val orbitVersion = (findProperty("orbitVersion") as String?)?.removePrefix("v") ?: "0.0.0-dev"
val orbitVersionCode: Int = run {
    val m = Regex("""^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$""").matchEntire(orbitVersion)
        ?: error("orbitVersion '$orbitVersion' is not MAJOR.MINOR.PATCH[-pre]")
    val (major, minor, patch) = m.destructured.toList().map { it.toInt() }
    require(minor < 100 && patch < 100) { "minor and patch must stay below 100 for the versionCode formula" }
    maxOf(1, major * 10_000 + minor * 100 + patch)
}

// Release signing from the environment only; without it, release builds are unsigned and
// debug builds use the usual debug key.
val releaseKeystore: String? = System.getenv("ORBIT_KEYSTORE_FILE")

android {
    namespace = "net.fledgewing.orbitcompanion"
    compileSdk = 34
    buildToolsVersion = "34.0.0"

    defaultConfig {
        applicationId = "net.fledgewing.orbitcompanion"
        minSdk = 26
        // 28 on purpose: WifiManager.setWifiEnabled only works for apps targeting 28 or lower.
        //noinspection ExpiredTargetSdkVersion
        targetSdk = 28
        versionCode = orbitVersionCode
        versionName = orbitVersion
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storeType = "pkcs12"
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    lint {
        disable += setOf("ExpiredTargetSdkVersion", "OldTargetApi")
    }

    // Robolectric (UpdaterSessionTest): the install-session states against Android's own
    // PackageInstaller, on the JVM (docs/design/emulated-release-tests.md, stage 2).
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

val robolectricAndroid: Configuration by configurations.creating

dependencies {
    testImplementation("junit:junit:4.13.2")
    // Android ships org.json; plain JVM unit tests need the real one (StatsExport).
    testImplementation("org.json:json:20240303")
    testImplementation("org.robolectric:robolectric:4.14.1")
    // Android 14 for @Config(sdk = [34]); Robolectric 4.14.1 also reads the app's resources with
    // its newest SDK, 15.
    robolectricAndroid("org.robolectric:android-all-instrumented:14-robolectric-10818077-i7")
    robolectricAndroid("org.robolectric:android-all-instrumented:15-robolectric-12650502-i7")
}

// Robolectric's Android 14 jar comes through Gradle (cached, retried) instead of Robolectric's own
// download at test time, which failed in CI (MavenArtifactFetcher); the tests then run offline.
// The versions are the ones Robolectric 4.14.1 asks for (its DefaultSdkProvider).
val robolectricJars = layout.buildDirectory.dir("robolectric-jars")
val copyRobolectricJars = tasks.register<Copy>("copyRobolectricJars") {
    from(robolectricAndroid)
    into(robolectricJars)
}
tasks.withType<Test>().configureEach {
    dependsOn(copyRobolectricJars)
    systemProperty("robolectric.offline", "true")
    systemProperty("robolectric.dependency.dir", robolectricJars.get().asFile.absolutePath)
    // A failure in CI shows its message, not only the exception's class.
    testLogging { exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

/**
 * Third-party notices for everything in the runtime classpath: each module with its POM license,
 * any LICENSE/NOTICE files inside its jar, and the full Apache-2.0 text. Shipped as the asset
 * open_source_licenses.txt (Settings › Open-source licenses) and attached to each release.
 */
abstract class OpenSourceNotices : DefaultTask() {
    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:InputFile
    abstract val apacheLicense: RegularFileProperty

    @get:Input
    abstract val configurationName: Property<String>

    @TaskAction
    fun generate() {
        val cfg = project.configurations.getByName(configurationName.get())
        val modules = cfg.incoming.resolutionResult.allComponents
            .filter { it.id is org.gradle.api.artifacts.component.ModuleComponentIdentifier }
            .mapNotNull { it.moduleVersion }
            .filter { it.group.isNotEmpty() }
            .sortedBy { "${it.group}:${it.name}" }
        val jarType = Attribute.of("artifactType", String::class.java)
        val jars = cfg.incoming.artifactView {
            isLenient = true
            attributes { attribute(jarType, "jar") }
        }.artifacts.associate { a ->
            val id = a.id.componentIdentifier
            (if (id is org.gradle.api.artifacts.component.ModuleComponentIdentifier) "${id.group}:${id.module}" else id.displayName) to a.file
        }

        fun pomLicenses(coord: String, depth: Int = 0): List<String> {
            val pom = try {
                project.configurations.detachedConfiguration(project.dependencies.create("$coord@pom")).apply { isTransitive = false }.singleFile.readText()
            } catch (e: Exception) {
                return emptyList()
            }
            val found = Regex("""<license>\s*<name>([^<]+)</name>(?:\s*<url>([^<]+)</url>)?""").findAll(pom)
                .map { it.groupValues[1].trim() + (it.groupValues[2].takeIf { u -> u.isNotBlank() }?.let { u -> " <${u.trim()}>" } ?: "") }.toList()
            if (found.isNotEmpty() || depth > 2) return found
            val parent = Regex("""<parent>\s*<groupId>([^<]+)</groupId>\s*<artifactId>([^<]+)</artifactId>\s*<version>([^<]+)</version>""").find(pom)
                ?: return emptyList()
            return pomLicenses(parent.groupValues.drop(1).joinToString(":"), depth + 1)
        }

        val sb = StringBuilder()
        sb.append("Orbit Companion: third-party notices\n")
        sb.append("Orbit Companion itself is MIT-licensed (https://github.com/Fledgewing/Orbify).\n")
        sb.append("It bundles the libraries below. Generated at build time from the runtime classpath.\n\n")
        for (m in modules) {
            val coord = "${m.group}:${m.name}:${m.version}"
            val lic = pomLicenses(coord).ifEmpty { listOf("see the project's site") }
            sb.append("== $coord\n")
            lic.forEach { sb.append("   License: $it\n") }
            jars["${m.group}:${m.name}"]?.takeIf { it.isFile && it.name.endsWith(".jar") }?.let { jar ->
                ZipFile(jar).use { z ->
                    z.entries().asSequence()
                        .filter { !it.isDirectory && Regex("""(?i)(^|/)(LICENSE|NOTICE|COPYING)[^/]*$""").containsMatchIn(it.name) }
                        .forEach { e ->
                            sb.append("   --- ${e.name}\n")
                            sb.append(z.getInputStream(e).readBytes().toString(Charsets.UTF_8).trimEnd()).append("\n")
                        }
                }
            }
            sb.append("\n")
        }
        sb.append("==================================================================\n")
        sb.append(apacheLicense.get().asFile.readText())
        val out = outputDir.get().asFile
        out.mkdirs()
        File(out, "open_source_licenses.txt").writeText(sb.toString())
        logger.lifecycle("open-source notices: ${modules.size} modules -> ${File(out, "open_source_licenses.txt")}")
    }
}

androidComponents {
    onVariants { variant ->
        val task = tasks.register<OpenSourceNotices>("${variant.name}OpenSourceNotices") {
            apacheLicense.set(layout.projectDirectory.file("licenses/Apache-2.0.txt"))
            configurationName.set("${variant.name}RuntimeClasspath")
            doNotTrackState("reads the resolved classpath; cheap to regenerate")
        }
        variant.sources.assets?.addGeneratedSourceDirectory(task, OpenSourceNotices::outputDir)
    }
}
