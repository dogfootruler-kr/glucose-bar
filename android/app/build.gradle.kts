plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Release builds get their version from the tag (-PversionName=1.2.0, see .github/workflows/release.yml);
// local builds are "dev", which never updates itself.
val version = providers.gradleProperty("versionName").getOrElse("dev")
val code = Regex("""(\d+)\.(\d+)\.(\d+)""").matchEntire(version)?.destructured
    ?.let { (major, minor, patch) -> major.toInt() * 10000 + minor.toInt() * 100 + patch.toInt() } ?: 1

android {
    namespace = "co.dnk.glucosebar"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "co.dnk.glucosebar"
        minSdk = 31
        targetSdk = 37
        versionCode = code
        versionName = version
    }

    signingConfigs {
        create("release") {
            System.getenv("KEYSTORE_PATH")?.let { storeFile = file(it) }
            storePassword = System.getenv("KEYSTORE_PASSWORD")
            keyAlias = System.getenv("KEY_ALIAS")
            keyPassword = System.getenv("KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            optimization {
                enable = true
            }
            // Without the keystore (a local build), release falls back to the debug key.
            signingConfig = signingConfigs.getByName(if (System.getenv("KEYSTORE_PATH") != null) "release" else "debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.02.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation("junit:junit:4.13.2")
}
