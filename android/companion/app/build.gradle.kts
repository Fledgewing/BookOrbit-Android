import net.fledgewing.orbitcompanion.AndroidVersionCode
import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release builds pass -PorbitVersion=<tag without "v"> (.github/workflows/release.yml).
// Shared encoder: preview.N < rc.N < stable, with codes above the legacy releases.
val orbitVersion = (findProperty("orbitVersion") as String?)?.removePrefix("v") ?: "0.0.0-dev"
val orbitVersionCode: Int = run {
    val m = Regex("""^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$""").matchEntire(orbitVersion)
        ?: error("orbitVersion '$orbitVersion' is not MAJOR.MINOR.PATCH[-pre]")
    val (major, minor, patch, pre) = m.destructured
    AndroidVersionCode.encode(major.toInt(), minor.toInt(), patch.toInt(), pre.ifEmpty { null })
}

// Release signing from the environment only; without it, release builds are unsigned and
// debug builds use the usual debug key.
val releaseKeystore: String? = System.getenv("ORBIT_KEYSTORE_FILE")

// The release-signing root key, minimum release-key serial and enforce switch, shared with the
// firmware (docs/design/release-signing.md): the plugin zip is checked against them.
@Suppress("UNCHECKED_CAST")
val releaseSigning = groovy.json.JsonSlurper()
    .parse(file("../../../shared/release-signing.json")) as Map<String, Any?>
val releaseRootKey = (releaseSigning["root_public_key"] as String?).orEmpty()
require(releaseRootKey.isEmpty() || Regex("^[0-9a-f]{64}$").matches(releaseRootKey)) {
    "shared/release-signing.json root_public_key must be empty or 64 lowercase hex characters"
}

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
        buildConfigField("String", "RELEASE_ROOT_KEY", "\"$releaseRootKey\"")
        buildConfigField("long", "RELEASE_MIN_SERIAL", "${(releaseSigning["min_release_key_serial"] as Number).toLong()}L")
        buildConfigField("boolean", "RELEASE_SIG_ENFORCE", "${releaseSigning["enforce"] == true}")
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

// One configuration per jar: both are versions of one module, and a single configuration would
// keep only the newer one (Gradle's conflict resolution).
val robolectricAndroid14: Configuration by configurations.creating
val robolectricAndroid15: Configuration by configurations.creating

dependencies {
    testImplementation("junit:junit:4.13.2")
    // Android ships org.json; plain JVM unit tests need the real one (StatsExport).
    testImplementation("org.json:json:20240303")
    testImplementation("org.robolectric:robolectric:4.14.1")
    // SQLite on the plain JVM: the offline cache's database code against a real SQLite (JdbcSql).
    testImplementation("org.xerial:sqlite-jdbc:3.46.1.3")
    // Android 14 for @Config(sdk = [34]); Robolectric 4.14.1 also reads the app's resources with
    // its newest SDK, 15.
    robolectricAndroid14("org.robolectric:android-all-instrumented:14-robolectric-10818077-i7")
    robolectricAndroid15("org.robolectric:android-all-instrumented:15-robolectric-12650502-i7")
}

// Robolectric's Android jars come through Gradle (cached, retried) instead of Robolectric's own
// download at test time, which failed in CI (MavenArtifactFetcher); the tests then run offline.
// The versions are the ones Robolectric 4.14.1 asks for (its DefaultSdkProvider).
val robolectricJars = layout.buildDirectory.dir("robolectric-jars")
val copyRobolectricJars = tasks.register<Sync>("copyRobolectricJars") {
    from(robolectricAndroid14, robolectricAndroid15)
    into(robolectricJars)
    doLast {
        val jars = robolectricJars.get().asFile.listFiles().orEmpty().filter { it.name.endsWith(".jar") }
        logger.lifecycle("Robolectric jars: " + jars.joinToString { "${it.name} (${it.length() / 1_000_000} MB)" })
        check(jars.size == 2) { "Robolectric's Android jars did not resolve" }
    }
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
        sb.append("BookSync Companion: third-party notices\n")
        sb.append("BookSync Companion itself is MIT-licensed (https://github.com/Fledgewing/BookSync).\n")
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

/**
 * The settings shared with the Orbit plugin (docs/design/companion-settings.md §4.1): one file,
 * shared/settings/schema.json, copied into the assets as settings_schema.json.
 */
abstract class SettingsSchemaAsset : DefaultTask() {
    @get:InputFile
    abstract val schema: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile
        out.mkdirs()
        schema.get().asFile.copyTo(File(out, "settings_schema.json"), overwrite = true)
    }
}

abstract class AboutCreditsAsset : DefaultTask() {
    @get:InputFile abstract val source: RegularFileProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction fun copy() {
        val out = outputDir.get().asFile
        out.mkdirs()
        source.get().asFile.copyTo(File(out, "about_credits.json"), overwrite = true)
    }
}

androidComponents {
    onVariants { variant ->
        val aboutCredits = tasks.register<AboutCreditsAsset>("${variant.name}AboutCredits") {
            source.set(layout.projectDirectory.file("../../../shared/about/credits.json"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(aboutCredits, AboutCreditsAsset::outputDir)
        val schemaTask = tasks.register<SettingsSchemaAsset>("${variant.name}SettingsSchema") {
            schema.set(layout.projectDirectory.file("../../../shared/settings/schema.json"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(schemaTask, SettingsSchemaAsset::outputDir)
        val task = tasks.register<OpenSourceNotices>("${variant.name}OpenSourceNotices") {
            apacheLicense.set(layout.projectDirectory.file("licenses/Apache-2.0.txt"))
            configurationName.set("${variant.name}RuntimeClasspath")
            doNotTrackState("reads the resolved classpath; cheap to regenerate")
        }
        variant.sources.assets?.addGeneratedSourceDirectory(task, OpenSourceNotices::outputDir)
    }
}

// One battery drawing program for the companion sleep screen and Lua reading strips.
android.sourceSets["main"].resources.srcDir("../../../shared/ui")
