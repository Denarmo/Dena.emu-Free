import java.security.MessageDigest

group = "app.dena.dena_android"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// ---- Emulator cores and the bundled test ROM (docs/specs/latency-spike.md) ----
val repoRoot = file("../../..")
val coresOut = layout.buildDirectory.dir("dena/jniLibs").get().asFile
val romAssets = layout.buildDirectory.dir("dena/assets").get().asFile
val coreAbis = listOf("arm64-v8a", "x86_64")

// Builds every packaged core (docs/specs/cores-m2.md) for each ABI with
// cores/<name>/build.sh and packages it as lib<name>_libretro.so.
// Needs bash and ANDROID_NDK_HOME (or ANDROID_NDK_LATEST_HOME).
val coreNames = listOf("mgba", "fceumm", "bsnes", "melonds", "pcsx_rearmed", "mupen64plus", "ppsspp", "fake08")
// Cores built for fewer ABIs (n64.md: no x86_64 dynarec without nasm).
val coreOnlyAbis = mapOf("mupen64plus" to listOf("arm64-v8a"))
val buildCores by tasks.registering {
    for (name in coreNames) inputs.file(File(repoRoot, "cores/$name/build.sh"))
    inputs.file(File(repoRoot, "cores/libretro-make.sh"))
    outputs.dir(coresOut)
    doLast {
        val ndk = System.getenv("ANDROID_NDK_HOME") ?: System.getenv("ANDROID_NDK_LATEST_HOME")
            ?: throw GradleException("Set ANDROID_NDK_HOME to build the emulator cores")
        for (abi in coreAbis) {
            val tmp = File(temporaryDir, abi).apply { deleteRecursively() }
            val dest = File(coresOut, abi).apply { mkdirs() }
            for (name in coreNames.filter { coreOnlyAbis[it]?.contains(abi) ?: true }) {
                // Incremental: objects stay in cores/build/obj (cached in CI).
                val log = File(temporaryDir, "$name-$abi.log")
                val proc = ProcessBuilder("bash", "cores/$name/build.sh", "android-$abi", tmp.absolutePath)
                    .directory(repoRoot)
                    // Log to a file and close stdin: on Windows, make/clang
                    // hang when they inherit the Gradle daemon's std handles.
                    .redirectErrorStream(true)
                    .redirectOutput(log)
                    .apply { environment()["ANDROID_NDK_HOME"] = ndk }
                    .start()
                    .apply { outputStream.close() }
                if (proc.waitFor() != 0) {
                    throw GradleException(
                        "$name build failed for $abi (log: $log):\n" +
                            log.readLines().takeLast(30).joinToString("\n"))
                }
                File(tmp, "${name}_libretro.so").copyTo(File(dest, "lib${name}_libretro.so"), overwrite = true)
            }
        }
    }
}

val copyTestRom by tasks.registering(Copy::class) {
    from(File(repoRoot, "host/tests/roms/latency/latency.gba"))
    into(File(romAssets, "dena"))
}

// PPSSPP's support files (psp.md): system fonts, VFPU tables, PPGe atlas,
// compat.ini, English strings. The checkout exists once buildCores has run.
val coreAssets = layout.buildDirectory.dir("dena/coreAssets").get().asFile
val copyPpssppAssets by tasks.registering(Sync::class) {
    dependsOn(buildCores)
    val src = File(repoRoot, "cores/build/src/ppsspp/assets")
    from(src) {
        include("flash0/**", "vfpu/**", "compat.ini", "knownfuncs.ini", "langregion.ini",
            "lang/en_US.ini", "ppge_atlas.*", "font_atlas.*", "asciifont_atlas.*")
    }
    into(File(coreAssets, "PPSSPP"))
    doLast {
        val tag = Regex("^TAG=(.+)$", RegexOption.MULTILINE)
            .find(File(repoRoot, "cores/ppsspp/build.sh").readText())!!.groupValues[1]
        File(coreAssets, "PPSSPP/dena-assets.txt").writeText(tag)
    }
}

// Bundled shaders (shaders.md), copied to files/shaders on first use. The
// stamp changes with their contents, so updates are picked up.
val shaderAssets = layout.buildDirectory.dir("dena/shaderAssets").get().asFile
val copyShaders by tasks.registering(Sync::class) {
    val src = File(repoRoot, "host/shaders")
    from(src)
    into(File(shaderAssets, "shaders"))
    doLast {
        val digest = MessageDigest.getInstance("SHA-256")
        src.walkTopDown().filter { f -> f.isFile }
            .sortedBy { f -> f.relativeTo(src).invariantSeparatorsPath }
            .forEach { f ->
                digest.update(f.relativeTo(src).invariantSeparatorsPath.toByteArray())
                digest.update(f.readBytes())
            }
        File(shaderAssets, "shaders/dena-assets.txt")
            .writeText(digest.digest().joinToString("") { b -> "%02x".format(b) })
    }
}

tasks.named("preBuild") { dependsOn(buildCores, copyTestRom, copyPpssppAssets, copyShaders) }

android {
    namespace = "app.dena.dena_android"

    compileSdk = 36

    // aapt drops asset folders starting with "_" by default, which lost the
    // xBRZ upscale filter (host/shaders/_upscale) and left GB/GBC/DS 2x-4x
    // unfiltered. Keep the default rules except that one (shaders.md).
    androidResources {
        ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:.*:!CVS:!thumbs.db:!picasa.ini:!*~"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            jniLibs.srcDirs(coresOut)
            assets.srcDirs(romAssets, coreAssets, shaderAssets)
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild {
            cmake {
                arguments("-DANDROID_STL=c++_shared")
            }
        }
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildFeatures {
        prefab = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("com.google.oboe:oboe:1.9.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Music and video players (media-players.md); Apache-2.0.
    implementation("androidx.media3:media3-exoplayer:1.8.0")
    implementation("androidx.media3:media3-session:1.8.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
}
