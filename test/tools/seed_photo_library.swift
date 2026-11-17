// Host-only fixture generator. Never bundled with the app.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
precondition(args.count == 2, "Usage: swift test/tools/seed_photo_library.swift /empty/output/directory")
let output = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let existing = try FileManager.default.contentsOfDirectory(atPath: output.path)
precondition(existing.isEmpty, "Use an empty fixture directory")
let cases: [(String, String, String)] = [
    ("native-start", "cover", "2018:06:18 12:00:00"),
    ("native-before-start", "cake", "2018:06:17 12:00:00"),
    ("native-anniversary", "coffee", "2019:06:18 12:00:00"),
    ("native-before", "cover", "2019:06:17 12:00:00"),
    ("native-after", "cake", "2019:06:19 12:00:00"),
    ("native-outside", "coffee", "2019:06:20 12:00:00"),
]
for (name, fixture, date) in cases {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("test/fixtures/\(fixture).png")
    let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let target = output.appendingPathComponent("\(name).jpg")
    let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: date,
            kCGImagePropertyExifDateTimeDigitized: date,
        ],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: date],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "Could not write fixture")
    print("\(target.path) | \(date)")
}
