// Marenn 400 on the command line (macOS).
//
// Builds together with the filter itself, so it runs exactly the engine the app ships:
//
//   swiftc -O -parse-as-library MarennFilter.swift Tools/marenn_cli.swift -o marenn
//   ./marenn beach.jpg out.png
//
// Options:
//   --seed N            fix the grain field and frame character (default: 3)
//   --random            roll a fresh frame every run instead
//   --nograin           develop without grain
//   --stamp [DATE]      burn in a date imprint; DATE is YYYY-MM-DD, default today
//   --leak X            light leak strength, 0...1
//   --variation X       frame to frame drift, 0...1 (default 1)
//   --set field=value   override any MarennParams field, e.g. --set grainAmount=0.03

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct MarennCLI {
    static func die(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static let fields: [String: WritableKeyPath<MarennParams, Float>] = [
        "distortion": \.distortion, "vigAmount": \.vigAmount, "vigTanHalfFov": \.vigTanHalfFov,
        "vigMech": \.vigMech, "softGlobal": \.softGlobal, "onset": \.onset, "defocusK": \.defocusK,
        "defocusP": \.defocusP, "aniso": \.aniso, "coma": \.coma, "axialR": \.axialR, "axialB": \.axialB,
        "caOnset": \.caOnset, "caK": \.caK, "caB": \.caB, "caP": \.caP, "hiBoost": \.hiBoost,
        "exposure": \.exposure, "halThreshold": \.halThreshold, "halKnee": \.halKnee,
        "halIntensity": \.halIntensity, "halR": \.halR, "halG": \.halG, "halB": \.halB,
        "veilAmount": \.veilAmount, "bloomI": \.bloomI, "warmGlow": \.warmGlow, "softAmt": \.softAmt, "hiE0": \.hiE0, "hiE1": \.hiE1,
        "grainAmount": \.grainAmount, "grainSigma": \.grainSigma, "mottleMix": \.mottleMix,
        "grainChroma": \.grainChroma, "grainR": \.grainR, "grainG": \.grainG, "grainB": \.grainB,
        "satGlobal": \.satGlobal, "blueSatK": \.blueSatK, "blueSatT0": \.blueSatT0,
        "blueSatT1": \.blueSatT1, "blueDark": \.blueDark, "blueHue": \.blueHue,
        "stampSize": \.stampSize, "dither": \.dither,
    ]

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            die("usage: marenn <in> <out.png|out.jpg> [--seed N] [--random] [--nograin] [--stamp [YYYY-MM-DD]] "
                + "[--leak X] [--variation X] [--set field=value]")
        }
        let inPath = args.removeFirst(), outPath = args.removeFirst()

        var options = MarennOptions(seed: 3)
        var params = MarennParams()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { die("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--seed": options.seed = UInt32(value()) ?? 3
            case "--random": options.seed = nil
            case "--nograin": options.grain = false
            case "--leak": options.lightLeak = Float(value()) ?? 0
            case "--variation": options.frameVariation = Float(value()) ?? 1
            case "--stamp":
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    guard let d = f.date(from: value()) else { die("--stamp wants YYYY-MM-DD") }
                    options.dateStamp = d
                } else {
                    options.dateStamp = Date()
                }
            case "--set":
                let kv = value().split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, let key = fields[kv[0]], let v = Float(kv[1]) else {
                    die("--set wants field=value, fields: \(fields.keys.sorted().joined(separator: ", "))")
                }
                params[keyPath: key] = v
            default:
                die("unknown option \(args[i])")
            }
            i += 1
        }

        guard let engine = MarennEngine.shared else { die("no Metal device") }
        engine.paramsOverride = params

        // decode with the EXIF orientation applied, as Photos would show it
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int else { die("cannot read \(inPath)") }
        let decode: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, decode as CFDictionary) else {
            die("cannot decode \(inPath)")
        }

        let start = Date()
        guard let out = engine.process(cg, options: options) else { die("processing failed") }
        let ms = Date().timeIntervalSince(start) * 1000

        let url = URL(fileURLWithPath: outPath) as CFURL
        let lower = outPath.lowercased()
        let type = (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url, type, 1, nil) else { die("cannot write \(outPath)") }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { die("cannot write \(outPath)") }

        let p = engine.lastParams
        let gain = p.map { String(format: "%.3f", $0.gainG) } ?? "?"
        print("\(inPath) -> \(outPath)  \(cg.width)x\(cg.height)  linear gain=\(gain)  \(String(format: "%.0f", ms)) ms")
    }
}
