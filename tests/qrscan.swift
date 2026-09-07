// Reads a QR code the way a phone's camera reads one.
//
// The encoder in backend-java/src/Qr.java is a specification full of tables,
// and a test that checked its output against what it produces would pass for
// as long as it was consistently wrong. So the grid it produced is turned into
// an image here and handed to Vision - the same framework behind the camera -
// and what comes back has to be the text that went in.
//
//     qrscan <grid file>   (a file of 0s and 1s, one row per line)
//
// It prints what it decoded, or nothing at all.

import Foundation
import CoreImage
import Vision

let arguments = CommandLine.arguments
guard arguments.count >= 2,
      let rows = try? String(contentsOfFile: arguments[1], encoding: .utf8)
        .split(separator: "\n").map(Array.init) else {
    FileHandle.standardError.write("qrscan: give it a grid file\n".data(using: .utf8)!)
    exit(2)
}

let modules = rows.count
// Eight pixels a module and a quiet zone of four: a scanner needs the blank
// border as much as it needs the squares, and one pixel a module is a picture
// nothing can read.
let scale = 8
let quiet = 4
let side = (modules + quiet * 2) * scale

var pixels = [UInt8](repeating: 255, count: side * side)
for (y, row) in rows.enumerated() {
    for (x, cell) in row.enumerated() where cell == "1" {
        for dy in 0..<scale {
            for dx in 0..<scale {
                let py = (y + quiet) * scale + dy
                let px = (x + quiet) * scale + dx
                pixels[py * side + px] = 0
            }
        }
    }
}

guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                          decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
    FileHandle.standardError.write("qrscan: could not build an image\n".data(using: .utf8)!)
    exit(2)
}

let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
let handler = VNImageRequestHandler(cgImage: image, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write("qrscan: \(error)\n".data(using: .utf8)!)
    exit(2)
}

for case let observation as VNBarcodeObservation in request.results ?? [] {
    if let payload = observation.payloadStringValue {
        print(payload)
        exit(0)
    }
}
exit(1)
