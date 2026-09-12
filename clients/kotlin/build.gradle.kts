import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm") version "2.0.21"
    application
}

group = "com.priostack"
version = "0.3.0"

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
}

java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

application {
    // The quickstart's top-level `main` compiles to this class. Pass -PmainClass to run another
    // example, e.g.:
    //   ./gradlew run -PmainClass=com.priostack.acn.examples.ShareQuickstartKt
    mainClass.set(
        (project.findProperty("mainClass") as String?)
            ?: "com.priostack.acn.examples.QuickstartKt",
    )
}
