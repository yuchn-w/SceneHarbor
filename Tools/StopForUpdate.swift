import AppKit

// Respect application termination handlers and any unsaved-work prompt.
// An update aborts if the app declines to quit; never force-kill it.
// Include the installed identity during a one-time development-to-public migration.
// Resolve from the actual bundles instead of embedding a developer's namespace.
let candidatePath = CommandLine.arguments.dropFirst().first
let identifiers = Set((["/Applications/SceneHarbor.app"] + [candidatePath].compactMap { $0 })
    .compactMap { Bundle(path: $0)?.bundleIdentifier })
guard !identifiers.isEmpty else {
    fputs("找不到要更新的 SceneHarbor 識別名稱，已停止安裝。\n", stderr)
    exit(2)
}
let apps = identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }

for app in apps where !app.isTerminated {
    guard app.terminate() else {
        fputs("SceneHarbor 未接受結束要求，已保留目前執行中的版本。\n", stderr)
        exit(2)
    }
}
let deadline = Date().addingTimeInterval(10)
while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy(\.isTerminated) else {
    fputs("SceneHarbor 尚未結束，更新已停止。請先完成 App 中的操作。\n", stderr)
    exit(2)
}
