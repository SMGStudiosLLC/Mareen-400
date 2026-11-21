import Foundation
import Metal
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// Marenn 400: a single-use camera loaded with 400 speed colour negative film.
//
// The pipeline follows the light. A photo is turned back into scene light, passed
// through a cheap moulded plastic lens, exposed onto film that glows and halates and
// grows grain, and finally printed through the measured Marenn tone and colour curve.
// Every stage lives in the Metal source at the bottom of this file.

enum MarennFilter {
    static let name = "Marenn 400"
    static let formerNames = ["Marenn XL", "gas filter"]

    #if canImport(UIKit)
    static func apply(to image: UIImage, options: MarennOptions = MarennOptions()) -> UIImage? {
        autoreleasepool {
            guard let cg = flatten(image),
                  let out = MarennEngine.shared?.process(cg, options: options) else { return nil }
            return UIImage(cgImage: out, scale: image.scale, orientation: .up)
        }
    }

    private static func flatten(_ image: UIImage) -> CGImage? {
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
    #endif
}

/// The camera's per-shot quirks. The look itself has no knobs.
struct MarennOptions {
    /// Fixes the grain field and the frame-to-frame character. nil rolls a new frame every time.
    var seed: UInt32? = nil
    /// Burns an orange seven-segment date imprint into the corner, like an old date back.
    var dateStamp: Date? = nil
    /// 0...1. A warm light leak bleeding in from the film door. Off unless asked for.
    var lightLeak: Float = 0
    /// 0...1. Small exposure and colour drift between frames, like a real roll printed by a lab.
    var frameVariation: Float = 1
    /// Develop without grain. Useful for tuning, not for photos.
    var grain: Bool = true

    init(seed: UInt32? = nil, dateStamp: Date? = nil, lightLeak: Float = 0,
         frameVariation: Float = 1, grain: Bool = true) {
        self.seed = seed
        self.dateStamp = dateStamp
        self.lightLeak = lightLeak
        self.frameVariation = frameVariation
        self.grain = grain
    }
}

/// Every uniform the kernels read, in one struct shared by all passes. The field
/// order must match `struct MarennParams` in the Metal source exactly (all floats).
/// Fields marked "per photo" are filled in by the engine; the rest are the look.
struct MarennParams {
    // frame, per photo
    var width: Float = 0
    var height: Float = 0
    var minDim: Float = 0
    var halfDiag: Float = 0
    var seed: Float = 0
    var gainR: Float = 1
    var gainG: Float = 1
    var gainB: Float = 1

    // plastic lens
    var distortion: Float = 0.012      // a hint of barrel (about 1%), corners kept in frame
    var vigAmount: Float = 0.72        // blend toward natural cos^4 falloff
    var vigTanHalfFov: Float = 0.676   // 32 mm lens on a 36 x 24 mm frame
    var vigMech: Float = 0.10          // extra darkening right in the corners
    var softGlobal: Float = 0.00042    // overall softness, sigma as a fraction of the short side
    var onset: Float = 0.25            // where field curvature starts to bite
    var defocusK: Float = 0.00080
    var defocusP: Float = 1.80
    var aniso: Float = 2.60            // radial vs tangential smear (astigmatism)
    var coma: Float = 0.12             // outward comet tail on corner highlights
    var axialR: Float = 1.10           // axial colour: red and blue focus behind green
    var axialB: Float = 1.45
    var caOnset: Float = 0.30          // lateral colour
    var caK: Float = 0.00085
    var caB: Float = 0.00095
    var caP: Float = 1.25
    var hiBoost: Float = 1.5           // clipped light sources glow like the bright things they were
    var exposure: Float = 0.92         // linear trim so the optics land on the measured print density
    var dimWarmth: Float = 0.06        // film has no white balance: lamp-lit dim scenes go amber

    // halation, veiling glare, highlight diffusion
    var halThreshold: Float = 0.55
    var halKnee: Float = 0.25
    var halIntensity: Float = 0.12
    var halR: Float = 1.00
    var halG: Float = 0.40
    var halB: Float = 0.14
    var veilAmount: Float = 0.028
    var bloomI: Float = 0.10           // measured print bloom: highlights glow into their surroundings
    var warmGlow: Float = 0.18         // measured warm glow of bright areas on the print
    var softAmt: Float = 0.45
    var hiE0: Float = 0.42
    var hiE1: Float = 0.80

    // grain
    var grainAmount: Float = 0.022     // std before the print curve, for a 3024 px short side
    var grainSigma: Float = 0.85       // dye cloud size in px at a 3024 px short side
    var grainRadius: Float = 2         // per photo
    var grainNorm: Float = 1           // per photo
    var mottleCell: Float = 6          // per photo
    var mottleSigma: Float = 3.6       // per photo
    var mottleNorm: Float = 1          // per photo
    var mottleMix: Float = 0.10        // share of low frequency clumping
    var grainChroma: Float = 0.05      // share of independent per-layer grain, the rest is shared
    var grainR: Float = 1.00
    var grainG: Float = 0.92
    var grainB: Float = 1.15           // the blue sensitive layer is the coarsest
    var grainPush: Float = 0           // per photo, extra shadow grain for dim scenes

    // print: the measured Marenn grade
    var satGlobal: Float = 1.17000
    var blueSatK: Float = 1.45000
    var blueSatT0: Float = 0.3800
    var blueSatT1: Float = 0.6141
    var blueDark: Float = 0.33000
    var blueHue: Float = -0.15000

