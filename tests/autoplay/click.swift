import CoreGraphics
import Foundation
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
  let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
  e.post(tap: .cghidEventTap); usleep(120000)
}
