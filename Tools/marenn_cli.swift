import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

func die(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else { die("usage: marenn <MarennFilter.swift> <in> <out.png> [--seed N] [--nograin]") }
let swiftPath = args[1], inPath = args[2], outPath = args[3]
var seed: Float = 3.0
if let i = args.firstIndex(of: "--seed"), i + 1 < args.count { seed = Float(args[i + 1]) ?? 3 }
let noGrain = args.contains("--nograin")

guard let swiftSrc = try? String(contentsOfFile: swiftPath, encoding: .utf8) else { die("cannot read \(swiftPath)") }
guard let startR = swiftSrc.range(of: "static let source = \"\"\""),
      let endR = swiftSrc.range(of: "\"\"\"", range: startR.upperBound..<swiftSrc.endIndex) else { die("MSL not found") }
let msl = String(swiftSrc[startR.upperBound..<endR.lowerBound])

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

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { die("no metal") }
let library: MTLLibrary
do { library = try device.makeLibrary(source: msl, options: nil) } catch { die("shader compile: \(error)") }
func pso(_ n: String) -> MTLComputePipelineState {
    guard let fn = library.makeFunction(name: n) else { die("missing \(n)") }
    return try! device.makeComputePipelineState(function: fn)
}
let gradePSO = pso("marenn_grade"), clarityPSO = pso("marenn_clarity")
let brightPSO = pso("marenn_bright"), blurPSO = pso("marenn_blur"), compositePSO = pso("marenn_composite")

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot load \(inPath)") }
let w = cg.width, h = cg.height

var bytes = [UInt8](repeating: 0, count: w * h * 4)
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("ctx") }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

func makeTex(_ w: Int, _ h: Int, _ f: MTLPixelFormat, _ u: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
    d.usage = u
    d.storageMode = (f == .rgba8Unorm) ? .managed : .private
    return device.makeTexture(descriptor: d)!
}
let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
let srcTex = makeTex(w, h, .rgba8Unorm, [.shaderRead])
let tA = makeTex(w, h, .rgba16Float, usage)
let tB = makeTex(w, h, .rgba16Float, usage)
let tFinal = makeTex(w, h, .rgba8Unorm, usage)
let hw = max(2, Int((Double(w) / 2).rounded())), hh = max(2, Int((Double(h) / 2).rounded()))
let tHalf = makeTex(hw, hh, .rgba16Float, usage)
let tHalf2 = makeTex(hw, hh, .rgba16Float, usage)
srcTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)

let total = w * h
let step = max(1, total / 40000)
var hist = [Int](repeating: 0, count: 64)
var count = 0, idx = 0
while idx < total {
    let p = idx * 4
    let l = 0.2126 * Float(bytes[p]) / 255 + 0.7152 * Float(bytes[p + 1]) / 255 + 0.0722 * Float(bytes[p + 2]) / 255
    hist[min(63, Int(l * 64))] += 1
    count += 1
    idx += step
}
var acc = 0
var p50: Float = 0.45
for i in 0..<64 { acc += hist[i]; if acc >= count / 2 { p50 = (Float(i) + 0.5) / 64; break } }
let expRef: Float = 0.37000, expPow: Float = 0.45
let gain = max(0.85, min(1.20, powf(expRef / max(p50, 0.05), expPow)))

let cmd = queue.makeCommandBuffer()!
func encode(_ pso: MTLComputePipelineState, _ w: Int, _ h: Int, _ texs: [MTLTexture], _ f: (MTLComputeCommandEncoder) -> Void) {
    let e = cmd.makeComputeCommandEncoder()!
    e.setComputePipelineState(pso)
    for (i, t) in texs.enumerated() { e.setTexture(t, index: i) }
    f(e)
    e.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    e.endEncoding()
}

var grade = GradeP(); grade.gain = gain
encode(gradePSO, w, h, [srcTex, tA]) { $0.setBytes(&grade, length: MemoryLayout<GradeP>.stride, index: 0) }

let minDim = Float(min(w, h))
var clar = ClarityP(); clar.radiusPx = max(1.5, minDim / 189)
encode(clarityPSO, w, h, [tA, tB]) { $0.setBytes(&clar, length: MemoryLayout<ClarityP>.stride, index: 0) }

var bright = BrightP()
encode(brightPSO, hw, hh, [tB, tHalf]) { $0.setBytes(&bright, length: MemoryLayout<BrightP>.stride, index: 0) }

let halStep = max(0.8, 0.0022 * minDim)
var read = tHalf, write = tHalf2
for _ in 0..<2 {
    var dirH = SIMD2<Float>(halStep / Float(hw), 0)
    encode(blurPSO, hw, hh, [read, write]) { $0.setBytes(&dirH, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
    swap(&read, &write)
    var dirV = SIMD2<Float>(0, halStep / Float(hh))
    encode(blurPSO, hw, hh, [read, write]) { $0.setBytes(&dirV, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
    swap(&read, &write)
}

var comp = CompP()
comp.seed = seed
if noGrain { comp.grainAmount = 0 }
comp.grainSize = max(1.0, minDim / max(comp.grainDiv, 1))
encode(compositePSO, w, h, [tB, read, tFinal]) { $0.setBytes(&comp, length: MemoryLayout<CompP>.stride, index: 0) }

if let blit = cmd.makeBlitCommandEncoder() { blit.synchronize(resource: tFinal); blit.endEncoding() }
cmd.commit()
cmd.waitUntilCompleted()

var out = [UInt8](repeating: 0, count: w * h * 4)
tFinal.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
guard let octx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let img = octx.makeImage() else { die("out ctx") }
let url = URL(fileURLWithPath: outPath) as CFURL
let type = outPath.lowercased().hasSuffix(".jpg") ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
guard let dest = CGImageDestinationCreateWithURL(url, type, 1, nil) else { die("dest") }
CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
CGImageDestinationFinalize(dest)
print("\(inPath) -> \(outPath)  \(w)x\(h)  gain=\(String(format: "%.3f", gain)) p50=\(String(format: "%.3f", p50))")