    // date imprint and light leak, per photo
    var stampOn: Float = 0
    var stampSize: Float = 0.030
    var stampD0: Float = 0
    var stampD1: Float = 0
    var stampD2: Float = 0
    var stampD3: Float = 0
    var stampD4: Float = 0
    var stampD5: Float = 0
    var leakAmount: Float = 0
    var leakX: Float = 1
    var leakY: Float = 0.3
    var leakSpread: Float = 0.35

    var dither: Float = 1
}

struct SceneStats {
    var p50: Float
    var meanLuma: Float
    var hiFrac: Float
}

final class MarennEngine {
    static let shared = MarennEngine()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lensPSO: MTLComputePipelineState
    private let extractPSO: MTLComputePipelineState
    private let downPSO: MTLComputePipelineState
    private let upPSO: MTLComputePipelineState
    private let filmPSO: MTLComputePipelineState
    private let lock = NSLock()

    /// Replace the look for experiments. Per photo fields are still filled in by the engine.
    var paramsOverride: MarennParams?
    /// The parameters the last photo was developed with, for diagnostics.
    private(set) var lastParams: MarennParams?
    var expRef: Float = 0.37000
    var expPow: Float = 0.45

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: MarennEngine.source, options: nil)
            func pso(_ name: String) throws -> MTLComputePipelineState {
                guard let fn = library.makeFunction(name: name) else { throw MarennError.missingFunction }
                return try device.makeComputePipelineState(function: fn)
            }
            self.device = device
            self.queue = queue
            self.lensPSO = try pso("marenn_lens")
            self.extractPSO = try pso("marenn_extract")
            self.downPSO = try pso("marenn_down")
            self.upPSO = try pso("marenn_up")
            self.filmPSO = try pso("marenn_film")
        } catch {
            return nil
        }
    }

    enum MarennError: Error { case missingFunction }

    func process(_ image: CGImage, options: MarennOptions = MarennOptions()) -> CGImage? {
        guard let source = bake(image) else { return nil }
        let w = source.width, h = source.height
        guard w > 1, h > 1 else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let stats = sceneStats(source)
        var p = MarennEngine.frameParams(base: paramsOverride ?? MarennParams(), width: w, height: h,
                                         stats: stats, options: options,
                                         encodedGain: exposureGain(stats))
        lastParams = p

        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let srcTex = makeTexture(w, h, .rgba16Float, [.shaderRead], cpu: true),
              let lensTex = makeTexture(w, h, .rgba16Float, rw, cpu: false),
              let outTex = makeTexture(w, h, .rgba8Unorm, rw, cpu: true) else { return nil }

        // glow pyramid: L[0] is half resolution, each level halves again
        let sizes = MarennEngine.pyramidSizes(w, h)
        var levels: [MTLTexture] = []
        var ups: [MTLTexture] = []
        for (i, s) in sizes.enumerated() {
            guard let t = makeTexture(s.0, s.1, .rgba16Float, rw, cpu: false) else { return nil }
            levels.append(t)
            if i < sizes.count - 1 {
                guard let u = makeTexture(s.0, s.1, .rgba16Float, rw, cpu: false) else { return nil }
                ups.append(u)
            }
        }

        source.pixels.withUnsafeBytes { buf in
            srcTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                           withBytes: buf.baseAddress!, bytesPerRow: w * 8)
        }

        guard let cmd = queue.makeCommandBuffer() else { return nil }
        let plen = MemoryLayout<MarennParams>.stride

        // 1. lens: scene light through the plastic lens onto the film plane
        encode(cmd, lensPSO, w, h, textures: [srcTex, lensTex]) { $0.setBytes(&p, length: plen, index: 0) }

        // 2. glow pyramid down
        encode(cmd, extractPSO, sizes[0].0, sizes[0].1, textures: [lensTex, levels[0]]) {
            $0.setBytes(&p, length: plen, index: 0)
        }
        for i in 1..<levels.count {
            encode(cmd, downPSO, sizes[i].0, sizes[i].1, textures: [levels[i - 1], levels[i]]) { _ in }
        }

        // 3. glow pyramid up, folding in each level with its veil (rgb) and halation (a) weight
        let weights = MarennEngine.glowWeights(levelCount: levels.count)
        var coarse = levels[levels.count - 1]
        var coarseScale = weights[levels.count - 1]
        for i in stride(from: levels.count - 2, through: 0, by: -1) {
            var fineW = weights[i]
            var cs = coarseScale
            encode(cmd, upPSO, sizes[i].0, sizes[i].1, textures: [coarse, levels[i], ups[i]]) { enc in
                enc.setBytes(&cs, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.setBytes(&fineW, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            }
            coarse = ups[i]
            coarseScale = SIMD4<Float>(repeating: 1)
        }
        let glow = ups.isEmpty ? levels[0] : ups[0]
        // the print bloom wants a blur of about 1/80 of the frame: fourth level from the top
        let bloomLevel = levels[max(0, levels.count - 4)]

        // 4. film: halation, veil, grain, print
        encode(cmd, filmPSO, w, h, textures: [lensTex, glow, bloomLevel, outTex]) {
            $0.setBytes(&p, length: plen, index: 0)
        }

        #if os(macOS)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: outTex)
            blit.endEncoding()
        }
        #endif

        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }

        return readBack(outTex)
    }

    // MARK: per photo parameters

    /// Everything that depends on the photo rather than the look. Mirrored by the CPU
    /// harness in Tools/cpu/marenn_cpu.cpp, keep the two in step.
    static func frameParams(base: MarennParams, width w: Int, height h: Int, stats: SceneStats,
                            options: MarennOptions, encodedGain: Float) -> MarennParams {
        var p = base
        p.width = Float(w)
        p.height = Float(h)
        p.minDim = Float(min(w, h))
        p.halfDiag = 0.5 * (Float(w * w + h * h)).squareRoot()

        var rng = MarennRNG(seed: options.seed ?? UInt32.random(in: 0..<UInt32.max))
        p.seed = Float(rng.next() & 0xFFFF)

        // exposure: the measured gain lives in encoded space, the lens works in light
        let v = max(0, min(1, options.frameVariation))
        let expDrift = (rng.unit() * 2 - 1) * 0.10 * v           // +-0.1 stop
        let warmDrift = (rng.unit() * 2 - 1) * 0.018 * v         // lab printing colour drift
        let tintDrift = (rng.unit() * 2 - 1) * 0.010 * v
        let g = powf(encodedGain, 2.2) * powf(2, expDrift) * base.exposure
        // dim frames were lit by lamps the film never balanced for
        let dim = max(0, min(1, (0.30 - stats.p50) / 0.20))
        let amber = base.dimWarmth * dim
        p.gainR = g * (1 + warmDrift) * (1 + amber)
        p.gainG = g * (1 + tintDrift) * (1 + 0.25 * amber)
        p.gainB = g * (1 - warmDrift) * (1 - 1.2 * amber)

        // grain: sized to the frame, so a preview and a full capture look alike on screen
        let scale = p.minDim / 3024
        let sigmaRaw = base.grainSigma * scale
        let sigma = max(0.6, sigmaRaw)
        p.grainSigma = sigma
        p.grainRadius = Float(max(1, min(3, Int(ceilf(2.5 * sigma)))))
        let r = Int(p.grainRadius)
        var sum2: Float = 0
        for dy in -r...r {
            for dx in -r...r {
                let wgt = expf(-Float(dx * dx + dy * dy) / (2 * sigma * sigma))
                sum2 += wgt * wgt
            }
        }
        // A pixel shows the grain integrated over its area. When a dye cloud is smaller than
        // a pixel it is drawn at pixel size, scaled so the pixel-integrated deviation matches
        // the real cloud's. Previews and full captures then look the same on a screen.
        p.grainNorm = pixelIntegral(sigmaRaw) / pixelIntegral(sigma) / (sum2 / 3).squareRoot()
        let mottleRaw = 3 * sigmaRaw
        p.mottleCell = max(2, (mottleRaw / 0.6).rounded())
        p.mottleSigma = 0.6 * p.mottleCell
        p.mottleNorm = pixelIntegral(mottleRaw) / pixelIntegral(p.mottleSigma)
            / (Float.pi * p.mottleSigma * p.mottleSigma / (3 * p.mottleCell * p.mottleCell)).squareRoot()
        p.grainAmount = options.grain ? base.grainAmount : 0
        // dim scenes were underexposed on the real roll, the lab printed them up, grain came along
        p.grainPush = dim

        if let date = options.dateStamp {
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
            let yy = (c.year ?? 2000) % 100, mm = c.month ?? 1, dd = c.day ?? 1
            p.stampOn = 1
            p.stampD0 = Float(yy / 10); p.stampD1 = Float(yy % 10)
            p.stampD2 = Float(mm / 10); p.stampD3 = Float(mm % 10)
            p.stampD4 = Float(dd / 10); p.stampD5 = Float(dd % 10)
        }

        let leak = max(0, min(1, options.lightLeak))
        let side: Float = rng.unit() < 0.5 ? 0 : 1
        let along = 0.15 + 0.7 * rng.unit()
        p.leakAmount = leak
        // the leak enters from the left or right edge, somewhere along its length
        p.leakX = side
        p.leakY = along
        p.leakSpread = 0.25 + 0.2 * rng.unit()
        return p
    }

    /// Standard deviation left after averaging a gaussian-correlated field of correlation
    /// sigma (in px) over a 1 px box, per axis: sqrt of the double integral of the correlation.
    static func pixelIntegral(_ sigma: Float) -> Float {
        let a = Double(4 * sigma * sigma)
        let i0 = (Double.pi * a).squareRoot() / 2 * erf(1 / a.squareRoot())
        let i1 = a / 2 * (1 - exp(-1 / a))
        return Float(2 * (i0 - i1))
    }

    /// Half resolution down to roughly 16 px on the short side.
    static func pyramidSizes(_ w: Int, _ h: Int) -> [(Int, Int)] {
        var sizes: [(Int, Int)] = []
        var cw = max(1, (w + 1) / 2), ch = max(1, (h + 1) / 2)
        sizes.append((cw, ch))
        while min(cw, ch) >= 32 && sizes.count < 8 {
            cw = max(1, (cw + 1) / 2)
            ch = max(1, (ch + 1) / 2)
            sizes.append((cw, ch))
        }
        return sizes
    }

    /// Per level weights (rgb: veiling glare, a: halation), counted from the coarsest level
    /// so the glow keeps the same size relative to the frame at any resolution.
    static func glowWeights(levelCount n: Int) -> [SIMD4<Float>] {
        let veilTop: [Float] = [0.34, 0.28, 0.18, 0.10, 0.06, 0.04, 0, 0]
        let halTop: [Float] = [0.02, 0.06, 0.16, 0.30, 0.28, 0.18, 0, 0]
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        var vs: Float = 0, hs: Float = 0
        for i in 0..<n {
            let t = n - 1 - i
            vs += veilTop[t]
            hs += halTop[t]
        }
        for i in 0..<n {
            let t = n - 1 - i
            let v = vs > 0 ? veilTop[t] / vs : 0
            let a = hs > 0 ? halTop[t] / hs : 0
            out[i] = SIMD4<Float>(v, v, v, a)
        }
        return out
    }

    // MARK: Metal plumbing

    private func encode(_ cmd: MTLCommandBuffer, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int,
                        textures: [MTLTexture], _ uniforms: (MTLComputeCommandEncoder) -> Void) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        uniforms(enc)
        // heavy kernels can get a lower thread limit on some GPUs, so size from the pipeline
        let tw = max(1, pso.threadExecutionWidth)
        let th = max(1, min(8, pso.maxTotalThreadsPerThreadgroup / tw))
        let tg = MTLSize(width: tw, height: th, depth: 1)
        let groups = MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func makeTexture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, _ usage: MTLTextureUsage,
                             cpu: Bool) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        desc.usage = usage
        #if os(macOS)
        desc.storageMode = cpu ? .managed : .private
        #else
        desc.storageMode = cpu ? .shared : .private
        #endif
        return device.makeTexture(descriptor: desc)
    }

    private func exposureGain(_ s: SceneStats) -> Float {
        let raw = powf(expRef / max(s.p50, 0.05), expPow)
        return max(0.85, min(1.20, raw))
    }

    /// Statistics on display-encoded values, as the measured exposure model expects.
    /// Mirrored by scene_stats() in Tools/cpu/marenn_cpu.cpp.
    private func sceneStats(_ baked: Baked) -> SceneStats {
        let px = baked.pixels
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
            let r = MarennEngine.encodeSRGB(MarennEngine.halfToFloat(px[p]))
            let g = MarennEngine.encodeSRGB(MarennEngine.halfToFloat(px[p + 1]))
            let b = MarennEngine.encodeSRGB(MarennEngine.halfToFloat(px[p + 2]))
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

    /// RGBA half floats in extended linear sRGB. Wide gamut (Display P3) colours keep
    /// their values outside 0...1 instead of being clipped on the way in.
    private struct Baked { let pixels: [UInt16]; let width: Int; let height: Int }

    private func bake(_ cg: CGImage) -> Baked? {
        let w = cg.width, h = cg.height
        guard w >= 1, h >= 1, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        var pixels = [UInt16](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 16,
                                      bytesPerRow: w * 8, space: space, bitmapInfo: info) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Baked(pixels: pixels, width: w, height: h) : nil
    }

    private func readBack(_ texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func halfToFloat(_ h: UInt16) -> Float {
        let sign: UInt32 = UInt32(h & 0x8000) << 16
        let exponent = Int((h >> 10) & 0x1F)
        let mantissa = UInt32(h & 0x3FF)
        if exponent == 0 {
            let v = Float(mantissa) * (1.0 / 16_777_216.0)
            return sign != 0 ? -v : v
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | (UInt32(exponent + 112) << 23) | (mantissa << 13))
    }

    static func encodeSRGB(_ linear: Float) -> Float {
        let c = max(0, min(1, linear))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ------------------------------------------------------------------------------
    // shared
    // ------------------------------------------------------------------------------

    struct MarennParams {
        float width, height, minDim, halfDiag;
        float seed, gainR, gainG, gainB;
        float distortion, vigAmount, vigTanHalfFov, vigMech;
        float softGlobal, onset, defocusK, defocusP;
        float aniso, coma, axialR, axialB;
        float caOnset, caK, caB, caP;
        float hiBoost, exposure, dimWarmth;
        float halThreshold, halKnee, halIntensity, halR, halG, halB;
        float veilAmount, bloomI, warmGlow, softAmt, hiE0, hiE1;
        float grainAmount, grainSigma, grainRadius, grainNorm;
        float mottleCell, mottleSigma, mottleNorm, mottleMix;
        float grainChroma, grainR, grainG, grainB;
        float grainPush;
        float satGlobal, blueSatK, blueSatT0, blueSatT1, blueDark, blueHue;
        float stampOn, stampSize, stampD0, stampD1, stampD2, stampD3, stampD4, stampD5;
        float leakAmount, leakX, leakY, leakSpread;
        float dither;
    };

    constant float3 LW = float3(0.2126, 0.7152, 0.0722);
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    inline float lumv(float3 c) { return dot(c, LW); }
    inline float maxc(float3 c) { return max(max(c.r, c.g), c.b); }

    inline float encode1(float c) {
        c = max(c, 0.0);
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }
    inline float3 encodeSRGB(float3 c) { return float3(encode1(c.r), encode1(c.g), encode1(c.b)); }

    // PCG4D (Jarzynski and Olano 2020). Four independent uniform values per call,
    // no lattice, no visible structure at any scale.
    inline uint4 pcg4d(uint4 v) {
        v = v * 1664525u + 1013904223u;
        v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
        v ^= v >> 16u;
        v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
        return v;
    }
    inline float4 rand4(int2 p, uint seed, uint layer) {
        uint4 h = pcg4d(uint4(uint(p.x), uint(p.y), seed, layer));
        return float4(h >> 8u) * (1.0 / 16777216.0);
    }

    // ------------------------------------------------------------------------------
    // 1. lens
    // A 32 mm f/10 single element plastic lens. Works in linear light so blur and
    // glow behave like light does.
    // ------------------------------------------------------------------------------

    // 24 tap Vogel disc, radius 2 sigma, xy offset and gaussian weight
    constant float3 VOGEL[24] = {
        float3(0.28868, 0.00000, 0.95919), float3(-0.36868, 0.33775, 0.88250), float3(0.05643, -0.64303, 0.81194),
        float3(0.46470, 0.60612, 0.74702), float3(-0.85279, -0.15085, 0.68729), float3(0.80783, -0.51388, 0.63234),
        float3(-0.27020, 1.00515, 0.58178), float3(-0.51531, -0.99220, 0.53526), float3(1.11802, 0.40830, 0.49246),
        float3(-1.16311, 0.48011, 0.45309), float3(0.56070, -1.19817, 0.41686), float3(0.41434, 1.32098, 0.38353),
        float3(-1.24882, -0.72372, 0.35287), float3(1.46501, -0.32208, 0.32465), float3(-0.89408, 1.27173, 0.29869),
        float3(-0.20655, -1.59395, 0.27481), float3(1.26803, 1.06869, 0.25284), float3(-1.70637, 0.07056, 0.23262),
        float3(1.24466, -1.23861, 0.21402), float3(-0.08327, 1.80085, 0.19691), float3(-1.18430, -1.41919, 0.18117),
        float3(1.87606, 0.25242, 0.16668), float3(-1.58959, 1.10599, 0.15335), float3(0.43437, -1.93080, 0.14109)
    };

    // seven segment glyphs: a b c d e f g = bits 0..6
    constant int SEGMASK[10] = {0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F};

    inline float capsule(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    // distance to a digit drawn in a 0.5 x 1.0 box, y up
    inline float digitDist(float2 p, int d) {
        int m = SEGMASK[clamp(d, 0, 9)];
        float r = 1e3;
        if ((m & 1) != 0)  r = min(r, capsule(p, float2(0.10, 1.00), float2(0.40, 1.00)));
        if ((m & 2) != 0)  r = min(r, capsule(p, float2(0.50, 0.90), float2(0.50, 0.60)));
        if ((m & 4) != 0)  r = min(r, capsule(p, float2(0.50, 0.40), float2(0.50, 0.10)));
        if ((m & 8) != 0)  r = min(r, capsule(p, float2(0.10, 0.00), float2(0.40, 0.00)));
        if ((m & 16) != 0) r = min(r, capsule(p, float2(0.00, 0.40), float2(0.00, 0.10)));
        if ((m & 32) != 0) r = min(r, capsule(p, float2(0.00, 0.90), float2(0.00, 0.60)));
        if ((m & 64) != 0) r = min(r, capsule(p, float2(0.10, 0.50), float2(0.40, 0.50)));
        return r;
    }

    // the date back's LEDs expose the film from behind: light, not ink
    inline float dateStamp(float2 px, constant MarennParams& P) {
        float H = P.stampSize * P.minDim;
        float2 origin = float2(P.width - P.minDim * 0.05, P.height - P.minDim * 0.045);
        float2 q = (px - origin) / H;
        q.y = -q.y;
        q.x += 6.05;                      // the stamp is about six digit heights wide
        q.x -= q.y * 0.14;                // slanted, like the old LCD date backs
        if (q.x < -0.3 || q.x > 6.4 || q.y < -0.3 || q.y > 1.3) return 0.0;
        float d = 1e3;
        d = min(d, capsule(q, float2(0.10, 1.00), float2(0.04, 0.78)));   // apostrophe
        float x = 0.35;
        float digits[6] = {P.stampD0, P.stampD1, P.stampD2, P.stampD3, P.stampD4, P.stampD5};
        for (int i = 0; i < 6; i++) {
            d = min(d, digitDist(q - float2(x, 0.0), int(digits[i] + 0.5)));
            x += (i % 2 == 1) ? 1.30 : 0.72;
        }
        float stroke = 0.075;
        float aa = 0.6 / H + 0.035;
        return 1.0 - smoothstep(stroke - aa, stroke + aa, d);
    }

    kernel void marenn_lens(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant MarennParams& P [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float2 centre = res * 0.5;
        float2 pc = float2(gid) + 0.5 - centre;
        float r = length(pc) / P.halfDiag;
        float2 dir = r > 1e-5 ? normalize(pc) : float2(1.0, 0.0);
        float2 tng = float2(-dir.y, dir.x);

        // barrel distortion, scaled so the corners stay in frame
        float2 ps = pc * (1.0 + P.distortion * r * r) / (1.0 + P.distortion);

        // field curvature and astigmatism: sharp middle, smeared corners
        float gate = smoothstep(P.onset, 1.0, r);
        float soft = P.softGlobal * P.minDim;
        float defo = P.defocusK * pow(gate, P.defocusP) * P.minDim;
        float sigR = soft + defo * P.aniso;
        float sigT = soft + defo / P.aniso;

        // lateral colour: red and blue land at slightly different magnifications
        float caGate = pow(smoothstep(P.caOnset, 1.05, r), P.caP);
        float shR = P.caK * caGate * P.minDim;
        float shB = -P.caB * caGate * P.minDim;

        // rotating the tap pattern per pixel trades ghosting for fine noise the grain hides
        float rot = 6.2831853 * fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
        float cr = cos(rot), sr = sin(rot);

        float3 acc = float3(0.0);
        float wsum = 0.0;
        for (int i = 0; i < 24; i++) {
            float3 t = VOGEL[i];
            float2 u = float2(t.x * cr - t.y * sr, t.x * sr + t.y * cr);
            float2 o = dir * (u.x * sigR + P.coma * dot(u, u) * sigR) + tng * (u.y * sigT);
            float2 pR = centre + ps + dir * shR + o * P.axialR;
            float2 pG = centre + ps + o;
            float2 pB = centre + ps + dir * shB + o * P.axialB;
            acc += t.z * float3(src.sample(smp, pR / res).r, src.sample(smp, pG / res).g, src.sample(smp, pB / res).b);
            wsum += t.z;
        }
        float3 col = acc / wsum;

        // clipped areas were brighter than the sensor could say, let them glow like it
        float clip = smoothstep(0.82, 1.0, maxc(col));
        float boost = 1.0 + P.hiBoost * clip * clip;

        // natural cos^4 falloff of a wide simple lens, plus the barrel's mechanical vignetting
        float tanT = r * P.vigTanHalfFov;
        float cos2 = 1.0 / (1.0 + tanT * tanT);
        float vig = mix(1.0, cos2 * cos2, P.vigAmount) * (1.0 - P.vigMech * smoothstep(0.75, 1.1, r));

        float3 lin = col * vig * float3(P.gainR, P.gainG, P.gainB);
        // halation is light that crossed the whole emulsion and bounced off the base, so it is
        // driven mostly by red, which reaches the bottom layer, and it exposes that red layer
        float glowSrc = dot(lin, float3(0.60, 0.32, 0.08)) * boost;

        if (P.stampOn > 0.5) {
            float s = dateStamp(float2(gid) + 0.5, P);
            float3 led = mix(float3(1.0, 0.20, 0.02), float3(1.0, 0.55, 0.12), s * s) * 1.4;
            lin += led * s;
            glowSrc += lumv(led) * s * 2.5;
        }

        if (P.leakAmount > 0.0) {
            float2 q = (float2(gid) + 0.5) / P.minDim;
            float2 o = float2(P.leakX * P.width, P.leakY * P.height) / P.minDim;
            float2 d = q - o;
            d.y *= 0.45;                                   // stretched along the edge
            float f = exp(-dot(d, d) / (P.leakSpread * P.leakSpread));
            float3 hot = mix(float3(0.9, 0.10, 0.01), float3(1.0, 0.62, 0.20), f * f);
            float3 leak = hot * f * P.leakAmount * 1.6;
            lin += leak;
            glowSrc += lumv(leak);
        }

        dst.write(float4(lin, glowSrc), gid);
    }

    // ------------------------------------------------------------------------------
    // 2. glow pyramid
    // rgb carries the whole image for veiling glare, a carries the halation source.
    // ------------------------------------------------------------------------------

    // soft knee above the halation threshold
    inline float halKnee(float a, constant MarennParams& P) {
        float x = a - P.halThreshold;
        float k = P.halKnee;
        float kv = clamp(x + k, 0.0, 2.0 * k);
        return max(x, kv * kv / (4.0 * k + 1e-5));
    }

    kernel void marenn_extract(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant MarennParams& P [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float2 ts = 1.0 / float2(src.get_width(), src.get_height());
        float4 c = 0.25 * (src.sample(smp, uv + ts * float2(-1.0, -1.0)) + src.sample(smp, uv + ts * float2(1.0, -1.0))
                         + src.sample(smp, uv + ts * float2(-1.0, 1.0)) + src.sample(smp, uv + ts * float2(1.0, 1.0)));
        dst.write(float4(c.rgb, halKnee(c.a, P)), gid);
    }

    // 13 tap downsample (Jimenez 2014), smooth and free of the blocky look of a box filter
    kernel void marenn_down(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float4 a = src.sample(smp, uv + t * float2(-2.0, -2.0));
        float4 b = src.sample(smp, uv + t * float2(0.0, -2.0));
        float4 c = src.sample(smp, uv + t * float2(2.0, -2.0));
        float4 d = src.sample(smp, uv + t * float2(-2.0, 0.0));
        float4 e = src.sample(smp, uv);
        float4 f = src.sample(smp, uv + t * float2(2.0, 0.0));
        float4 g = src.sample(smp, uv + t * float2(-2.0, 2.0));
        float4 h = src.sample(smp, uv + t * float2(0.0, 2.0));
        float4 i = src.sample(smp, uv + t * float2(2.0, 2.0));
        float4 j = src.sample(smp, uv + t * float2(-1.0, -1.0));
        float4 k = src.sample(smp, uv + t * float2(1.0, -1.0));
        float4 l = src.sample(smp, uv + t * float2(-1.0, 1.0));
        float4 m = src.sample(smp, uv + t * float2(1.0, 1.0));
        float4 o = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
        dst.write(o, gid);
    }

    // tent upsample of the coarser level plus this level's weighted contribution
    kernel void marenn_up(texture2d<float, access::sample> coarse [[texture(0)]],
                          texture2d<float, access::sample> fine [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          constant float4& coarseScale [[buffer(0)]],
                          constant float4& fineWeight [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        float2 t = 1.0 / float2(coarse.get_width(), coarse.get_height());
        float4 s = coarse.sample(smp, uv) * 4.0;
        s += (coarse.sample(smp, uv + t * float2(-1.0, 0.0)) + coarse.sample(smp, uv + t * float2(1.0, 0.0))
            + coarse.sample(smp, uv + t * float2(0.0, -1.0)) + coarse.sample(smp, uv + t * float2(0.0, 1.0))) * 2.0;
        s += coarse.sample(smp, uv + t * float2(-1.0, -1.0)) + coarse.sample(smp, uv + t * float2(1.0, -1.0))
           + coarse.sample(smp, uv + t * float2(-1.0, 1.0)) + coarse.sample(smp, uv + t * float2(1.0, 1.0));
        float4 o = s * (1.0 / 16.0) * coarseScale + fine.read(gid) * fineWeight;
        dst.write(o, gid);
    }

    // ------------------------------------------------------------------------------
    // 3. film and print
    // ------------------------------------------------------------------------------

    constant float2 RING8[8] = {
        float2(1.0, 0.0), float2(0.70711, 0.70711), float2(0.0, 1.0), float2(-0.70711, 0.70711),
        float2(-1.0, 0.0), float2(-0.70711, -0.70711), float2(0.0, -1.0), float2(0.70711, -0.70711)
    };

    // measured print curve and tints (unchanged from Marenn 400 v1)
    constant float KX[7] = {0.0, 0.05, 0.15, 0.30, 0.50, 0.72, 1.0};
    constant float KY[7] = {0.04997, 0.08906, 0.19790, 0.37006, 0.54963, 0.77005, 0.92492};
    constant float KM[7] = {0.70753, 0.87665, 1.16177, 1.02403, 0.95497, 0.66508, 0.32555};
    constant float3 SHADOW_TINT = float3(-0.01785, 0.00481, 0.01304);
    constant float3 MID_WARM = float3(0.01200, 0.01200, -0.02400);
    constant float3 HL_WARM = float3(0.05777, -0.00631, -0.05146);

    inline float toneCurve(float x) {
        x = clamp(x, 0.0, 1.0);
        int i = 0;
        for (int k = 5; k >= 1; k--) { if (x >= KX[k]) { i = k; break; } }
        float h = KX[i + 1] - KX[i];
        float t = (x - KX[i]) / h;
        float t2 = t * t, t3 = t2 * t;
        return (2.0 * t3 - 3.0 * t2 + 1.0) * KY[i] + (t3 - 2.0 * t2 + t) * h * KM[i]
             + (-2.0 * t3 + 3.0 * t2) * KY[i + 1] + (t3 - t2) * h * KM[i + 1];
    }

    inline float3 hueRotate(float3 c, float ang) {
        float ca = cos(ang), sa = sin(ang);
        const float third = 1.0 / 3.0;
        float sq = sqrt(third);
        float k = 1.0 - ca;
        float3x3 m = float3x3(
            float3(ca + k * third, third * k + sq * sa, third * k - sq * sa),
            float3(third * k - sq * sa, ca + third * k, third * k + sq * sa),
            float3(third * k + sq * sa, third * k - sq * sa, ca + third * k));
        return m * c;
    }

    inline float3 grade(float3 c, constant MarennParams& P) {
        c = float3(toneCurve(c.r), toneCurve(c.g), toneCurve(c.b));
        float L = lumv(c);
        float shW = 1.0 - smoothstep(0.10, 0.42, L);
        c += SHADOW_TINT * shW;
        float dm = L - 0.58;
        float midW = exp(-dm * dm / 0.0968);
        c *= 1.0 + MID_WARM * midW;
        float hlW = smoothstep(0.70, 0.95, L);
        c *= 1.0 + HL_WARM * hlW;
        float L2 = lumv(c);
        c = L2 + (c - L2) * P.satGlobal;
        float mx = maxc(c), mn = min(min(c.r, c.g), c.b);
        float s = (mx - mn) / (mx + 1e-4);
        float wb = clamp((c.b - max(c.r, c.g)) / (mx - mn + 1e-4), 0.0, 1.0);
        float boost = P.blueSatK * smoothstep(P.blueSatT0, P.blueSatT1, s)
                    - 0.05 * (1.0 - smoothstep(0.30, P.blueSatT0, s));
        float kk = wb * boost;
        float L3 = lumv(c);
        c = L3 + (c - L3) * (1.0 + kk);
        c *= 1.0 - P.blueDark * clamp(kk, 0.0, 1.0);
        float hw = wb * smoothstep(0.35, 0.65, s);
        return hueRotate(c, P.blueHue * hw);
    }

    // Film grain as gaussian filtered white noise: the gaussian limit of the boolean
    // grain model (Newson et al. 2017). Fine dye clouds on the pixel lattice plus
    // jittered sparse clumps, one shared (luminance) field and three per-layer fields.
    inline float4 grainField(int2 ip, constant MarennParams& P) {
        uint seed = uint(P.seed);
        int R = int(P.grainRadius);
        float inv2s2 = 1.0 / (2.0 * P.grainSigma * P.grainSigma);
        float4 fine = float4(0.0);
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                float w = exp(-float(dx * dx + dy * dy) * inv2s2);
                fine += w * (rand4(ip + int2(dx, dy), seed, 0u) * 2.0 - 1.0);
            }
        }
        fine *= P.grainNorm;

        float C = P.mottleCell;
        float2 pf = (float2(ip) + 0.5) / C;
        int2 cell = int2(floor(pf));
        float inv2m = 1.0 / (2.0 * (P.mottleSigma / C) * (P.mottleSigma / C));
        float4 mot = float4(0.0);
        for (int cy = -2; cy <= 2; cy++) {
            for (int cx = -2; cx <= 2; cx++) {
                int2 c = cell + int2(cx, cy);
                float4 j = rand4(c, seed, 1u);
                float2 d = pf - (float2(c) + j.xy);
                float w = exp(-dot(d, d) * inv2m);
                mot += w * (rand4(c, seed, 2u) * 2.0 - 1.0);
            }
        }
        mot *= P.mottleNorm;

        float4 g = fine * sqrt(1.0 - P.mottleMix) + mot * sqrt(P.mottleMix);
        float ind = sqrt(P.grainChroma), sh = sqrt(1.0 - P.grainChroma);
        return float4(g.w * sh + g.x * ind, g.w * sh + g.y * ind, g.w * sh + g.z * ind, g.w);
    }

    kernel void marenn_film(texture2d<float, access::sample> lens [[texture(0)]],
                            texture2d<float, access::sample> glow [[texture(1)]],
                            texture2d<float, access::sample> bloom [[texture(2)]],
                            texture2d<float, access::write> dst [[texture(3)]],
                            constant MarennParams& P [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float2 res = float2(W, H);
        float2 uv = (float2(gid) + 0.5) / res;

        // highlight diffusion: bright areas melt a little into their surroundings
        float4 lensC = lens.sample(smp, uv);
        float3 e = lensC.rgb;
        float2 r1 = float2(max(1.5, P.minDim / 189.0)) / res;
        float2 r2 = r1 * 0.5;
        float3 low = e * 0.25;
        float wsum = 0.25;
        for (int i = 0; i < 8; i++) {
            low += lens.sample(smp, uv + RING8[i] * r2).rgb * 0.06;
            low += lens.sample(smp, uv + RING8[i] * r1).rgb * 0.0325;
            wsum += 0.06 + 0.0325;
        }
        low /= wsum;
        float hi = smoothstep(P.hiE0, P.hiE1, encode1(lumv(e)));
        e = mix(e, low, hi * P.softAmt);

        // veiling glare of an uncoated plastic lens
        float4 gl = glow.sample(smp, uv);
        e = mix(e, gl.rgb, P.veilAmount);

        // halation: light bounced off the film base spills red into darker neighbours. Inside a
        // large bright area it is uniform and the lab's colour balance takes it out, so only
        // the spill beyond the local level shows.
        float spill = max(gl.a - halKnee(lensC.a, P), 0.0);
        e += float3(P.halR, P.halG, P.halB) * spill * P.halIntensity;

        // wide gamut photos (Display P3) arrive with colours outside sRGB. Film does not clip
        // a channel, it runs out of saturation, so pull such colours toward grey just enough.
        float Lg = lumv(e);
        float mn = min(min(e.r, e.g), e.b);
        if (mn < 0.0 && Lg > 0.0) e = Lg + (e - Lg) * (Lg / (Lg - mn));
        e = max(e, 0.0);

        // film shoulder: highlights roll off instead of clipping
        float3 t = max(e - 0.8, 0.0) / 0.2;
        e = min(e, 0.8) + 0.2 * tanh(t);

        // into the print domain the Marenn curve was measured in
        float3 v = encodeSRGB(e);

        // grain lives in the negative, so it goes in before the print curve. The curve's
        // slope then does what a real print does: strongest in the mids, gentle in the
        // highlights, and lifted shadows in dim frames carry extra grain.
        if (P.grainAmount > 0.0) {
            float4 g = grainField(int2(gid), P);
            float lv = lumv(v);
            float push = 1.0 + 0.6 * P.grainPush * (1.0 - smoothstep(0.08, 0.5, lv));
            float dense = 1.0 - 0.45 * smoothstep(0.55, 0.97, lv);    // dense negative, smoother print
            v += g.rgb * float3(P.grainR, P.grainG, P.grainB) * (P.grainAmount * push * dense);
        }

        float3 c = grade(v, P);

        // print bloom and warm glow, measured on real prints: bright areas lift and warm what
        // surrounds them. Screened on in print space, from a softly upsampled mid pyramid level.
        float2 bt = 0.5 / float2(bloom.get_width(), bloom.get_height());
        float3 wideL = 0.25 * (bloom.sample(smp, uv + float2(-bt.x, -bt.y)).rgb + bloom.sample(smp, uv + float2(bt.x, -bt.y)).rgb
                             + bloom.sample(smp, uv + float2(-bt.x, bt.y)).rgb + bloom.sample(smp, uv + float2(bt.x, bt.y)).rgb);
        float3 wide = grade(encodeSRGB(wideL), P);
        float lw = lumv(wide);
        float3 bloomS = wide * smoothstep(0.55, 0.95, lw) * P.bloomI;
        float3 warmS = wide * clamp((lw - 0.62) / 0.38, 0.0, 1.0) * float3(1.0, 0.60, 0.32) * P.warmGlow;
        c = 1.0 - (1.0 - c) * (1.0 - clamp(bloomS, 0.0, 1.0)) * (1.0 - clamp(warmS, 0.0, 1.0));

        // triangular dither so smooth skies never band at 8 bits
        float4 n = rand4(int2(gid), uint(P.seed), 7u);
        c += (n.x - n.y) * (P.dither / 255.0);

        dst.write(float4(clamp(c, 0.0, 1.0), 1.0), gid);
    }
    """
}

/// Small deterministic generator for per frame choices (SplitMix32 style).
struct MarennRNG {
    private var state: UInt32
    init(seed: UInt32) { state = seed &+ 0x9E3779B9 }
    mutating func next() -> UInt32 {
        state = state &+ 0x9E3779B9
        var z = state
        z = (z ^ (z >> 16)) &* 0x85EBCA6B
        z = (z ^ (z >> 13)) &* 0xC2B2AE35
        return z ^ (z >> 16)
    }
    mutating func unit() -> Float { Float(next() >> 8) / Float(1 << 24) }
}
