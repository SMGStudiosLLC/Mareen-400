// Vesper 800, the film look from Relay. Successor to Marenn 400.
//
// This file keeps its historical name so projects that reference it by path
// keep building. The Marenn 400 kernels and host path are preserved verbatim
// further down and stay selectable through FilmStock.marenn400, so the old
// look is one option away, not one git revert away.
//
// Modified 2026-09-07: the look was rebuilt as Vesper 800 (linear light
// halation and optics, a perceptual color stage, film grain, scene adaptive
// development, optional databack stamp). See CHANGELOG.md for the details.
// Copyright (C) Tobias Schmidt Services LLC. GPL-3.0, see LICENSE.

import Foundation
import Metal
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public surface

enum FilmStock: String {
    case vesper800
    case marenn400
}

/// Everything a caller can ask for. The defaults give the fixed Vesper look.
struct VesperOptions {
    /// nil uses the engine's defaultStock (Vesper 800 unless it failed to compile).
    var stock: FilmStock? = nil
    /// Grain and roll seed. nil derives a stable seed from the photo itself, so a
    /// preview and an export of the same photo look identical.
    var seed: Float? = nil
    var grain: Bool = true
    /// Databack stamp text such as "'98 8 24". Digits, apostrophe, space and dash.
    var dateStamp: String? = nil
    /// Warm light leak strength, 0 to 1. Off by default.
    var lightLeak: Float = 0
    /// nil lets the engine infer flash from the histogram.
    var flash: Bool? = nil

    init() {}

    /// Formats a date the way a 1990s quartz databack did: '98 8 24.
    static func dateStamp(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "'%02d %d %d", (parts.year ?? 2000) % 100, parts.month ?? 1, parts.day ?? 1)
    }
}

/// What the engine measured and decided for the last photo it developed.
struct VesperReport {
    var stock: FilmStock = .vesper800
    var p50: Float = 0
    var p90: Float = 0
    var darkFrac: Float = 0
    var brightFrac: Float = 0
    var gain: Float = 1
    var wbR: Float = 1
    var wbB: Float = 1
    var flash: Float = 0
    var night: Float = 0
    var highKey: Float = 0
    var seed: Float = 0
}

#if canImport(UIKit)
enum VesperFilter {
    static let name = "Vesper 800"
    static let formerNames = ["Marenn 400", "Marenn XL", "gas filter"]

    static func apply(to image: UIImage) -> UIImage? {
        apply(to: image, options: VesperOptions())
    }

    static func apply(to image: UIImage, options: VesperOptions) -> UIImage? {
        autoreleasepool {
            guard let cg = flatten(image),
                  let out = VesperEngine.shared?.process(cg, options: options) else { return nil }
            return UIImage(cgImage: out, scale: image.scale, orientation: .up)
        }
    }

    private static func flatten(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let px = CGSize(width: (image.size.width * image.scale).rounded(),
                        height: (image.size.height * image.scale).rounded())
        guard px.width >= 1, px.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: px, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: px))
        }.cgImage
    }
}

/// Kept for callers written against Marenn 400. Same call, current look.
enum MarennFilter {
    static var name: String { VesperFilter.name }
    static var formerNames: [String] { VesperFilter.formerNames }

    static func apply(to image: UIImage) -> UIImage? {
        VesperFilter.apply(to: image)
    }
}
#endif

typealias MarennEngine = VesperEngine

// MARK: - Marenn 400 parameters (unchanged)

struct GradeP {
    var gain: Float = 1
    var satGlobal: Float = 1.17000
    var blueSatK: Float = 1.45000
    var blueSatT0: Float = 0.3800
    var blueSatT1: Float = 0.6141
    var blueDark: Float = 0.33000
    var blueHue: Float = -0.15000
    var pad0: Float = 0
    var pad1: Float = 0
}

struct ClarityP {
    var radiusPx: Float = 4.0
    var softAmt: Float = 0.60000
    var hiE0: Float = 0.42
    var hiE1: Float = 0.78
    var bloomI: Float = 0.10000
    var pad0: Float = 0
}

struct BrightP {
    var threshold: Float = 0.62
    var glowR: Float = 1.0, glowG: Float = 0.60, glowB: Float = 0.32
}

struct CompP {
    var halIntensity: Float = 0.18000
    var vigAmount: Float = 0.20000
    var vigRadius: Float = 0.20000
    var vigFeather: Float = 1.20000
    var onset: Float = 0.25000
    var defocusK: Float = 0.00050
    var defocusP: Float = 1.80000
    var softGlobal: Float = 0.00055
    var aniso: Float = 3.20000
    var caOnset: Float = 0.4500
    var caK: Float = 0.00090
    var caB: Float = 0.00090
    var caP: Float = 1.0000
    var grainAmount: Float = 0.02600
    var grainSize: Float = 1.6
    var grainDiv: Float = 900.0
    var seed: Float = 0
}

struct SceneStats {
    var p50: Float
    var meanLuma: Float
    var hiFrac: Float
}

// MARK: - Vesper 800 parameters
//
// Every struct is all-Float and mirrors its Metal twin field for field. The
// values here are the shipped look. Radii are fractions of the short side so
// the look holds from a thumbnail to a 48MP capture.

/// Exposure in linear light plus the optional light leak.
struct ExposeP {
    var gainR: Float = 1
    var gainG: Float = 1
    var gainB: Float = 1
    var clampMax: Float = 8
    var leakAmount: Float = 0
    var leakEdge: Float = 0
    var leakSeed: Float = 0
    var leakWidth: Float = 0.45
    var leakR: Float = 1.0
    var leakG: Float = 0.42
    var leakB: Float = 0.10
    var pad0: Float = 0
}

/// Seven segment databack stamp, exposed onto the film as light.
struct StampP {
    var enabled: Float = 0
    var count: Float = 0
    var marginX: Float = 0.045
    var marginY: Float = 0.050
    var height: Float = 0.036
    var skew: Float = 0.12
    var intensity: Float = 2.2
    var glow: Float = 0.08
    var r: Float = 1.0
    var g: Float = 0.36
    var b: Float = 0.08
    var minDim: Float = 200
    var c0: Float = 11
    var c1: Float = 11
    var c2: Float = 11
    var c3: Float = 11
    var c4: Float = 11
    var c5: Float = 11
    var c6: Float = 11
    var c7: Float = 11
    var c8: Float = 11
    var c9: Float = 11
}

/// Halation source: what light gets through the emulsion and bounces back.
struct HaloP {
    var threshold: Float = 0.60
    var knee: Float = 0.25
    var tintR: Float = 1.0
    var tintG: Float = 0.42
    var tintB: Float = 0.12
    var coreSigma: Float = 0.004
    var auraSigma: Float = 0.025
    var pad0: Float = 0
}

/// One separable Gaussian pass. Sigma is a fraction of the short side of the
/// texture being blurred; red spreads widest, blue least, like the layers.
struct BlurP {
    var dirX: Float = 1
    var dirY: Float = 0
    var sigmaFrac: Float = 0.004
    var scaleR: Float = 1.0
    var scaleG: Float = 0.8
    var scaleB: Float = 0.65
    var maxRadius: Float = 24
    var pad0: Float = 0
}

