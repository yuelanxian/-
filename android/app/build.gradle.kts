import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
}

// Version: defaults below; CI passes -PhvVersionName=1.2.3 -PhvVersionCode=10203 for tags v1.2.3.
val hvVersionName: String = providers.gradleProperty("hvVersionName").getOrElse("1.0.0")
val hvVersionCode: Int = providers.gradleProperty("hvVersionCode").map { it.toInt() }.getOrElse(1)

// Release signing from the environment (CI decodes the HV_ANDROID_KEYSTORE_B64 secret into a file).
// Without it the release APK is signed with the local debug key.
val releaseKeystore: String? =
    providers.environmentVariable("HV_ANDROID_KEYSTORE_FILE").orNull?.takeIf { it.isNotBlank() }

android {
    namespace = "app.homevault.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.homevault.android"
        minSdk = 26
        targetSdk = 36
        versionCode = hvVersionCode
        versionName = hvVersionName
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = providers.environmentVariable("HV_ANDROID_KEYSTORE_PASSWORD").orNull
                keyAlias = providers.environmentVariable("HV_ANDROID_KEY_ALIAS").orNull
                keyPassword = providers.environmentVariable("HV_ANDROID_KEY_PASSWORD").orNull
            }
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // Test-only; nothing is packaged into the APK besides the Kotlin standard library.
    testImplementation("junit:junit:4.13.2")
}
