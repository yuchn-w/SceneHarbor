#!/usr/bin/env python3
"""Run the XCTest interaction bodies on Command Line Tools hosts without XCTest."""
import pathlib, subprocess, os
root=pathlib.Path(__file__).resolve().parents[1]
os.chdir(root)
sdkroot=os.environ.get('SDKROOT') or '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
cache_root=pathlib.Path(os.environ.get('SCENE_HARBOR_CACHE_ROOT') or '/private/tmp/scene-harbor-test-cache')
clang_cache=pathlib.Path(os.environ.get('CLANG_MODULE_CACHE_PATH') or cache_root/'clang')
swift_cache=pathlib.Path(os.environ.get('SWIFT_MODULE_CACHE_PATH') or cache_root/'swift')
swiftpm_cache=pathlib.Path(os.environ.get('SWIFTPM_MODULECACHE_OVERRIDE') or cache_root/'swiftpm')
clang_cache.mkdir(parents=True, exist_ok=True)
swift_cache.mkdir(parents=True, exist_ok=True)
swiftpm_cache.mkdir(parents=True, exist_ok=True)
env=dict(os.environ,SDKROOT=sdkroot,CLANG_MODULE_CACHE_PATH=str(clang_cache),SWIFT_MODULE_CACHE_PATH=str(swift_cache),SWIFTPM_MODULECACHE_OVERRIDE=str(swiftpm_cache))
log=root/'work/interaction-build.log'
with log.open('w') as out: result=subprocess.run(['swift','test','--disable-sandbox','--filter','PlaybackInteractionTests'],stdout=out,stderr=subprocess.STDOUT,env=env)
text=log.read_text()
errors=[line for line in text.splitlines() if 'error:' in line]
if result.returncode and not any("unable to resolve module dependency: 'XCTest'" in line for line in errors):
    print('\n'.join(errors));raise SystemExit(result.returncode)
source=(root/'Tests/SceneHarborTests/PlaybackInteractionTests.swift').read_text().replace('import XCTest\n','').replace(': XCTestCase {',' {')
assertions=(root/'Tools/InteractionAssertions.swift').read_text()
assertions+='func XCTAssertEqual<T: BinaryFloatingPoint>(_ a: T, _ b: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line) { precondition(abs(a-b) <= accuracy, "values differ", file: file, line: line) }\n'
main=(root/'Tools/InteractionMain.swift').read_text()
main=main.replace('  try await tests.testActualVideoHoverIsMutedAdvancesAndReleasesPlayer()', '  tests.testVisualSettingsNeverPulseThePlayingVolume()\n  print("PASS: real AVPlayer volume updates never pulse zero; visual changes preserve effective volume")\n  try await tests.testPosterCachePreservesFullVideoAndIgnoresDesktopCropAndVolume()\n  print("PASS: full-frame video poster and memory reuse across crop/audio changes")\n  try await tests.testActualVideoHoverIsMutedAdvancesAndReleasesPlayer()')
runner=root/'work/AudioPreviewInteractionRunner.swift';runner.write_text(assertions+'import Combine\nimport CryptoKit\n'+source+'\n'+main)
base=root/'.build/out/Intermediates.noindex/SceneHarbor.build/Debug'
objects=next(base.glob('SceneHarbor-*-testable-t.build/Objects-normal/arm64'))
args=['swiftc','-parse-as-library','-swift-version','5','-sdk',sdkroot,'-module-cache-path',str(swift_cache),'-I',str(objects),'-Xcc','-fmodule-map-file='+str(base/'SceneHarborGlassBridge-t.build/SceneHarborGlassBridge.modulemap'),str(runner)]
args += [str(f) for f in objects.glob('*.o')]
args += [str(base/'SceneHarborGlassBridge-t.build/Objects-normal/arm64/DWGlassBridge.o'),'-o',str(root/'work/verify-audio-preview-interaction')]
subprocess.run(args,check=True,env=env)
print('Built standalone runner from the current XCTest bodies (this host has no XCTest).')
