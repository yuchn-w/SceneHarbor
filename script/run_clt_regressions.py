"""Run unchanged XCTest method bodies with a standalone assertion runner.

The installed CLT toolchain lacks XCTest. This fallback links the freshly
compiled testable app objects; it does not mark SwiftPM/XCTest as passing.
Only the import and base class are adapted in temporary source copies.
"""
import os
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
base = root / '.build/out/Intermediates.noindex/SceneHarbor.build/Debug'
object_dirs = list(base.glob('SceneHarbor--*-testable-t.build/Objects-normal/arm64'))
object_dirs += list(base.glob('SceneHarbor-p.build/Objects-normal/arm64'))
objects = sorted(object_dirs,
                 key=lambda p: (p / 'HarborPlayback.o').stat().st_mtime)[-1]
for source in (root / 'Sources/SceneHarbor').glob('*.swift'):
    obj = objects / (source.stem + '.o')
    if not obj.exists() or obj.stat().st_mtime < source.stat().st_mtime:
        raise RuntimeError('Build the current source before testing: ' + str(source))
module_map = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps/SceneHarborGlassBridge.modulemap'
bridge = base / 'SceneHarborGlassBridge-t.build/Objects-normal/arm64/DWGlassBridge.o'
sdk = os.environ.get('SDKROOT', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
cache = pathlib.Path('/private/tmp/sceneharbor-clt-regression-module-cache')
cache.mkdir(exist_ok=True)
only = os.environ.get('SCENEHARBOR_REGRESSION_FILTER', '')
test_files = sorted((root / 'Tests/SceneHarborTests').glob('*.swift'))
with tempfile.TemporaryDirectory(prefix='sceneharbor-regressions-', dir='/private/tmp') as temp:
    temp = pathlib.Path(temp)
    sources, calls = [], []
    for source in test_files:
        content = source.read_text()
        match = re.search(r'final class (\w+): XCTestCase', content)
        if not match:
            raise RuntimeError('Unsupported test class: ' + str(source))
        cls = match.group(1)
        content = re.sub(r'^import XCTest\n', '', content, flags=re.M)
        content = content.replace(': XCTestCase', ': HarborRegressionCase')
        target = temp / source.name
        target.write_text('import Foundation\n' + content)
        sources.append(str(target))
        for method in re.finditer(r'func (test\w+)\(\)\s*(async\s*)?(throws\s*)?\{', content):
            name = cls + '.' + method.group(1)
            if only and only not in name:
                continue
            invocation = ('try ' if method.group(3) else '') + ('await ' if method.group(2) else '')
            invocation += 'test.' + method.group(1) + '()'
            calls.append(f'''await run("{name}") {{
                let test = {cls}(); defer {{ test.finish() }}
                {invocation}
            }}''')
    if not calls:
        raise RuntimeError('No test methods selected')
    runner = temp / 'Runner.swift'
    runner.write_text('''import AppKit
@main enum CoreRegressionRunner {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        print("Standalone CLT regression runner; XCTest unavailable; original method bodies retained")
''' + '\n'.join(calls) + f'''
        print("RESULT: {len(calls)} methods, \\(RegressionResults.assertions) assertions, \\(RegressionResults.failures) failures, \\(RegressionResults.skipped) skipped")
        exit(RegressionResults.failures == 0 && RegressionResults.skipped == 0 ? 0 : 1)
    }}
    @MainActor static func run(_ name: String, body: () async throws -> Void) async {{
        let before = RegressionResults.failures
        print("RUN: \\(name)")
        do {{ try await body() }}
        catch let skipped as XCTSkip {{
            RegressionResults.skipped += 1
            print("SKIP: \\(name): \\(skipped.message)")
            return
        }}
        catch {{ XCTFail("\\(name) threw: \\(error)") }}
        print("\\(RegressionResults.failures == before ? "PASS" : "FAIL"): \\(name)")
    }}
}}
''')
    binary = temp / 'regressions'
    command = ['swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', sdk,
               '-module-cache-path', str(cache), '-I', str(objects),
               '-Xcc', '-fmodule-map-file=' + str(module_map),
               str(root / 'Tools/RegressionAssertions.swift'), str(runner)]
    command += sources
    command += [str(p) for p in sorted(objects.glob('*.o')) if p.name != 'SceneHarborApp.o']
    sparkle_frameworks = root / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
    if not (sparkle_frameworks / 'Sparkle.framework').is_dir():
        raise RuntimeError('Resolve the pinned Sparkle artifact before testing')
    command += ['-F', str(sparkle_frameworks), '-framework', 'Sparkle',
                '-Xlinker', '-rpath', '-Xlinker', str(sparkle_frameworks)]
    command += [str(bridge), '-o', str(binary)]
    compile_result = subprocess.run(command, cwd=root)
    if compile_result.returncode:
        raise SystemExit(compile_result.returncode)
    result = subprocess.run([str(binary)], cwd=root)
    raise SystemExit(result.returncode)