/// The film response: halation, glare, shoulder, the measured curve, the
/// three zone tints, and the perceptual color stage.
struct DevelopP {
    var kCore: Float = 0.20
    var kAura: Float = 0.08
    var auraR: Float = 1.0
    var auraG: Float = 0.30
    var auraB: Float = 0.08
    var glare: Float = 0.04
    var knee: Float = 0.80
    var clipDesat0: Float = 0.85
    var clipDesat1: Float = 1.6
    var toeLift: Float = 0.02
    var shR: Float = -0.020
    var shG: Float = 0.006
    var shB: Float = 0.014
    var midR: Float = 0.016
    var midG: Float = 0.010
    var midB: Float = -0.024
    var hlR: Float = 0.060
    var hlG: Float = -0.006
    var hlB: Float = -0.050
    var sat: Float = 1.05
    var vibrance: Float = 0.18
    var density: Float = 0.08
    var hlDesatStart: Float = 0.80
    var hlDesatAmt: Float = 0.5
    var skinHue: Float = 50
    var skinSigma: Float = 22
    var skinPull: Float = 0.25
    var skinChroma: Float = 0.92
    var skinLift: Float = 0.015
    var folHue: Float = 135
    var folSigma: Float = 25
    var folShift: Float = -12
    var folChroma: Float = 0.85
    var skyHue: Float = 258
    var skySigma: Float = 22
    var skyShift: Float = -8
    var skyChroma: Float = 1.25
    var skyDark: Float = 0.05
    var chromaGate0: Float = 0.02
    var chromaGate1: Float = 0.08
}

/// Highlight diffusion and bloom on the developed image, in linear light.
struct DiffuseP {
    var radiusFrac: Float = 0.00529
    var radiusMin: Float = 1.5
    var softAmt: Float = 0.60
    var hiE0: Float = 0.147
    var hiE1: Float = 0.57
    var bloomI: Float = 0.10
    var bloomE0: Float = 0.26
    var bloomE1: Float = 0.89
}

/// The lens and the print: corner defocus, lateral CA, vignette, grain.
struct PrintP {
    var vigAmount: Float = 0.40
    var vigK: Float = 1.15
    var vigMech: Float = 0.10
    var onset: Float = 0.25
    var defocusK: Float = 0.00050
    var defocusP: Float = 1.80
    var softGlobal: Float = 0.00055
    var aniso: Float = 3.20
    var caOnset: Float = 0.45
    var caK: Float = 0.00090
    var caB: Float = 0.00090
    var caP: Float = 1.0
    var grainAmount: Float = 0.045
    var grainDiv: Float = 900
    var grainChroma: Float = 0.30
    var grainFloor: Float = 0.35
    var grainMid: Float = 0.80
    var grainBlue: Float = 1.30
    var seed: Float = 0
    var dither: Float = 1.0
    var grainSizeMin: Float = 1.0
    var grainSharp: Float = 0.0
    var pad0: Float = 0
    var pad1: Float = 0
}

// MARK: - Engine

final class VesperEngine: @unchecked Sendable {
    static let shared = VesperEngine()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var legacyLibrary: MTLLibrary?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    /// False when the Vesper kernels failed to compile on this device and the
    /// engine fell back to the Marenn 400 kernels.
    let vesperAvailable: Bool
    var defaultStock: FilmStock = .vesper800
    private(set) var lastReport = VesperReport()

