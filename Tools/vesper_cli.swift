// vesper: a macOS command line harness for the Vesper 800 engine.
//
// Build it against the engine file so there is exactly one copy of the host
// code and the shader:
//
//   swiftc -O Tools/vesper_cli.swift MarennFilter.swift -o vesper
//   ./vesper in.jpg out.png [--stock vesper800|marenn400] [--seed N] [--nograin]
//            [--date "'98 8 24"|auto|none] [--leak 0.35] [--flash 0|1] [--stats]
//
// EXIF orientation is applied on load, so phone photos come out upright.

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct VesperCLI {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func captureDate(_ source: CGImageSource) -> Date? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        // EXIF dates look like 1998:08:24 17:05:00
        let datePart = raw.split(separator: " ").first.map(String.init) ?? raw
        let parts = datePart.split(separator: ":")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        var options = VesperOptions()
        var dateOption = "none"
        var wantStats = false
        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            let next: String = (i + 1 < args.count) ? args[i + 1] : ""
            switch a {
            case "--seed":
                options.seed = Float(next)
                i += 1
            case "--nograin":
                options.grain = false
            case "--stock":
                options.stock = FilmStock(rawValue: next)
                if options.stock == nil { fail("unknown stock \(next); use vesper800 or marenn400") }
                i += 1
            case "--date":
                dateOption = next
                i += 1
            case "--leak":
                options.lightLeak = Float(next) ?? 0
                i += 1
            case "--flash":
                options.flash = next != "0"
                i += 1
            case "--stats":
                wantStats = true
            default:
                positional.append(a)
            }
            i += 1
        }
        guard positional.count == 2 else {
            fail("usage: vesper <in> <out.png|jpg> [--stock vesper800|marenn400] [--seed N] [--nograin] [--date TEXT|auto|none] [--leak X] [--flash 0|1] [--stats]")
        }
        let inPath = positional[0], outPath = positional[1]

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
              let probe = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot load \(inPath)") }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(probe.width, probe.height)
        ]
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) ?? probe

        if dateOption == "auto" {
            options.dateStamp = VesperOptions.dateStamp(for: captureDate(source) ?? Date())
        } else if dateOption != "none" && !dateOption.isEmpty {
            options.dateStamp = dateOption
        }

        guard let engine = VesperEngine.shared else { fail("no Metal device") }
        guard let out = engine.process(cg, options: options) else { fail("render failed") }

        let url = URL(fileURLWithPath: outPath) as CFURL
        let lower = outPath.lowercased()
        let type = (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")) ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url, type, 1, nil) else { fail("cannot write \(outPath)") }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { fail("cannot write \(outPath)") }

        let r = engine.lastReport
        if wantStats {
            if r.stock == .vesper800 {
                print(String(format: "stock=vesper800 %dx%d p50=%.3f p90=%.3f dark=%.3f bright=%.3f gain=%.3f wb=%.3f,%.3f flash=%.2f night=%.2f highkey=%.2f seed=%.2f",
                             out.width, out.height, r.p50, r.p90, r.darkFrac, r.brightFrac, r.gain, r.wbR, r.wbB, r.flash, r.night, r.highKey, r.seed))
            } else {
                print(String(format: "stock=marenn400 %dx%d gain=%.3f p50=%.3f", out.width, out.height, r.gain, r.p50))
            }
        }
        print("\(inPath) -> \(outPath)  \(out.width)x\(out.height)  \(r.stock.rawValue)  gain=\(String(format: "%.3f", r.gain))")
    }
}
