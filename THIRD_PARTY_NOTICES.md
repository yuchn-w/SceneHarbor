# SceneHarbor third party notices

This file identifies third party source and license material included in the public SceneHarbor source and app package. License texts are shipped with the paths listed below. Package versions are pinned by `machine-runtime-lock.json`; the portable runtime manifest records the byte hashes used during staging.

## SceneHarbor

- SceneHarbor source: MIT, [`LICENSE.md`](LICENSE.md).
- Public source namespace: `org.sceneharbor.SceneHarbor`.

## MirageWallpaper runtime

- MirageWallpaper source and frozen runtime assets: GPL-3.0, [`Vendor/MirageBaseline/LICENSE`](Vendor/MirageBaseline/LICENSE).
- Upstream source: [laobamac/MirageWallpaper](https://github.com/laobamac/MirageWallpaper).
- The pinned source archive is `Vendor/MirageBaseline/source.tar.gz`; apply `Vendor/LockScreenRuntime/first-presented.patch` as described in `Vendor/LockScreenRuntime/README.md`.
- MoltenVK: Apache-2.0, [`Vendor/LockScreenRuntime/LICENSE-MoltenVK`](Vendor/LockScreenRuntime/LICENSE-MoltenVK); upstream [KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK).
- Embedded runtime font notices remain with `Vendor/MirageBaseline/assets/fonts/`, including the Roboto Mono Apache notice, SIL Open Font License text, and Twemoji CC-BY-4.0 notice.

## Portable Homebrew runtime

The following shared libraries are copied byte-for-byte from the pinned lock and redistributed under their upstream terms. The manifest additionally includes brotli's `libbrotlicommon` provider because it is required by the retained `@rpath` edges; that supplemental entry is explicitly marked `lock_pinned: false` until the machine lock is expanded. The Homebrew formula recipe, sanitized install receipt, and package license text are retained under `Vendor/PortableRuntime/`. The formula page is the source URL for the package metadata; the upstream homepage and source archive URL are also retained in each copied formula recipe.

| Component | Version | Declared license | Source URLs | License text |
| --- | --- | --- | --- | --- |
| `brotli` | `1.2.0` | MIT | [https://github.com/google/brotli](https://github.com/google/brotli) / [https://formulae.brew.sh/formula/brotli](https://formulae.brew.sh/formula/brotli) | `licenses/brotli/LICENSE` |
| `dav1d` | `1.5.4` | BSD-2-Clause | [https://code.videolan.org/videolan/dav1d](https://code.videolan.org/videolan/dav1d) / [https://formulae.brew.sh/formula/dav1d](https://formulae.brew.sh/formula/dav1d) | `licenses/dav1d/COPYING` |
| `ffmpeg` | `9.0.1` | GPL-3.0-or-later | [https://ffmpeg.org/](https://ffmpeg.org/) / [https://formulae.brew.sh/formula/ffmpeg](https://formulae.brew.sh/formula/ffmpeg) | `licenses/ffmpeg/COPYING.GPLv2`, `licenses/ffmpeg/COPYING.GPLv3`, `licenses/ffmpeg/COPYING.LGPLv2.1`, `licenses/ffmpeg/COPYING.LGPLv3`, `licenses/ffmpeg/LICENSE.md` |
| `fontconfig` | `2.18.3` | See shipped license texts | [https://wiki.freedesktop.org/www/Software/fontconfig/](https://wiki.freedesktop.org/www/Software/fontconfig/) / [https://formulae.brew.sh/formula/fontconfig](https://formulae.brew.sh/formula/fontconfig) | `licenses/fontconfig/COPYING` |
| `freetype` | `2.14.3` | FTL | [https://www.freetype.org/](https://www.freetype.org/) / [https://formulae.brew.sh/formula/freetype](https://formulae.brew.sh/formula/freetype) | `licenses/freetype/LICENSE.TXT` |
| `gettext` | `1.0` | See shipped license texts | [https://www.gnu.org/software/gettext/](https://www.gnu.org/software/gettext/) / [https://formulae.brew.sh/formula/gettext](https://formulae.brew.sh/formula/gettext) | `licenses/gettext/COPYING` |
| `lame` | `4.0` | LGPL-2.0-or-later | [https://lame.sourceforge.io/](https://lame.sourceforge.io/) / [https://formulae.brew.sh/formula/lame](https://formulae.brew.sh/formula/lame) | `licenses/lame/COPYING`, `licenses/lame/LICENSE` |
| `libpng` | `1.6.58` | libpng-2.0 | [https://www.libpng.org/pub/png/libpng.html](https://www.libpng.org/pub/png/libpng.html) / [https://formulae.brew.sh/formula/libpng](https://formulae.brew.sh/formula/libpng) | `licenses/libpng/LICENSE` |
| `libvpx` | `1.16.0` | BSD-3-Clause | [https://www.webmproject.org/code/](https://www.webmproject.org/code/) / [https://formulae.brew.sh/formula/libvpx](https://formulae.brew.sh/formula/libvpx) | `licenses/libvpx/LICENSE` |
| `lz4` | `1.10.0` | BSD-2-Clause | [https://lz4.github.io/lz4/](https://lz4.github.io/lz4/) / [https://formulae.brew.sh/formula/lz4](https://formulae.brew.sh/formula/lz4) | `licenses/lz4/LICENSE` |
| `molten-vk` | `1.4.2` | Apache-2.0 | [https://github.com/KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) / [https://formulae.brew.sh/formula/molten-vk](https://formulae.brew.sh/formula/molten-vk) | `licenses/molten-vk/LICENSE` |
| `mpg123` | `1.33.7` | LGPL-2.1-only | [https://www.mpg123.de/](https://www.mpg123.de/) / [https://formulae.brew.sh/formula/mpg123](https://formulae.brew.sh/formula/mpg123) | `licenses/mpg123/COPYING` |
| `openssl@3` | `3.6.4` | Apache-2.0 | [https://openssl-library.org](https://openssl-library.org) / [https://formulae.brew.sh/formula/openssl@3](https://formulae.brew.sh/formula/openssl@3) | `licenses/openssl@3/LICENSE.txt` |
| `opus` | `1.6.1` | BSD-3-Clause | [https://www.opus-codec.org/](https://www.opus-codec.org/) / [https://formulae.brew.sh/formula/opus](https://formulae.brew.sh/formula/opus) | `licenses/opus/COPYING` |
| `svt-av1` | `4.2.0` | BSD-3-Clause | [https://gitlab.com/AOMediaCodec/SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1) / [https://formulae.brew.sh/formula/svt-av1](https://formulae.brew.sh/formula/svt-av1) | `licenses/svt-av1/LICENSE-BSD2.md`, `licenses/svt-av1/LICENSE.md` |
| `vulkan-loader` | `1.4.357.0` | Apache-2.0 | [https://github.com/KhronosGroup/Vulkan-Loader](https://github.com/KhronosGroup/Vulkan-Loader) / [https://formulae.brew.sh/formula/vulkan-loader](https://formulae.brew.sh/formula/vulkan-loader) | `licenses/vulkan-loader/LICENSE.txt` |
| `x264` | `r3222` | GPL-2.0-or-later | [https://www.videolan.org/developers/x264.html](https://www.videolan.org/developers/x264.html) / [https://formulae.brew.sh/formula/x264](https://formulae.brew.sh/formula/x264) | `licenses/x264/COPYING` |
| `x265` | `4.2` | GPL-2.0-or-later | [https://bitbucket.org/multicoreware/x265_git](https://bitbucket.org/multicoreware/x265_git) / [https://formulae.brew.sh/formula/x265](https://formulae.brew.sh/formula/x265) | `licenses/x265/COPYING` |
| `xz` | `5.8.3` | See shipped license texts | [https://tukaani.org/xz/](https://tukaani.org/xz/) / [https://formulae.brew.sh/formula/xz](https://formulae.brew.sh/formula/xz) | `licenses/xz/COPYING`, `licenses/xz/COPYING.0BSD`, `licenses/xz/COPYING.GPLv2`, `licenses/xz/COPYING.GPLv3`, `licenses/xz/COPYING.LGPLv2.1` |

The FFmpeg package is built under its GPL-enabled formula and ships the corresponding GPL/LGPL COPYING files. Consumers must follow the terms applicable to the selected FFmpeg components. The portable directory also retains the exact formula and install receipt used for this build.

## Sparkle updater

- Sparkle 2.10.0: MIT, source [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.0).
- The app ships its license at `Contents/Resources/ThirdParty/Sparkle/LICENSE`.
- SwiftPM pins the release and its binary artifact checksum. Update signing keys are generated independently and are not part of Sparkle or this repository.

## Steam service

- SteamKit2 3.4.0: LGPL-2.1, [`SteamKit2-NOTICE.txt`](SteamService/Licenses/SteamKit2-NOTICE.txt); source [SteamRE/SteamKit](https://github.com/SteamRE/SteamKit).
- protobuf-net: Apache-2.0, source [protobuf-net/protobuf-net](https://github.com/protobuf-net/protobuf-net).
- DepotDownloader notice and source reference: [`DepotDownloader-NOTICE.txt`](SteamService/Licenses/DepotDownloader-NOTICE.txt); source [SteamRE/DepotDownloader](https://github.com/SteamRE/DepotDownloader). SceneHarbor does not bundle or execute the DepotDownloader application.
- Full GPL-3.0 and LGPL-2.1 texts are in `SteamService/Licenses/` and are copied into the app package under `Contents/Resources/ThirdParty/`.

## DynamicWallpaper integration

- Source: [yuchn-w/DynamicWallpaper](https://github.com/yuchn-w/DynamicWallpaper).
- License text: [`Resources/ThirdParty/DynamicWallpaper-LICENSE.md`](Resources/ThirdParty/DynamicWallpaper-LICENSE.md).
- Imported file hashes and source head are recorded in `dynamicwallpaper-import-lock.json`.

## Corresponding source archives

- `Vendor/PortableRuntime/sources/manifest.json` records the upstream URL, formula hash (when supplied by Homebrew), bundled archive SHA-256, recipe revision, and license path for every portable runtime component. The source archive directory is about 147 MiB and is intended to ship as a separate GitHub release asset with the binary package; it is too large for a normal Git checkout.
- The GPL/LGPL runtime sources are present as verified archives: FFmpeg 9.0.1, x264 recipe revision `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`, x265 4.2, gettext 1.0, LAME 4.0, and mpg123 1.33.7. Their formula SHA-256 values and archive SHA-256 values are in the manifest.

| Source component | Version | Archive SHA-256 | Upstream source |
| --- | --- | --- | --- |
| `brotli` | `1.2.0` | `816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec` | [https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz](https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz) |
| `dav1d` | `1.5.4` | `2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011` | [https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2](https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2) |
| `ffmpeg` | `9.0.1` | `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635` | [https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz](https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz) |
| `fontconfig` | `2.18.3` | `9ae01e1d53acdef56010c5451cd34aa41d325b2faccd8606448d8fa01b2496b3` | [https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.18.3/fontconfig-2.18.3.tar.gz](https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.18.3/fontconfig-2.18.3.tar.gz) |
| `freetype` | `2.14.3` | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` | [https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz](https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz) |
| `gettext` | `1.0` | `85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a` | [https://ftpmirror.gnu.org/gnu/gettext/gettext-1.0.tar.gz](https://ftpmirror.gnu.org/gnu/gettext/gettext-1.0.tar.gz) |
| `lame` | `4.0` | `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb` | [https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz](https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz) |
| `libpng` | `1.6.58` | `28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775` | [https://downloads.sourceforge.net/project/libpng/libpng16/1.6.58/libpng-1.6.58.tar.xz](https://downloads.sourceforge.net/project/libpng/libpng16/1.6.58/libpng-1.6.58.tar.xz) |
| `libvpx` | `1.16.0` | `7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c` | [https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz](https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz) |
| `lz4` | `1.10.0` | `537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b` | [https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz](https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz) |
| `molten-vk` | `1.4.2` | `6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb` | [https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.2.tar.gz](https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.2.tar.gz) |
| `mpg123` | `1.33.7` | `31d0e35a4ca567ec9b5ebda6c3062bb4435d6d3eacd6ef0d95cadd7854dc03ee` | [https://www.mpg123.de/download/mpg123-1.33.7.tar.bz2](https://www.mpg123.de/download/mpg123-1.33.7.tar.bz2) |
| `openssl@3` | `3.6.4` | `9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef` | [https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz](https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz) |
| `opus` | `1.6.1` | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` | [https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz](https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz) |
| `svt-av1` | `4.2.0` | `512f2ea5649e3e76c2dddcc25c2556fb67a9582baaab207c9c96161c94659dad` | [https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.bz2](https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.bz2) |
| `vulkan-loader` | `1.4.357.0` | `54f2537df22313768da0317dda2abdaaab7711b4081c48c869a79db343d0ae70` | [https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/vulkan-sdk-1.4.357.0.tar.gz](https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/vulkan-sdk-1.4.357.0.tar.gz) |
| `x264` | `r3222` | `cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9` | [https://code.videolan.org/videolan/x264.git](https://code.videolan.org/videolan/x264.git) |
| `x265` | `4.2` | `40b1ea0453e0309f0eba934e0ddf533f8f6295966679e8894e8f1c1c8d5e1210` | [https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.2.tar.gz](https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.2.tar.gz) |
| `xz` | `5.8.3` | `3d3a1b973af218114f4f889bbaa2f4c037deaae0c8e815eec381c3d546b974a0` | [https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.gz](https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.gz) |
| `yt-dlp` | `2026.08.19` | `a0779c45179a846986a852bce31bddbe9259b594574f75c0ec146d0567058f7e` | [https://github.com/yt-dlp/yt-dlp/archive/refs/tags/2026.08.19.tar.gz](https://github.com/yt-dlp/yt-dlp/archive/refs/tags/2026.08.19.tar.gz) |

## yt-dlp

- Bundled binary: `Vendor/HDR/yt-dlp_macos`, version `2026.08.19`; SHA-256 is recorded in `hdr-runtime-lock.json` and `Vendor/PortableRuntime/sources/manifest.json`.
- Corresponding source: `Vendor/PortableRuntime/sources/yt-dlp-2026.08.19.tar.gz`, from [yt-dlp 2026.08.19](https://github.com/yt-dlp/yt-dlp/archive/refs/tags/2026.08.19.tar.gz), with archive SHA-256 recorded in the source manifest.
- License: Unlicense/public domain dedication, [`Vendor/PortableRuntime/licenses/yt-dlp-2026.08.19/LICENSE`](Vendor/PortableRuntime/licenses/yt-dlp-2026.08.19/LICENSE).


## Source downloads and app bundle locations

The matching runtime/source attachment is distributed with the [SceneHarbor public releases](https://github.com/yuchn-w/SceneHarbor/releases). `RUNTIME_SOURCES.md` describes the patches and reconstruction. In the installed app, this notice is at `Contents/Resources/ThirdParty/THIRD_PARTY_NOTICES.md`; the full Mirage GPL text is at `SceneHarborScreenSaver/LICENSE-Mirage` relative to that directory, and portable-library license texts are in `PortableRuntime-Licenses/`. Repository-relative links above refer to the source checkout.

Official upstream source archives retain their published test certificates, sample cookie fixtures, and service constants. They are not the SceneHarbor developer's credentials. Personal-key comparisons are performed separately and are never exempted by these upstream fixtures.

This software uses the FreeType font engine. FreeType license choices and contributor notices are preserved in `Vendor/PortableRuntime/licenses/freetype/`, including `docs-FTL.TXT` and `docs-GPLv2.TXT`.
