# SceneHarbor lock rendering runtime

MirageWallpaper GPL-3.0 source is pinned by runtime.json and included in
Vendor/MirageBaseline/source.tar.gz. Extract that archive, then apply
first-presented.patch at its root before building the MirageSceneSaver target.
The patch exposes actual CAMetalDrawable presentation readiness; it does not
change wallpaper rendering or scheduling. Both the source patch and frozen
binaries are included in SHA256SUMS. MoltenVK is licensed separately.

This local runtime links dependencies requiring macOS 26.0 or later. The saver
and wallpaper extension declare that minimum even though the main app can run
on older macOS releases.
