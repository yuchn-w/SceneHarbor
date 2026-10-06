import AppKit
import QuartzCore
import Metal
import Darwin

// Integration fixture: actual native renderers, mixed aspect ratios, and the
// detached NSViews used by WallpaperAgent. No wallpaper preferences are touched.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments
setenv("VK_DRIVER_FILES", "/Applications/SceneHarbor.app/Contents/Extensions/SceneHarborWallpaperExtension.appex/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json", 1)
setenv("VK_ICD_FILENAMES", "/Applications/SceneHarbor.app/Contents/Extensions/SceneHarborWallpaperExtension.appex/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json", 1)
setenv("RUST_LOG", "info", 1)
setbuf(stdout, nil)
let library = dlopen(args[1], RTLD_NOW | RTLD_LOCAL)!
typealias Create = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
typealias Pause = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias Ready = @convention(c) (UnsafeMutableRawPointer?) -> Int32
let create = unsafeBitCast(dlsym(library,"MirageSceneSaverCreate")!, to: Create.self)
let pause = unsafeBitCast(dlsym(library,"MirageSceneSaverSetPaused")!, to: Pause.self)
let destroy = unsafeBitCast(dlsym(library,"MirageSceneSaverDestroy")!, to: Destroy.self)
let ready = unsafeBitCast(dlsym(library,"MirageSceneSaverHasPresented")!, to: Ready.self)
let screen = NSScreen.screens.first { screen in
    CGDisplayIsBuiltin((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value) != 0
}!
let window = NSWindow(contentRect: NSRect(x:screen.visibleFrame.minX+30,y:screen.visibleFrame.minY+40,width:1000,height:450),styleMask:[.titled],backing:.buffered,defer:false)
window.title = "SceneHarbor 鎖定比例驗證"
window.contentView!.wantsLayer = true
window.orderFrontRegardless()
var views:[NSView] = []
var handles:[UnsafeMutableRawPointer] = []
var done = false
var failed = false
let extents:[(UInt32,UInt32)] = [(1280,832),(1920,1080)]
DispatchQueue.global().async {
    for (index, extent) in extents.enumerated() {
        var view:NSView!
        DispatchQueue.main.sync {
            view = NSView(frame:NSRect(x:0,y:0,width:CGFloat(extent.0)/2,height:CGFloat(extent.1)/2))
            view.wantsLayer = true
            views.append(view)
        }
        let handle = args[2].withCString { assets in args[3].withCString { scene in
            "{}".withCString { props in create(Unmanaged.passUnretained(view).toOpaque(),assets,scene,props,extent.0,extent.1,extent.0,extent.1,30) }
        }}
        guard let handle else { failed=true; break }
        handles.append(handle)
        DispatchQueue.main.sync {
            let host = CALayer()
            host.frame = CGRect(x:CGFloat(index)*500,y:0,width:500,height:450)
            host.masksToBounds = true
            window.contentView!.layer!.addSublayer(host)
            host.addSublayer(view.layer!)
            view.layer!.opacity = 0 // Match the extension while it waits for the first frame.
            view.layer!.setAffineTransform(CGAffineTransform(scaleX:0.5,y:0.5))
            view.layer!.anchorPoint = .zero
            view.layer!.position = CGPoint(x:0,y:0)
        }
        pause(handle,1)
    }
    for handle in handles { pause(handle,0) }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline && !handles.allSatisfy({ready($0) != 0}) { Thread.sleep(forTimeInterval:0.1) }
    if handles.count != 2 || !handles.allSatisfy({ready($0) != 0}) { failed=true }
    DispatchQueue.main.sync {
        for (i,view) in views.enumerated() {
            let metal = view.layer as! CAMetalLayer
            print("host \(i): bounds=\(view.bounds.size) drawable=\(metal.drawableSize) firstFrame=\(i < handles.count ? ready(handles[i]) : 0)")
            if abs(view.bounds.width-CGFloat(extents[i].0)/2)>0.1 || abs(view.bounds.height-CGFloat(extents[i].1)/2)>0.1 { failed=true }
        }
    }
    // Tear down one display while the other keeps running; then resume it.
    if handles.count == 2 {
        destroy(handles.removeFirst())
        pause(handles[0],1)
        Thread.sleep(forTimeInterval:0.2)
        pause(handles[0],0)
        Thread.sleep(forTimeInterval:0.5)
    }
    for h in handles { destroy(h) }
    handles.removeAll()
    // Recreate after the previous scene completely stopped, as on a playlist
    // change or a video-to-scene switch in an already-connected extension.
    let replacement = args[2].withCString { assets in args[3].withCString { scene in
        "{}".withCString { props in create(Unmanaged.passUnretained(views[0]).toOpaque(),assets,scene,props,1280,832,1280,832,30) }
    }}
    if let replacement {
        DispatchQueue.main.sync {
            window.contentView!.layer!.addSublayer(views[0].layer!)
            views[0].layer!.opacity = 0
        }
        pause(replacement, 1)
        Thread.sleep(forTimeInterval:0.1)
        pause(replacement, 0)
        let replacementDeadline = Date().addingTimeInterval(20)
        while Date() < replacementDeadline && ready(replacement) == 0 { Thread.sleep(forTimeInterval:0.1) }
        if ready(replacement) == 0 { failed = true }
        print("replacement firstFrame=\(ready(replacement))")
        destroy(replacement)
    } else { failed = true }
    DispatchQueue.main.async { window.close(); done=true }
}
while !done { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
print(failed ? "FAIL: native mixed-display framing/readiness" : "PASS: native mixed-display framing, first frames, independent pause and teardown")
exit(failed ? 1:0)