    // Marenn 400 tuning hooks, kept as they were.
    var gradeOverride: GradeP?
    var clarityOverride: ClarityP?
    var compOverride: CompP?
    var expRef: Float = 0.37000
    var expPow: Float = 0.45

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        var vesper: MTLLibrary? = nil
        do {
            vesper = try device.makeLibrary(source: VesperEngine.prelude + VesperEngine.vesperSource, options: nil)
        } catch {
            print("Vesper 800: Metal compile failed, falling back to Marenn 400: \(error)")
        }
        if let vesper = vesper {
            self.library = vesper
            self.vesperAvailable = true
        } else {
            do {
                self.library = try device.makeLibrary(source: VesperEngine.prelude + VesperEngine.legacySource, options: nil)
            } catch {
                return nil
            }
            self.legacyLibrary = self.library
            self.vesperAvailable = false
            self.defaultStock = .marenn400
        }
    }

    private func pipeline(_ name: String, legacy: Bool) -> MTLComputePipelineState? {
        if let cached = pipelines[name] { return cached }
        let lib: MTLLibrary
        if legacy {
            if legacyLibrary == nil {
                legacyLibrary = try? device.makeLibrary(source: VesperEngine.prelude + VesperEngine.legacySource, options: nil)
            }
            guard let l = legacyLibrary else { return nil }
            lib = l
        } else {
            lib = library
        }
        guard let fn = lib.makeFunction(name: name),
              let pso = try? device.makeComputePipelineState(function: fn) else { return nil }
        pipelines[name] = pso
        return pso
    }

    func process(_ image: CGImage) -> CGImage? {
        process(image, options: VesperOptions())
    }

    func process(_ image: CGImage, options: VesperOptions) -> CGImage? {
        guard let source = bake(image) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let wanted = options.stock ?? defaultStock
        if wanted == .vesper800 && vesperAvailable {
            if let out = processVesper(source, options: options) { return out }
            print("Vesper 800: render failed, retrying with Marenn 400")
        }
        return processLegacy(source, options: options)
    }

    // MARK: Vesper 800 host path

    private struct VesperStats {
        var p50: Float = 0.45
        var p90: Float = 0.80
        var darkFrac: Float = 0
        var brightFrac: Float = 0
        var meanR: Float = 1
        var meanG: Float = 1
        var meanB: Float = 1
        var hash: UInt32 = 0
    }

    private struct VesperScene {
        var gainR: Float
        var gainG: Float
        var gainB: Float
        var gain: Float
        var wbR: Float
        var wbB: Float
        var flash: Float
        var night: Float
        var highKey: Float
        var seed: Float
        var seedBits: UInt32
        var grainScale: Float
    }

    private static func eotf(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Deterministic value in -1...1 from a seed and a salt.
    private static func unit(_ h: UInt32, _ salt: UInt32) -> Float {
        var x = (h ^ salt) &* 2654435761
        x ^= x >> 15
        x = x &* 2246822519
        x ^= x >> 13
        return Float(x % 20001) / 10000 - 1
    }

    private func vesperSceneStats(_ baked: Baked) -> VesperStats {
        var s = VesperStats()
        let bytes = baked.bytes
        let total = baked.width * baked.height
        guard total > 0 else { return s }
        var step = max(1, total / 40000)
        if step % 2 == 0 { step += 1 }
        var hist = [Int](repeating: 0, count: 256)
        var count = 0
        var midR: Float = 0, midG: Float = 0, midB: Float = 0
        var midCount = 0
        var idx = 0
        while idx < total {
            let p = idx * 4
            let r = Float(bytes[p]) / 255
            let g = Float(bytes[p + 1]) / 255
            let b = Float(bytes[p + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            hist[min(255, max(0, Int(l * 255 + 0.5)))] += 1
            if l > 0.3 && l < 0.85 {
                midR += r
                midG += g
                midB += b
                midCount += 1
            }
            count += 1
            idx += step
        }
        var acc = 0
        var p50 = -1
        var p90 = -1
        var dark = 0
        var bright = 0
        for i in 0..<256 {
            acc += hist[i]
            if p50 < 0 && acc * 2 >= count { p50 = i }
            if p90 < 0 && acc * 10 >= count * 9 { p90 = i }
            if i < 31 { dark += hist[i] }
            if i > 216 { bright += hist[i] }
        }
        s.p50 = (Float(max(p50, 0)) + 0.5) / 256
        s.p90 = (Float(max(p90, 0)) + 0.5) / 256
        s.darkFrac = Float(dark) / Float(count)
        s.brightFrac = Float(bright) / Float(count)
        if midCount > 0 {
            s.meanR = midR / Float(midCount)
            s.meanG = midG / Float(midCount)
            s.meanB = midB / Float(midCount)
        }
        var h: UInt32 = 2166136261
        for i in 0..<256 {
            h = (h ^ UInt32(truncatingIfNeeded: hist[i])) &* 16777619
        }
        h = (h ^ UInt32(truncatingIfNeeded: baked.width)) &* 16777619
        h = (h ^ UInt32(truncatingIfNeeded: baked.height)) &* 16777619
        s.hash = h
        return s
    }

    private func deriveScene(_ s: VesperStats, options: VesperOptions) -> VesperScene {
        let refLin = VesperEngine.eotf(0.37)
        var gain = powf(refLin / max(VesperEngine.eotf(s.p50), 0.002), 0.42)
        gain = min(max(gain, 0.72), 1.55)
        let p90Lin = VesperEngine.eotf(s.p90)
        if p90Lin > 0.05 { gain = min(gain, 0.95 / p90Lin) }
        var flash = VesperEngine.smooth(0.35, 0.6, s.darkFrac) * VesperEngine.smooth(0.02, 0.08, s.brightFrac)
        if let hint = options.flash { flash = hint ? max(flash, 0.7) : 0 }
        let night = 1 - VesperEngine.smooth(0.12, 0.30, s.p50)
        let highKey = VesperEngine.smooth(0.55, 0.75, s.p50)
        var wbR: Float = 1
        var wbB: Float = 1
        if s.meanR > 0.01 && s.meanG > 0.01 && s.meanB > 0.01 {
            let satM = max(abs(s.meanR / s.meanG - 1), abs(s.meanB / s.meanG - 1))
            let gate = 1 - VesperEngine.smooth(0.25, 0.45, satM)
            let rawR = min(max(1 + 0.35 * (s.meanG / s.meanR - 1), 0.97), 1.03)
            let rawB = min(max(1 + 0.35 * (s.meanG / s.meanB - 1), 0.97), 1.03)
            wbR = 1 + (rawR - 1) * gate
            wbB = 1 + (rawB - 1) * gate
        }
        var seed = options.seed ?? Float(s.hash % 100000) / 100
        if !(seed >= 0 && seed < 1000000) { seed = 3 }
        let seedBits = UInt32(seed * 1000)
        let u1 = VesperEngine.unit(seedBits, 1)
        let u2 = VesperEngine.unit(seedBits, 2)
        let u3 = VesperEngine.unit(seedBits, 3)
        gain *= powf(2, 0.06 * u1)
        let warm = 1 + 0.015 * u2
        return VesperScene(gainR: gain * wbR * warm, gainG: gain, gainB: gain * wbB / warm, gain: gain,
                           wbR: wbR, wbB: wbB, flash: flash, night: night, highKey: highKey,
                           seed: seed, seedBits: seedBits, grainScale: 1 + 0.1 * u3)
    }

    private static func stampParams(_ text: String?) -> StampP {
        var s = StampP()
        guard let text = text, !text.isEmpty else { return s }
        var codes: [Float] = []
        for ch in text.unicodeScalars {
            let code: Int
            switch ch {
            case "0"..."9": code = Int(ch.value) - 48
            case "'", "`": code = 10
            case " ", ".", "/", ":": code = 11
            case "-": code = 12
            default: continue
            }
            codes.append(Float(code))
            if codes.count == 10 { break }
        }
        guard !codes.isEmpty else { return s }
        while codes.count < 10 { codes.append(11) }
        s.enabled = 1
        s.count = Float(codes.count)
        s.c0 = codes[0]
        s.c1 = codes[1]
        s.c2 = codes[2]
        s.c3 = codes[3]
        s.c4 = codes[4]
        s.c5 = codes[5]
        s.c6 = codes[6]
        s.c7 = codes[7]
        s.c8 = codes[8]
        s.c9 = codes[9]
        // Trailing padding does not count as characters.
        var n = 10
        while n > 0 && codes[n - 1] == 11 { n -= 1 }
        s.count = Float(max(n, 1))
        return s
    }

    private func processVesper(_ source: Baked, options: VesperOptions) -> CGImage? {
        let w = source.width, h = source.height
        guard w >= 1, h >= 1 else { return nil }
        guard let exposePSO = pipeline("vesper_expose", legacy: false),
              let haloPSO = pipeline("vesper_halo_source", legacy: false),
              let downPSO = pipeline("vesper_down", legacy: false),
              let blurPSO = pipeline("vesper_blur", legacy: false),
              let developPSO = pipeline("vesper_develop", legacy: false),
              let diffusePSO = pipeline("vesper_diffuse", legacy: false),
              let printPSO = pipeline("vesper_print", legacy: false) else { return nil }

        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let srcTex = makeTexture(w, h, format: .rgba8Unorm, usage: [.shaderRead]),
              let tA = makeTexture(w, h, format: .rgba16Float, usage: usage),
              let tB = makeTexture(w, h, format: .rgba16Float, usage: usage),
              let tFinal = makeTexture(w, h, format: .rgba8Unorm, usage: usage) else { return nil }

        let hw = max(1, Int((Double(w) / 2).rounded()))
        let hh = max(1, Int((Double(h) / 2).rounded()))
        let qw = max(1, Int((Double(hw) / 2).rounded()))
        let qh = max(1, Int((Double(hh) / 2).rounded()))
        let ew = max(1, Int((Double(qw) / 2).rounded()))
        let eh = max(1, Int((Double(qh) / 2).rounded()))
        guard let tHalf = makeTexture(hw, hh, format: .rgba16Float, usage: usage),
              let tHalf2 = makeTexture(hw, hh, format: .rgba16Float, usage: usage),
              let tQuarter = makeTexture(qw, qh, format: .rgba16Float, usage: usage),
              let tEighth = makeTexture(ew, eh, format: .rgba16Float, usage: usage),
              let tEighth2 = makeTexture(ew, eh, format: .rgba16Float, usage: usage) else { return nil }

        srcTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: source.bytes, bytesPerRow: w * 4)

        let stats = vesperSceneStats(source)
        let scene = deriveScene(stats, options: options)

        var expose = ExposeP()
        expose.gainR = scene.gainR
        expose.gainG = scene.gainG
        expose.gainB = scene.gainB
        expose.leakAmount = min(max(options.lightLeak, 0), 1) * 0.8
        expose.leakEdge = Float(scene.seedBits % 4)
        expose.leakSeed = Float(scene.seedBits % 1000) / 100

        var stamp = VesperEngine.stampParams(options.dateStamp)

        var halo = HaloP()
        halo.threshold += 0.15 * scene.highKey

        var coreH = BlurP()
        coreH.sigmaFrac = halo.coreSigma
        var coreV = coreH
        coreV.dirX = 0
        coreV.dirY = 1
        var auraH = BlurP()
        auraH.sigmaFrac = halo.auraSigma
        var auraV = auraH
        auraV.dirX = 0
        auraV.dirY = 1

        var develop = DevelopP()
        develop.kCore *= 1 + 0.5 * scene.flash
        develop.kAura *= 1 + 0.5 * scene.flash
        develop.toeLift *= 1 - 0.3 * scene.flash

        var diffuse = DiffuseP()

        var print = PrintP()
        print.vigAmount *= 1 + 0.4 * scene.flash
        print.grainAmount *= (1 + 0.35 * scene.night) * scene.grainScale
        if !options.grain { print.grainAmount = 0 }
        print.seed = scene.seed

        guard let cmd = queue.makeCommandBuffer() else { return nil }

        encode(cmd, exposePSO, w, h, textures: [srcTex, tA]) { enc in
            enc.setBytes(&expose, length: MemoryLayout<ExposeP>.stride, index: 0)
            enc.setBytes(&stamp, length: MemoryLayout<StampP>.stride, index: 1)
        }
        encode(cmd, haloPSO, hw, hh, textures: [tA, tHalf]) { enc in
            enc.setBytes(&halo, length: MemoryLayout<HaloP>.stride, index: 0)
        }
        encode(cmd, downPSO, qw, qh, textures: [tHalf, tQuarter]) { _ in }
        encode(cmd, downPSO, ew, eh, textures: [tQuarter, tEighth]) { _ in }
        encode(cmd, blurPSO, hw, hh, textures: [tHalf, tHalf2]) { enc in
            enc.setBytes(&coreH, length: MemoryLayout<BlurP>.stride, index: 0)
        }
        encode(cmd, blurPSO, hw, hh, textures: [tHalf2, tHalf]) { enc in
            enc.setBytes(&coreV, length: MemoryLayout<BlurP>.stride, index: 0)
        }
        encode(cmd, blurPSO, ew, eh, textures: [tEighth, tEighth2]) { enc in
            enc.setBytes(&auraH, length: MemoryLayout<BlurP>.stride, index: 0)
        }
        encode(cmd, blurPSO, ew, eh, textures: [tEighth2, tEighth]) { enc in
            enc.setBytes(&auraV, length: MemoryLayout<BlurP>.stride, index: 0)
        }
        encode(cmd, developPSO, w, h, textures: [tA, tHalf, tEighth, tB]) { enc in
            enc.setBytes(&develop, length: MemoryLayout<DevelopP>.stride, index: 0)
        }
        encode(cmd, diffusePSO, w, h, textures: [tB, tA]) { enc in
            enc.setBytes(&diffuse, length: MemoryLayout<DiffuseP>.stride, index: 0)
        }
        encode(cmd, printPSO, w, h, textures: [tA, tFinal]) { enc in
            enc.setBytes(&print, length: MemoryLayout<PrintP>.stride, index: 0)
        }

        #if os(macOS)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: tFinal)
            blit.endEncoding()
        }
        #endif

        cmd.commit()
        cmd.waitUntilCompleted()

        var report = VesperReport()
        report.stock = .vesper800
        report.p50 = stats.p50
        report.p90 = stats.p90
        report.darkFrac = stats.darkFrac
        report.brightFrac = stats.brightFrac
        report.gain = scene.gain
        report.wbR = scene.wbR
        report.wbB = scene.wbB
        report.flash = scene.flash
        report.night = scene.night
        report.highKey = scene.highKey
        report.seed = scene.seed
        lastReport = report

        return readBack(tFinal)
    }

    // MARK: Marenn 400 host path (as shipped)

    private func processLegacy(_ source: Baked, options: VesperOptions) -> CGImage? {
        let w = source.width, h = source.height
        guard w > 1, h > 1 else { return nil }
        guard let gradePSO = pipeline("marenn_grade", legacy: true),
              let clarityPSO = pipeline("marenn_clarity", legacy: true),
              let brightPSO = pipeline("marenn_bright", legacy: true),
              let blurPSO = pipeline("marenn_blur", legacy: true),
              let compositePSO = pipeline("marenn_composite", legacy: true) else { return nil }

        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let srcTex = makeTexture(w, h, format: .rgba8Unorm, usage: [.shaderRead]),
              let tA = makeTexture(w, h, format: .rgba16Float, usage: usage),
              let tB = makeTexture(w, h, format: .rgba16Float, usage: usage),
              let tFinal = makeTexture(w, h, format: .rgba8Unorm, usage: usage) else { return nil }

        let hw = max(2, Int((Double(w) / 2).rounded()))
        let hh = max(2, Int((Double(h) / 2).rounded()))
        guard let tHalf = makeTexture(hw, hh, format: .rgba16Float, usage: usage),
              let tHalf2 = makeTexture(hw, hh, format: .rgba16Float, usage: usage) else { return nil }

        srcTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: source.bytes, bytesPerRow: w * 4)

        guard let cmd = queue.makeCommandBuffer() else { return nil }

        let stats = sceneStats(source)
        var grade = gradeOverride ?? GradeP()
        grade.gain = exposureGain(stats)
        encode(cmd, gradePSO, w, h, textures: [srcTex, tA]) { enc in
            enc.setBytes(&grade, length: MemoryLayout<GradeP>.stride, index: 0)
        }

        let minDim = Float(min(w, h))
        var clar = clarityOverride ?? ClarityP()
        clar.radiusPx = max(1.5, minDim / 189)
        encode(cmd, clarityPSO, w, h, textures: [tA, tB]) { enc in
            enc.setBytes(&clar, length: MemoryLayout<ClarityP>.stride, index: 0)
        }

        var bright = BrightP()
        encode(cmd, brightPSO, hw, hh, textures: [tB, tHalf]) { enc in
            enc.setBytes(&bright, length: MemoryLayout<BrightP>.stride, index: 0)
        }

        let halStep = max(0.8, 0.0022 * minDim)
        var read = tHalf, write = tHalf2
        for _ in 0..<2 {
            var dirH = SIMD2<Float>(halStep / Float(hw), 0)
            encode(cmd, blurPSO, hw, hh, textures: [read, write]) { enc in
                enc.setBytes(&dirH, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
            swap(&read, &write)
            var dirV = SIMD2<Float>(0, halStep / Float(hh))
            encode(cmd, blurPSO, hw, hh, textures: [read, write]) { enc in
                enc.setBytes(&dirV, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
            swap(&read, &write)
        }

        var comp = compOverride ?? CompP()
        if compOverride == nil { comp.seed = options.seed ?? Float.random(in: 0..<1000) }
        if !options.grain { comp.grainAmount = 0 }
        comp.grainSize = max(1.0, minDim / max(comp.grainDiv, 1))
        encode(cmd, compositePSO, w, h, textures: [tB, read, tFinal]) { enc in
            enc.setBytes(&comp, length: MemoryLayout<CompP>.stride, index: 0)
        }

        #if os(macOS)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: tFinal)
            blit.endEncoding()
        }
        #endif

        cmd.commit()
        cmd.waitUntilCompleted()

        var report = VesperReport()
        report.stock = .marenn400
        report.p50 = stats.p50
        report.gain = grade.gain
        report.seed = comp.seed
        lastReport = report

        return readBack(tFinal)
    }

    // MARK: Shared plumbing

    private func encode(_ cmd: MTLCommandBuffer, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int,
                        textures: [MTLTexture], _ uniforms: (MTLComputeCommandEncoder) -> Void) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        uniforms(enc)
        let tw = max(1, pso.threadExecutionWidth)
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        let tg = MTLSize(width: tw, height: th, depth: 1)
        let groups = MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func makeTexture(_ w: Int, _ h: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        desc.usage = usage
        #if os(macOS)
        desc.storageMode = format == .rgba8Unorm ? .managed : .private
        #else
        desc.storageMode = format == .rgba8Unorm ? .shared : .private
        #endif
        return device.makeTexture(descriptor: desc)
    }

    private func exposureGain(_ s: SceneStats) -> Float {
        let raw = powf(expRef / max(s.p50, 0.05), expPow)
        return max(0.85, min(1.20, raw))
    }

    private func sceneStats(_ baked: Baked) -> SceneStats {
        let bytes = baked.bytes
        let total = baked.width * baked.height
        guard total > 0 else { return SceneStats(p50: 0.45, meanLuma: 0.45, hiFrac: 0) }
        let step = max(1, total / 40000)
        var hist = [Int](repeating: 0, count: 64)
        var count = 0
        var lumaSum: Float = 0
        var hiCount = 0
        var idx = 0
        while idx < total {
            let p = idx * 4
            let r = Float(bytes[p]) / 255
            let g = Float(bytes[p + 1]) / 255
            let b = Float(bytes[p + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumaSum += l
            if l > 0.82 { hiCount += 1 }
            hist[min(63, Int(l * 64))] += 1
            count += 1
            idx += step
        }
        var acc = 0
        var p50: Float = 0.45
        for i in 0..<64 {
            acc += hist[i]
            if acc >= count / 2 {
                p50 = (Float(i) + 0.5) / 64
                break
            }
        }
        return SceneStats(p50: p50, meanLuma: lumaSum / Float(count), hiFrac: Float(hiCount) / Float(count))
    }

    private struct Baked { let bytes: [UInt8]; let width: Int; let height: Int }

    private func bake(_ cg: CGImage) -> Baked? {
        let w = cg.width, h = cg.height
        guard w >= 1, h >= 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Baked(bytes: bytes, width: w, height: h)
    }

    private func readBack(_ texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: - Metal source
    //
    // Three strings: shared helpers, the Marenn 400 kernels as shipped, and the
    // Vesper 800 kernels. The engine compiles prelude + vesperSource and falls
    // back to prelude + legacySource if that fails. Tools/ref compiles the same
    // strings on the CPU. Rules for these strings: no backslashes, no triple
    // quotes, no tabs, indent every line at least as far as the closing quotes.

    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 LW = float3(0.2126, 0.7152, 0.0722);
    constant float2 RING8[8] = {
        float2(1.0, 0.0), float2(0.70711, 0.70711), float2(0.0, 1.0), float2(-0.70711, 0.70711),
        float2(-1.0, 0.0), float2(-0.70711, -0.70711), float2(0.0, -1.0), float2(0.70711, -0.70711)
    };
    constant float2 DISC6[6] = {
        float2(1.0, 0.0), float2(0.5, 0.86603), float2(-0.5, 0.86603),
        float2(-1.0, 0.0), float2(-0.5, -0.86603), float2(0.5, -0.86603)
    };
    inline float lumv(float3 c) { return dot(c, LW); }
    inline float hashv(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }

    constant float KX[7] = {0.0, 0.05, 0.15, 0.30, 0.50, 0.72, 1.0};
    constant float KY[7] = {0.04997, 0.08906, 0.19790, 0.37006, 0.54963, 0.77005, 0.92492};
    constant float KM[7] = {0.70753, 0.87665, 1.16177, 1.02403, 0.95497, 0.66508, 0.32555};

    inline float toneCurve(float x) {
        x = clamp(x, 0.0, 1.0);
        int i = 0;
        for (int k = 5; k >= 1; k--) { if (x >= KX[k]) { i = k; break; } }
        float h = KX[i + 1] - KX[i];
        float t = (x - KX[i]) / h;
        float t2 = t * t, t3 = t2 * t;
        return (2*t3 - 3*t2 + 1) * KY[i] + (t3 - 2*t2 + t) * h * KM[i]
             + (-2*t3 + 3*t2) * KY[i + 1] + (t3 - t2) * h * KM[i + 1];
    }

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    inline float3 hueRotate(float3 c, float ang) {
        float ca = cos(ang), sa = sin(ang);
        const float third = 1.0 / 3.0;
        float sq = sqrt(third);
        float3x3 m = float3x3(
            float3(ca + (1 - ca) * third, third * (1 - ca) + sq * sa, third * (1 - ca) - sq * sa),
            float3(third * (1 - ca) - sq * sa, ca + third * (1 - ca), third * (1 - ca) + sq * sa),
            float3(third * (1 - ca) + sq * sa, third * (1 - ca) - sq * sa, ca + third * (1 - ca)));
        return m * c;
    }

    inline float3 defocusSample(texture2d<float, access::sample> t, float2 uvR, float2 uvG, float2 uvB,
                                float2 axR, float2 axT) {
        float3 acc = float3(t.sample(smp, uvR).r, t.sample(smp, uvG).g, t.sample(smp, uvB).b);
        if (length(axR) < 1e-7 && length(axT) < 1e-7) return acc;
        float wsum = 1.0;
        for (int i = 0; i < 6; i++) {
            float2 o1 = axR * (DISC6[i].x * 0.5) + axT * (DISC6[i].y * 0.5);
            float2 o2 = axR * DISC6[i].x + axT * DISC6[i].y;
            acc += float3(t.sample(smp, uvR + o1).r, t.sample(smp, uvG + o1).g, t.sample(smp, uvB + o1).b) * 0.60653;
            acc += float3(t.sample(smp, uvR + o2).r, t.sample(smp, uvG + o2).g, t.sample(smp, uvB + o2).b) * 0.13534;
            wsum += 0.60653 + 0.13534;
        }
        return acc / wsum;
    }

    inline float vnoise(float2 p, float seed) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hashv(i + seed);
        float b = hashv(i + float2(1, 0) + seed);
        float c = hashv(i + float2(0, 1) + seed);
        float d = hashv(i + float2(1, 1) + seed);
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) - 0.5;
    }

    """

    static let legacySource = """
    struct GradeP {
        float gain, satGlobal, blueSatK, blueSatT0, blueSatT1, blueDark, blueHue, pad0, pad1;
    };
    struct ClarityP { float radiusPx, softAmt, hiE0, hiE1, bloomI, pad0; };
    struct BrightP { float threshold, glowR, glowG, glowB; };
    struct CompP {
        float halIntensity;
        float vigAmount, vigRadius, vigFeather;
        float onset, defocusK, defocusP, softGlobal, aniso;
        float caOnset, caK, caB, caP;
        float grainAmount, grainSize, grainDiv, seed;
    };

    kernel void marenn_grade(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant GradeP& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = src.read(gid).rgb * p.gain;
        c = float3(toneCurve(c.r), toneCurve(c.g), toneCurve(c.b));
        float L = lumv(c);
        float shW = 1.0 - smoothstep(0.10, 0.42, L);
        c += float3(-0.01785, 0.00481, 0.01304) * shW;
        float dm = L - 0.58;
        float midW = exp(-dm * dm / 0.0968);
        c *= 1.0 + float3(0.01200, 0.01200, -0.02400) * midW;
        float hlW = smoothstep(0.70, 0.95, L);
        c *= 1.0 + float3(0.05777, -0.00631, -0.05146) * hlW;
        float L2 = lumv(c);
        c = L2 + (c - L2) * p.satGlobal;
        float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
        float s = (mx - mn) / (mx + 1e-4);
        float wb = clamp((c.b - max(c.r, c.g)) / (mx - mn + 1e-4), 0.0, 1.0);
        float boost = p.blueSatK * smoothstep(p.blueSatT0, p.blueSatT1, s)
                    - 0.05 * (1.0 - smoothstep(0.30, p.blueSatT0, s));
        float kk = wb * boost;
        float L3 = lumv(c);
        c = L3 + (c - L3) * (1.0 + kk);
        c *= 1.0 - p.blueDark * clamp(kk, 0.0, 1.0);
        float hw = wb * smoothstep(0.35, 0.65, s);
        c = hueRotate(c, p.blueHue * hw);
        dst.write(float4(clamp(c, 0.0, 1.0), 1.0), gid);
    }

    kernel void marenn_clarity(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant ClarityP& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float2 uv = (float2(gid) + 0.5) / res;
        float3 center = src.sample(smp, uv).rgb;
        float2 r1 = float2(p.radiusPx) / res;
        float2 r2 = r1 * 0.5;
        float2 r3 = r1 * 2.4;
        float3 low = center * 0.25;
        float3 wide = center * 0.2;
        float wsum = 0.25;
        for (int i = 0; i < 8; i++) {
            low += src.sample(smp, uv + RING8[i] * r2).rgb * 0.06;
            low += src.sample(smp, uv + RING8[i] * r1).rgb * 0.0325;
            wide += src.sample(smp, uv + RING8[i] * r3).rgb * 0.1;
            wsum += 0.06 + 0.0325;
        }
        low /= wsum;
        float hi = smoothstep(p.hiE0, p.hiE1, lumv(center));
        float3 outc = mix(center, low, hi * p.softAmt);
        float3 bloomSrc = wide * smoothstep(0.55, 0.95, lumv(wide));
        outc = 1.0 - (1.0 - outc) * (1.0 - clamp(bloomSrc * p.bloomI, 0.0, 1.0));
        dst.write(float4(clamp(outc, 0.0, 1.0), 1.0), gid);
    }

    kernel void marenn_bright(texture2d<float, access::sample> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant BrightP& p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 c = src.sample(smp, uv).rgb;
        float b = clamp((lumv(c) - p.threshold) / (1.0 - p.threshold), 0.0, 1.0);
        dst.write(float4(c * b * float3(p.glowR, p.glowG, p.glowB), 1.0), gid);
    }

    kernel void marenn_blur(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float2& dir [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float3 s = src.sample(smp, uv).rgb * 0.227027;
        s += src.sample(smp, uv + dir * 1.3846).rgb * 0.316216;
        s += src.sample(smp, uv - dir * 1.3846).rgb * 0.316216;
        s += src.sample(smp, uv + dir * 3.2308).rgb * 0.070270;
        s += src.sample(smp, uv - dir * 3.2308).rgb * 0.070270;
        dst.write(float4(s, 1.0), gid);
    }

    kernel void marenn_composite(texture2d<float, access::sample> graded [[texture(0)]],
                                 texture2d<float, access::sample> glow [[texture(1)]],
                                 texture2d<float, access::write> dst [[texture(2)]],
                                 constant CompP& p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float minDim = min(res.x, res.y);
        float2 uv = (float2(gid) + 0.5) / res;
        float2 ctr = uv - 0.5;
        float d = length(ctr) * 1.41421;

        float2 q = (float2(gid) + 0.5) - res * 0.5;
        float2 dirPx = length(q) > 1e-4 ? normalize(q) : float2(1, 0);
        float2 tanPx = float2(-dirPx.y, dirPx.x);

        float gate = smoothstep(p.onset, 1.0, d);
        float soft = p.softGlobal * minDim;
        float defo = p.defocusK * pow(gate, p.defocusP) * minDim;
        float sigR = soft + defo * p.aniso;
        float sigT = soft + defo / p.aniso;

        float2 axR = float2(0), axT = float2(0);
        if (max(sigR, sigT) > 0.08) {
            axR = dirPx * (2.0 * sigR) / res;
            axT = tanPx * (2.0 * sigT) / res;
        }

        float caGate = smoothstep(p.caOnset, 1.05, d);
        float caR = p.caK * pow(caGate, p.caP) * minDim;
        float caBv = p.caB * pow(caGate, p.caP) * minDim;
        float2 uvR = uv + dirPx * caR / res;
        float2 uvG = uv;
        float2 uvB = uv - dirPx * caBv / res;

        float3 col = defocusSample(graded, uvR, uvG, uvB, axR, axT);

        float3 g = glow.sample(smp, uv).rgb * p.halIntensity;
        col = 1.0 - (1.0 - col) * (1.0 - clamp(g, 0.0, 1.0));

        float vig = 1.0 - smoothstep(p.vigRadius, p.vigRadius + p.vigFeather, d) * p.vigAmount;
        col *= vig;

        float2 fc = float2(gid) + 0.5;
        float n = 0.8 * vnoise(fc / p.grainSize, p.seed) + 0.2 * vnoise(fc / (p.grainSize * 2.2), p.seed + 17.0);
        n *= 3.2;
        float gw = 0.92 + 0.16 * (1.0 - lumv(col));
        col += n * p.grainAmount * gw;

        dst.write(float4(clamp(col, 0.0, 1.0), 1.0), gid);
    }

    """

    static let vesperSource = """
    struct ExposeP {
        float gainR, gainG, gainB, clampMax;
        float leakAmount, leakEdge, leakSeed, leakWidth;
        float leakR, leakG, leakB, pad0;
    };
    struct StampP {
        float enabled, count, marginX, marginY;
        float height, skew, intensity, glow;
        float r, g, b, minDim;
        float c0, c1, c2, c3, c4, c5, c6, c7, c8, c9;
    };
    struct HaloP { float threshold, knee, tintR, tintG, tintB, coreSigma, auraSigma, pad0; };
    struct BlurP { float dirX, dirY, sigmaFrac, scaleR, scaleG, scaleB, maxRadius, pad0; };
    struct DevelopP {
        float kCore, kAura, auraR, auraG, auraB, glare, knee, clipDesat0;
        float clipDesat1, toeLift, shR, shG, shB, midR, midG, midB;
        float hlR, hlG, hlB, sat, vibrance, density, hlDesatStart, hlDesatAmt;
        float skinHue, skinSigma, skinPull, skinChroma, skinLift, folHue, folSigma, folShift;
        float folChroma, skyHue, skySigma, skyShift, skyChroma, skyDark, chromaGate0, chromaGate1;
    };
    struct DiffuseP { float radiusFrac, radiusMin, softAmt, hiE0, hiE1, bloomI, bloomE0, bloomE1; };
    struct PrintP {
        float vigAmount, vigK, vigMech, onset, defocusK, defocusP, softGlobal, aniso;
        float caOnset, caK, caB, caP, grainAmount, grainDiv, grainChroma, grainFloor;
        float grainMid, grainBlue, seed, dither, grainSizeMin, grainSharp, pad0, pad1;
    };

    // ---- transfer functions and OKLab ----

    inline float srgbToLinear1(float c) {
        c = max(c, 0.0);
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    inline float linearToSrgb1(float c) {
        c = max(c, 0.0);
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }
    inline float3 srgbToLinear(float3 c) { return float3(srgbToLinear1(c.r), srgbToLinear1(c.g), srgbToLinear1(c.b)); }
    inline float3 linearToSrgb(float3 c) { return float3(linearToSrgb1(c.r), linearToSrgb1(c.g), linearToSrgb1(c.b)); }

    inline float cbrtSigned(float x) { return sign(x) * pow(abs(x), 1.0 / 3.0); }

    inline float3 linearToOklab(float3 c) {
        float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
        float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
        float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
        l = cbrtSigned(l); m = cbrtSigned(m); s = cbrtSigned(s);
        return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
    }

    inline float3 oklabToLinear(float3 lab) {
        float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
        float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
        float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
        l = l * l * l; m = m * m * m; s = s * s * s;
        return float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    }

    inline float wrapAngle(float d) { return fmod(d + 540.0, 360.0) - 180.0; }
    inline float hueWeight(float h, float center, float sigma) {
        float d = wrapAngle(h - center) / sigma;
        return exp(-d * d);
    }

    // Excess above a threshold with a quadratic knee, zero below.
    inline float softKnee(float x, float t, float k) {
        float d = x - t;
        if (d <= -k) return 0.0;
        if (d >= k) return d;
        float u = d + k;
        return u * u / (4.0 * k);
    }

    // Identity below the knee, then an exponential approach to 1.0 with a
    // continuous first derivative at the knee.
    inline float shoulder1(float x, float k) {
        return x <= k ? x : k + (1.0 - k) * (1.0 - exp(-(x - k) / (1.0 - k)));
    }

    // ---- integer hash noise (bit exact on every device) ----

    inline uint ihash(uint x) {
        x ^= x >> 16; x *= 0x7feb352dU;
        x ^= x >> 15; x *= 0x846ca68bU;
        x ^= x >> 16;
        return x;
    }
    inline float hash01(uint x, uint y, uint s) {
        uint h = ihash(x * 0x9E3779B1U + ihash(y * 0x85EBCA77U + s));
        return float(h) * 2.3283064e-10;
    }
    inline float latticeNoise(float2 gc, uint s) {
        float2 fl = floor(gc);
        float2 f = gc - fl;
        uint ix = uint(int(fl.x) + 1048576);
        uint iy = uint(int(fl.y) + 1048576);
        float a = hash01(ix, iy, s);
        float b = hash01(ix + 1u, iy, s);
        float c = hash01(ix, iy + 1u, s);
        float d = hash01(ix + 1u, iy + 1u, s);
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) - 0.5;
    }

    // ---- seven segment databack ----

    constant uint SEG_MASK[13] = {63u, 6u, 91u, 79u, 102u, 109u, 125u, 7u, 127u, 111u, 128u, 0u, 64u};

    inline float segDist(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        return length(pa - ba * t);
    }

    // Signed distance to a glyph in digit box units: x 0..0.58, y 0..1 downward.
    inline float glyphDist(float2 p, int code) {
        uint m = SEG_MASK[clamp(code, 0, 12)];
        float mg = 0.075, gp = 0.035;
        float xl = mg, xr = 0.58 - mg, yt = mg, ym = 0.5, yb = 1.0 - mg;
        float d = 1e9;
        if (m & 1u)   d = min(d, segDist(p, float2(xl + gp, yt), float2(xr - gp, yt)));
        if (m & 2u)   d = min(d, segDist(p, float2(xr, yt + gp), float2(xr, ym - gp)));
        if (m & 4u)   d = min(d, segDist(p, float2(xr, ym + gp), float2(xr, yb - gp)));
        if (m & 8u)   d = min(d, segDist(p, float2(xl + gp, yb), float2(xr - gp, yb)));
        if (m & 16u)  d = min(d, segDist(p, float2(xl, ym + gp), float2(xl, yb - gp)));
        if (m & 32u)  d = min(d, segDist(p, float2(xl, yt + gp), float2(xl, ym - gp)));
        if (m & 64u)  d = min(d, segDist(p, float2(xl + gp, ym), float2(xr - gp, ym)));
        if (m & 128u) d = min(d, segDist(p, float2(0.20, yt), float2(0.16, 0.24)));
        return d - 0.065;
    }

    inline float glyphAdvance(int code) {
        return code == 10 ? 0.30 : (code == 11 ? 0.45 : 0.72);
    }

    inline float3 stampLight(float2 px, float2 res, constant StampP& p) {
        if (p.enabled < 0.5 || min(res.x, res.y) < p.minDim) return float3(0.0);
        float hpx = p.height * res.y;
        int n = clamp(int(p.count), 0, 10);
        float codes[10] = {p.c0, p.c1, p.c2, p.c3, p.c4, p.c5, p.c6, p.c7, p.c8, p.c9};
        float total = 0.0;
        for (int i = 0; i < n; i++) total += glyphAdvance(int(codes[i]));
        float right = res.x * (1.0 - p.marginX);
        float x0 = right - total * hpx;
        float y0 = res.y * (1.0 - p.marginY) - hpx;
        float pad = 0.6 * hpx;
        if (px.x < x0 - pad || px.x > right + pad || px.y < y0 - pad || px.y > y0 + hpx + pad) return float3(0.0);
        float d = 1e9;
        float xc = x0;
        for (int i = 0; i < n; i++) {
            int code = int(codes[i]);
            float2 q = float2((px.x - xc) / hpx, (px.y - y0) / hpx);
            q.x -= p.skew * (1.0 - q.y);
            d = min(d, glyphDist(q, code));
            xc += glyphAdvance(code) * hpx;
        }
        float aa = 0.8 / hpx;
        float cover = 1.0 - smoothstep(-aa, aa, d);
        float halo = exp(-max(d, 0.0) / max(p.glow, 0.005));
        float light = (cover + 0.35 * halo * (1.0 - cover)) * p.intensity;
        return float3(p.r, p.g, p.b) * light;
    }

    // ---- light leak: fogging from one edge, shaped by low frequency noise ----

    inline float3 leakLight(float2 uv, constant ExposeP& p) {
        if (p.leakAmount <= 0.0) return float3(0.0);
        int edge = int(p.leakEdge);
        float u, t;
        if (edge == 0) { u = uv.x; t = uv.y; }
        else if (edge == 1) { u = 1.0 - uv.x; t = uv.y; }
        else if (edge == 2) { u = uv.y; t = uv.x; }
        else { u = 1.0 - uv.y; t = uv.x; }
        float base = 1.0 - clamp(u / max(p.leakWidth, 0.01), 0.0, 1.0);
        base = base * base;
        float n = latticeNoise(float2(t * 3.0 + p.leakSeed, 0.5), 77u) + 0.5;
        float shape = base * (0.55 + 0.45 * n);
        return float3(p.leakR, p.leakG, p.leakB) * (p.leakAmount * shape);
    }

    // ---- kernels ----

    kernel void vesper_expose(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant ExposeP& p [[buffer(0)]],
                              constant StampP& st [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float2 px = float2(gid) + 0.5;
        float2 uv = px / res;
        float3 c = srgbToLinear(src.read(gid).rgb) * float3(p.gainR, p.gainG, p.gainB);
        c += leakLight(uv, p);
        c += stampLight(px, res, st);
        c = min(c, float3(p.clampMax));
        dst.write(float4(c, 1.0), gid);
    }

    // Half resolution: exact 2x2 box of the linear scene, then the part of the
    // light that gets through the emulsion. Alpha keeps the unthresholded luma
    // for veiling glare.
    kernel void vesper_halo_source(texture2d<float, access::read> src [[texture(0)]],
                                   texture2d<float, access::write> dst [[texture(1)]],
                                   constant HaloP& p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        uint sw = src.get_width(), sh = src.get_height();
        uint x0 = min(gid.x * 2u, sw - 1u), x1 = min(gid.x * 2u + 1u, sw - 1u);
        uint y0 = min(gid.y * 2u, sh - 1u), y1 = min(gid.y * 2u + 1u, sh - 1u);
        float3 c = (src.read(uint2(x0, y0)).rgb + src.read(uint2(x1, y0)).rgb
                  + src.read(uint2(x0, y1)).rgb + src.read(uint2(x1, y1)).rgb) * 0.25;
        float Y = lumv(c);
        float e = softKnee(Y, p.threshold, p.knee);
        float3 glow = c * (e / max(Y, 1e-4)) * float3(p.tintR, p.tintG, p.tintB);
        dst.write(float4(glow, Y), gid);
    }

    kernel void vesper_down(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        uint sw = src.get_width(), sh = src.get_height();
        uint x0 = min(gid.x * 2u, sw - 1u), x1 = min(gid.x * 2u + 1u, sw - 1u);
        uint y0 = min(gid.y * 2u, sh - 1u), y1 = min(gid.y * 2u + 1u, sh - 1u);
        float4 c = (src.read(uint2(x0, y0)) + src.read(uint2(x1, y0))
                  + src.read(uint2(x0, y1)) + src.read(uint2(x1, y1))) * 0.25;
        dst.write(c, gid);
    }

    // Separable Gaussian with as many taps as the radius needs (capped), sigma
    // scaled per channel. Alpha is blurred with the unscaled sigma.
    kernel void vesper_blur(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant BlurP& p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float sigma = max(p.sigmaFrac * float(min(W, H)), 0.5);
        int R = min(int(ceil(sigma * 3.0)), int(p.maxRadius));
        int dx = int(p.dirX), dy = int(p.dirY);
        float3 inv2 = 1.0 / (2.0 * sigma * sigma * float3(p.scaleR * p.scaleR, p.scaleG * p.scaleG, p.scaleB * p.scaleB));
        float invA = 1.0 / (2.0 * sigma * sigma);
        float3 acc = float3(0.0);
        float3 wsum = float3(0.0);
        float accA = 0.0, wA = 0.0;
        int maxX = int(W) - 1, maxY = int(H) - 1;
        for (int i = -R; i <= R; i++) {
            int x = clamp(int(gid.x) + dx * i, 0, maxX);
            int y = clamp(int(gid.y) + dy * i, 0, maxY);
            float4 s = src.read(uint2(uint(x), uint(y)));
            float d2 = float(i * i);
            float3 w3 = exp(-d2 * inv2);
            float wa = exp(-d2 * invA);
            acc += s.rgb * w3;
            wsum += w3;
            accA += s.a * wa;
            wA += wa;
        }
        dst.write(float4(acc / wsum, accA / wA), gid);
    }

    // The film. Halation and glare are added to the linear scene, the shoulder
    // and the measured print curve shape the tones, the three zone tints and
    // the OKLab stage shape the color. Output is display linear.
    kernel void vesper_develop(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::sample> core [[texture(1)]],
                               texture2d<float, access::sample> aura [[texture(2)]],
                               texture2d<float, access::write> dst [[texture(3)]],
                               constant DevelopP& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 uv = (float2(gid) + 0.5) / float2(W, H);
        float3 c = src.read(gid).rgb;
        float4 hc = core.sample(smp, uv);
        float4 ha = aura.sample(smp, uv);
        c += hc.rgb * p.kCore + ha.rgb * (float3(p.auraR, p.auraG, p.auraB) * p.kAura);
        c += p.glare * ha.a;

        float mx = max(max(c.r, c.g), c.b);
        float wDesat = smoothstep(p.clipDesat0, p.clipDesat1, mx);
        float Yl = lumv(c);
        c = mix(c, float3(Yl), wDesat);
        c = float3(shoulder1(c.r, p.knee), shoulder1(c.g, p.knee), shoulder1(c.b, p.knee));
        c = max(c, float3(0.0));

        float3 e = linearToSrgb(c);
        e = float3(toneCurve(e.r), toneCurve(e.g), toneCurve(e.b));
        float3 inv = 1.0 - e;
        e += p.toeLift * inv * inv * inv;

        float L = lumv(e);
        float shW = 1.0 - smoothstep(0.10, 0.42, L);
        e += float3(p.shR, p.shG, p.shB) * shW;
        float dm = L - 0.58;
        float midW = exp(-dm * dm / 0.0968);
        e *= 1.0 + float3(p.midR, p.midG, p.midB) * midW;
        float hlW = smoothstep(0.70, 0.95, L);
        e *= 1.0 + float3(p.hlR, p.hlG, p.hlB) * hlW;
        e = clamp(e, 0.0, 1.0);

        float3 lin = srgbToLinear(e);
        float3 lab = linearToOklab(lin);
        float Lk = lab.x;
        float C = length(float2(lab.y, lab.z));
        float h = atan2(lab.z, lab.y) * 57.29578;
        if (h < 0.0) h += 360.0;
        float gate = smoothstep(p.chromaGate0, p.chromaGate1, C);
        float Cn = C * p.sat * (1.0 + p.vibrance * (1.0 - min(C / 0.35, 1.0)));

        float wSkin = gate * hueWeight(h, p.skinHue, p.skinSigma);
        h += wSkin * p.skinPull * wrapAngle(p.skinHue - h);
        Cn *= 1.0 - wSkin * (1.0 - p.skinChroma);
        Lk += wSkin * p.skinLift;

        float wFol = gate * hueWeight(h, p.folHue, p.folSigma);
        h += wFol * p.folShift;
        Cn *= 1.0 - wFol * (1.0 - p.folChroma);

        float wSky = gate * hueWeight(h, p.skyHue, p.skySigma);
        h += wSky * p.skyShift;
        Cn *= 1.0 + wSky * (p.skyChroma - 1.0);
        Lk -= wSky * p.skyDark * min(Cn / 0.2, 1.0);

        Lk -= p.density * Cn;
        Cn *= 1.0 - p.hlDesatAmt * smoothstep(p.hlDesatStart, 1.0, Lk);

        float hr = h * 0.017453292;
        float3 rgb = oklabToLinear(float3(Lk, Cn * cos(hr), Cn * sin(hr)));

        float Y = clamp(lumv(rgb), 0.0, 1.0);
        float t = 1.0;
        if (rgb.r > 1.0) t = min(t, (1.0 - Y) / max(rgb.r - Y, 1e-5));
        if (rgb.g > 1.0) t = min(t, (1.0 - Y) / max(rgb.g - Y, 1e-5));
        if (rgb.b > 1.0) t = min(t, (1.0 - Y) / max(rgb.b - Y, 1e-5));
        if (rgb.r < 0.0) t = min(t, Y / max(Y - rgb.r, 1e-5));
        if (rgb.g < 0.0) t = min(t, Y / max(Y - rgb.g, 1e-5));
        if (rgb.b < 0.0) t = min(t, Y / max(Y - rgb.b, 1e-5));
        rgb = Y + (rgb - Y) * clamp(t, 0.0, 1.0);
        dst.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
    }

    // Highlight diffusion and bloom on the developed image, in linear light.
    kernel void vesper_diffuse(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant DiffuseP& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float2 uv = (float2(gid) + 0.5) / res;
        float radiusPx = max(p.radiusMin, p.radiusFrac * min(res.x, res.y));
        float3 center = src.sample(smp, uv).rgb;
        float2 r1 = float2(radiusPx) / res;
        float2 r2 = r1 * 0.5;
        float2 r3 = r1 * 2.4;
        float3 low = center * 0.25;
        float3 wide = center * 0.2;
        float wsum = 0.25;
        for (int i = 0; i < 8; i++) {
            low += src.sample(smp, uv + RING8[i] * r2).rgb * 0.06;
            low += src.sample(smp, uv + RING8[i] * r1).rgb * 0.0325;
            wide += src.sample(smp, uv + RING8[i] * r3).rgb * 0.1;
            wsum += 0.06 + 0.0325;
        }
        low /= wsum;
        float hi = smoothstep(p.hiE0, p.hiE1, lumv(center));
        float3 outc = mix(center, low, hi * p.softAmt);
        float3 bloomSrc = wide * smoothstep(p.bloomE0, p.bloomE1, lumv(wide));
        outc = 1.0 - (1.0 - outc) * (1.0 - clamp(bloomSrc * p.bloomI, 0.0, 1.0));
        dst.write(float4(clamp(outc, 0.0, 1.0), 1.0), gid);
    }

    // The lens and the print: corner defocus and lateral CA, a natural vignette
    // in linear light, then the encode, the grain, and a dither.
    kernel void vesper_print(texture2d<float, access::sample> graded [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant PrintP& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float minDim = min(res.x, res.y);
        float2 uv = (float2(gid) + 0.5) / res;
        float2 ctr = uv - 0.5;
        float d = length(ctr) * 1.41421;

        float2 q = (float2(gid) + 0.5) - res * 0.5;
        float2 dirPx = length(q) > 1e-4 ? normalize(q) : float2(1, 0);
        float2 tanPx = float2(-dirPx.y, dirPx.x);

        float gate = smoothstep(p.onset, 1.0, d);
        float soft = p.softGlobal * minDim;
        float defo = p.defocusK * pow(gate, p.defocusP) * minDim;
        float sigR = soft + defo * p.aniso;
        float sigT = soft + defo / p.aniso;

        float2 axR = float2(0), axT = float2(0);
        if (max(sigR, sigT) > 0.08) {
            axR = dirPx * (2.0 * sigR) / res;
            axT = tanPx * (2.0 * sigT) / res;
        }

        float caGate = smoothstep(p.caOnset, 1.05, d);
        float caR = p.caK * pow(caGate, p.caP) * minDim;
        float caBv = p.caB * pow(caGate, p.caP) * minDim;
        float2 uvR = uv + dirPx * caR / res;
        float2 uvG = uv;
        float2 uvB = uv - dirPx * caBv / res;

        float3 col = defocusSample(graded, uvR, uvG, uvB, axR, axT);

        float vd = p.vigK * d;
        float falloff = 1.0 / ((1.0 + vd * vd) * (1.0 + vd * vd));
        float vig = mix(1.0, falloff, p.vigAmount) * (1.0 - p.vigMech * smoothstep(0.8, 1.2, d));
        col *= vig;

        float3 e = linearToSrgb(clamp(col, 0.0, 1.0));

        float gsize = max(p.grainSizeMin, minDim / max(p.grainDiv, 1.0));
        float2 fc = float2(gid) + 0.5;
        float2 gc = fc / gsize;
        uint s = uint(max(p.seed, 0.0) * 64.0);
        float nl = 0.75 * latticeNoise(gc, s) + 0.25 * latticeNoise(gc * 2.0, s + 11u);
        nl = mix(nl, hash01(gid.x, gid.y, s + 5u) - 0.5, p.grainSharp);
        float3 nc = float3(latticeNoise(gc, s + 101u), latticeNoise(gc, s + 202u), latticeNoise(gc, s + 303u));
        float Yp = lumv(e);
        float mid = 4.0 * Yp * (1.0 - Yp);
        float A = p.grainAmount * (p.grainFloor + (1.0 - p.grainFloor) * pow(max(mid, 0.0), p.grainMid));
        float3 n = nl + p.grainChroma * (nc - nl);
        n.b *= p.grainBlue;
        e += A * n;
        e += (hash01(gid.x, gid.y, s + 999u) - 0.5) * (p.dither / 255.0);

        dst.write(float4(clamp(e, 0.0, 1.0), 1.0), gid);
    }

    """
}
