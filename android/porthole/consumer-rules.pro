# Porthole starts itself from a ContentProvider and reads Compose through
# reflection-free public API; keep its entry points in minified debug builds.
-keep class dev.porthole.** { *; }
