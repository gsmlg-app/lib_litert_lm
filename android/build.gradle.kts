group = "dev.gsmlg.litertlm.lib_litert_lm"
version = "1.0-SNAPSHOT"

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.gsmlg.litertlm.lib_litert_lm"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }
}
