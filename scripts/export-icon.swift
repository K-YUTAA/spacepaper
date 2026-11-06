import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Export the generated artwork into a precise macOS icon container. Keeping the
// source separate makes both the artwork and the platform mask reproducible.
guard CommandLine.arguments.count == 3 else { fatalError("Usage: export-icon.swift INPUT.png OUTPUT.png") }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height, image.width >= 1024 else { fatalError("A square source of at least 1024px is required") }
guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create the icon context") }
context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 184, cornerHeight: 184, transform: nil))
context.clip()
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot export the icon")
}
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finalize the icon") }
