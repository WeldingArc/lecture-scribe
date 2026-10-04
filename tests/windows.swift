import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "받아쓰기") {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("WINDOW owner=\(w[kCGWindowOwnerName as String] ?? "") pid=\(w[kCGWindowOwnerPID as String] ?? "") layer=\(w[kCGWindowLayer as String] ?? "") onscreen=\(w[kCGWindowIsOnscreen as String] ?? "") bounds=\(b)")
}
