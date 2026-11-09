// The Porthole harness for Android (:porthole) and its demo app (:demo).
// Build with Gradle 8.11 or later and JDK 17: `gradle :porthole:test :demo:assembleDebug`.
plugins {
    id("com.android.library") version "8.7.3" apply false
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}
