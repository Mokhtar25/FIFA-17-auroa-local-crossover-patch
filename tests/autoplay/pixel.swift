// usage: pixel <png> <x-in-points> <y-in-points> <screen-width-in-points>  -> prints "r g b"
import CoreGraphics
import ImageIO
import Foundation
let a = CommandLine.arguments
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("0 0 0"); exit(1) }
let s = Double(img.width) / Double(a[4])!
let x = Int(Double(a[2])! * s), y = Int(Double(a[3])! * s)
guard let c = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { print("0 0 0"); exit(1) }
var px = [UInt8](repeating: 0, count: 4)
let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(c, in: CGRect(x: 0, y: 0, width: 1, height: 1))
print(px[0], px[1], px[2])
