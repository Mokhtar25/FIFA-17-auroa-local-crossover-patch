import Foundation
import CoreGraphics
// key <keycode> [hold-seconds]  -- press and hold one key (games that poll the keyboard miss a tap)
let a = CommandLine.arguments
guard a.count >= 2, let code = UInt16(a[1]) else { print("usage: key <keycode> [hold-seconds]"); exit(2) }
let hold = a.count > 2 ? Double(a[2]) ?? 0.3 : 0.3
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: hold)
CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
