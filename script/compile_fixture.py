#!/usr/bin/env python3
"""Link a native verification fixture against the current testable app objects."""
import pathlib, subprocess, os, sys
root=pathlib.Path(__file__).resolve().parents[1]
base=root/'.build/out/Intermediates.noindex/SceneHarbor.build/Debug'
objects=next(base.glob('SceneHarbor-*-testable-t.build/Objects-normal/arm64'))
sdkroot=os.environ.get('SDKROOT') or '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
cache_root=pathlib.Path(os.environ.get('SCENE_HARBOR_CACHE_ROOT') or '/private/tmp/scene-harbor-test-cache')
clang_cache=pathlib.Path(os.environ.get('CLANG_MODULE_CACHE_PATH') or cache_root/'clang')
swift_cache=pathlib.Path(os.environ.get('SWIFT_MODULE_CACHE_PATH') or cache_root/'swift')
clang_cache.mkdir(parents=True, exist_ok=True)
swift_cache.mkdir(parents=True, exist_ok=True)
args=['swiftc','-parse-as-library','-swift-version','5','-sdk',sdkroot,'-module-cache-path',str(swift_cache),'-I',str(objects),'-Xcc','-fmodule-map-file='+str(base/'SceneHarborGlassBridge-t.build/SceneHarborGlassBridge.modulemap'),str(root/sys.argv[1])]
args += [str(f) for f in objects.glob('*.o')]
args += [str(base/'SceneHarborGlassBridge-t.build/Objects-normal/arm64/DWGlassBridge.o'),'-o',str(root/sys.argv[2])]
subprocess.run(args,check=True,env=dict(os.environ,SDKROOT=sdkroot,CLANG_MODULE_CACHE_PATH=str(clang_cache),SWIFT_MODULE_CACHE_PATH=str(swift_cache)))
