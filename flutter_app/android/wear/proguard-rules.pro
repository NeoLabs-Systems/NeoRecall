# Tiles and complications are instantiated by the system from the manifest, and
# the AndroidX libraries reach their builders reflectively in places. The
# manifest entries already keep the service classes; these keep the members the
# frameworks call on them.
-keep class systems.neolabs.neorecall.wear.tiles.** { *; }
-keep class systems.neolabs.neorecall.wear.complications.** { *; }

# The shared phone/watch contract is compared field by field across two APKs
# that are built and shipped separately.
-keep class systems.neolabs.neorecall.wear.protocol.** { *; }
