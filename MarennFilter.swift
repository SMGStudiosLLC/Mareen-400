import UIKit
import Metal
import CoreGraphics

enum MarennFilter {
    static let name = "Marenn 400"
    static let formerNames = ["Marenn XL", "gas filter"]

    static func apply(to image: UIImage) -> UIImage? {
        autoreleasepool {
            guard let cg = flatten(image),
                  let out = MarennEngine.shared?.process(cg) else { return nil }
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
}

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

final class MarennEngine {
    static let shared = MarennEngine()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gradePSO: MTLComputePipelineState
    private let clarityPSO: MTLComputePipelineState
    private let brightPSO: MTLComputePipelineState
    private let blurPSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState
    private let lock = NSLock()

    var gradeOverride: GradeP?
    var clarityOverride: ClarityP?
    var compOverride: CompP?
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
            self.gradePSO = try pso("marenn_grade")
            self.clarityPSO = try pso("marenn_clarity")
            self.brightPSO = try pso("marenn_bright")
            self.blurPSO = try pso("marenn_blur")
            self.compositePSO = try pso("marenn_composite")
        } catch {
            return nil
        }
    }

    enum MarennError: Error { case missingFunction }

    func process(_ image: CGImage) -> CGImage? {
        guard let source = bake(image) else { return nil }
        let w = source.width, h = source.height
        guard w > 1, h > 1 else { return nil }

        lock.lock()
        defer { lock.unlock() }

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
        if compOverride == nil { comp.seed = Float.random(in: 0..<1000) }
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

        return readBack(tFinal)
    }

    private func encode(_ cmd: MTLCommandBuffer, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int,
                        textures: [MTLTexture], _ uniforms: (MTLComputeCommandEncoder) -> Void) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        uniforms(enc)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
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

    static let source = """
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
        return (2*t3 - 3*t2 + 1) * KY[i] + (t3 - 2*t2 + t) * h * KM[i]
             + (-2*t3 + 3*t2) * KY[i + 1] + (t3 - t2) * h * KM[i + 1];
    }

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

    kernel void marenn_grade(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant GradeP& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = src.read(gid).rgb * p.gain;
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
}
