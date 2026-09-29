import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in l {
  let o = w[kCGWindowOwnerName as String] as? String ?? ""
  if o.lowercased().contains("fifa") || o.lowercased().contains("wine") || o.lowercased().contains("crossover") {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? "", o, w[kCGWindowOwnerPID as String] ?? "", w[kCGWindowName as String] ?? "", w[kCGWindowIsOnscreen as String] ?? "", b["Width"] ?? "", b["Height"] ?? "", w[kCGWindowLayer as String] ?? "")
  }
}
