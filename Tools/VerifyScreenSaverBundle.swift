import AppKit
import Darwin
import Foundation
import ScreenSaver

/// Loads a completed saver bundle in a separate process without installing it,
/// changing the user's saver preference, or writing SceneHarbor configuration.
/// The optional scene path is only checked for safe readability; a real
/// ScreenSaver host is still required to prove a Metal frame on screen.
@main
enum VerifyScreenSaverBundle {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            throw Failure("usage: VerifyScreenSaverBundle <SceneHarborScreenSaver.saver> [scene.pkg]")
        }
        let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw Failure("saver bundle does not exist: \(bundleURL.path)")
        }
        guard let bundle = Bundle(url: bundleURL), bundle.load() else {
            throw Failure("Bundle.load() failed: \(bundleURL.path)")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "BNDL",
              bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String
                == "SceneHarborScreenSaverView" else {
            throw Failure("saver Info.plist has an unexpected package type or principal class")
        }
        guard let viewType = NSClassFromString("SceneHarborScreenSaverView") as? ScreenSaverView.Type,
              let view = viewType.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360), isPreview: true) else {
            throw Failure("NSPrincipalClass did not load as ScreenSaverView")
        }

        guard let frameworks = bundle.privateFrameworksURL else {
            throw Failure("Contents/Frameworks is missing")
        }
        let runtimeURL = frameworks.appendingPathComponent("libMirageSceneSaver.dylib")
        guard let runtime = dlopen(runtimeURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw Failure("bundled saver runtime could not dlopen: \(runtimeURL.path)")
        }
        defer { dlclose(runtime) }
        for symbol in [
            "MirageSceneSaverCreate",
            "MirageSceneSaverSetPaused",
            "MirageSceneSaverDestroy",
            "MirageSceneSaverHasPresented"
        ] {
            guard dlsym(runtime, symbol) != nil else {
                throw Failure("bundled runtime is missing C ABI symbol: \(symbol)")
            }
        }

        // Exercise the public ScreenSaver lifecycle only. The view has no
        // host window in this probe, so it must not be presented as a render
        // or lock-screen test.
        view.startAnimation()
        view.stopAnimation()

        if CommandLine.arguments.count >= 3 {
            let sceneURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            guard fileManager.isReadableFile(atPath: sceneURL.path),
                  (try? sceneURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw Failure("optional scene fixture is unreadable or symlinked: \(sceneURL.path)")
            }
            print("NOT RUN: scene fixture was read-only checked; native ScreenSaver host rendering was not invoked")
        }

        print("PASS: loaded saver Bundle/principal class and dlopen'd all pinned SceneSaver C ABI symbols without installation or user configuration writes")
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
