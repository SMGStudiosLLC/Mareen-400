// ref.cpp: CPU driver that runs the filter's real Metal kernels through the
// metal_stdlib shim. It mirrors VesperEngine.process dispatch by dispatch so
// the shader can be exercised, tuned and regression tested on any machine.
//
// Build (see build.sh): the Metal source is extracted from the Swift file by
// extract_msl.py and included here through the MSL_A / MSL_B macros. The
// binary is compiled once per stock:
//   -DSTOCK_LEGACY  runs the Marenn 400 kernels (marenn_*)
//   -DSTOCK_VESPER  runs the Vesper 800 kernels (vesper_*)
//
// I/O is a raw RGBA8 stream with an 8 byte header (uint32 width, uint32
// height). vesper_ref.py wraps this with real image decoding and encoding.
#include <metal_stdlib>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <chrono>

#include MSL_A
#ifdef MSL_B
#include MSL_B
#endif
#include "build/defaults.inc"

using namespace metal;

namespace {

struct Options {
    std::string inPath, outPath, dumpDir;
    float seed = 3.0f;
    bool haveSeed = false;
    bool noGrain = false;
    bool half = true;
    bool stats = false;
    std::string stampText;
    float leak = 0.0f;
    int flashHint = -1;
    bool timing = false;
};

struct Raw {
    int w = 0, h = 0;
    std::vector<uint8_t> bytes;
};

bool readRaw(const std::string& path, Raw& raw) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    uint32_t wh[2];
    if (std::fread(wh, 4, 2, f) != 2) { std::fclose(f); return false; }
    raw.w = (int)wh[0];
    raw.h = (int)wh[1];
    raw.bytes.resize((size_t)raw.w * raw.h * 4);
    size_t got = std::fread(raw.bytes.data(), 1, raw.bytes.size(), f);
    std::fclose(f);
    return got == raw.bytes.size();
}

bool writeRaw(const std::string& path, const Raw& raw) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    uint32_t wh[2] = { (uint32_t)raw.w, (uint32_t)raw.h };
    std::fwrite(wh, 4, 2, f);
    std::fwrite(raw.bytes.data(), 1, raw.bytes.size(), f);
    std::fclose(f);
    return true;
}

// Dump a texture as raw float32 RGBA (header: uint32 w, uint32 h) for scans.
void dumpTexture(const std::string& dir, const std::string& name, const TextureStorage& t) {
    if (dir.empty()) return;
    std::string path = dir + "/" + name + ".f32";
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    uint32_t wh[2] = { (uint32_t)t.width, (uint32_t)t.height };
    std::fwrite(wh, 4, 2, f);
    std::fwrite(t.px.data(), sizeof(float4), t.px.size(), f);
    std::fclose(f);
}

template <class F>
void dispatch(int w, int h, F&& fn) {
#pragma omp parallel for schedule(static)
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) fn(uint2((uint)x, (uint)y));
    }
}

PixelFormat interFormat(const Options& o) { return o.half ? PixelFormat::rgba16Float : PixelFormat::rgba32Float; }

template <access A>
texture2d<float, A> tex(TextureStorage& s) { return texture2d<float, A>(&s); }

void loadSource(TextureStorage& src, const Raw& raw) {
    for (int y = 0; y < raw.h; y++) {
        for (int x = 0; x < raw.w; x++) {
            const uint8_t* p = &raw.bytes[((size_t)y * raw.w + x) * 4];
            src.px[(size_t)y * raw.w + x] = float4(p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f, p[3] / 255.0f);
        }
    }
}

void storeFinal(const TextureStorage& t, Raw& raw) {
    raw.w = t.width;
    raw.h = t.height;
    raw.bytes.resize((size_t)t.width * t.height * 4);
    for (size_t i = 0; i < t.px.size(); i++) {
        const float4& p = t.px[i];
        raw.bytes[i * 4 + 0] = (uint8_t)std::nearbyint(saturate(p.x) * 255.0f);
        raw.bytes[i * 4 + 1] = (uint8_t)std::nearbyint(saturate(p.y) * 255.0f);
        raw.bytes[i * 4 + 2] = (uint8_t)std::nearbyint(saturate(p.z) * 255.0f);
        raw.bytes[i * 4 + 3] = 255;
    }
}

int swiftRoundHalf(int v) {
    // Swift: Int((Double(v) / 2).rounded()) rounds half away from zero.
    return (int)std::round((double)v / 2.0);
}

#ifdef STOCK_LEGACY

// ------------------------------------------------------------ Marenn 400 host

struct LegacyStats { float p50, meanLuma, hiFrac; };

LegacyStats legacySceneStats(const Raw& raw) {
    int total = raw.w * raw.h;
    LegacyStats s{0.45f, 0.45f, 0.0f};
    if (total <= 0) return s;
    int step = std::max(1, total / 40000);
    int hist[64] = {0};
    int count = 0, hiCount = 0;
    float lumaSum = 0.0f;
    for (int idx = 0; idx < total; idx += step) {
        const uint8_t* p = &raw.bytes[(size_t)idx * 4];
        float r = (float)p[0] / 255.0f, g = (float)p[1] / 255.0f, b = (float)p[2] / 255.0f;
        float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        lumaSum += l;
        if (l > 0.82f) hiCount++;
        hist[std::min(63, (int)(l * 64.0f))]++;
        count++;
    }
    int acc = 0;
    float p50 = 0.45f;
    for (int i = 0; i < 64; i++) {
        acc += hist[i];
        if (acc >= count / 2) { p50 = ((float)i + 0.5f) / 64.0f; break; }
    }
    s.p50 = p50;
    s.meanLuma = lumaSum / (float)count;
    s.hiFrac = (float)hiCount / (float)count;
    return s;
}

float legacyExposureGain(const LegacyStats& s) {
    float raw = std::pow(0.37f / std::max(s.p50, 0.05f), 0.45f);
    return std::max(0.85f, std::min(1.20f, raw));
}

bool runLegacy(const Options& o, const Raw& in, Raw& out) {
    int w = in.w, h = in.h;
    if (w < 1 || h < 1) return false;
    TextureStorage src(w, h, PixelFormat::rgba8Unorm);
    TextureStorage tA(w, h, interFormat(o)), tB(w, h, interFormat(o));
    TextureStorage tFinal(w, h, PixelFormat::rgba8Unorm);
    int hw = std::max(2, swiftRoundHalf(w)), hh = std::max(2, swiftRoundHalf(h));
    TextureStorage tHalf(hw, hh, interFormat(o)), tHalf2(hw, hh, interFormat(o));
    loadSource(src, in);

    LegacyStats stats = legacySceneStats(in);
    GradeP grade = defaultGradeP();
    grade.gain = legacyExposureGain(stats);
    dispatch(w, h, [&](uint2 gid) { marenn_grade(tex<access::read>(src), tex<access::write>(tA), grade, gid); });
    dumpTexture(o.dumpDir, "grade", tA);

    float minDim = (float)std::min(w, h);
    ClarityP clar = defaultClarityP();
    clar.radiusPx = std::max(1.5f, minDim / 189.0f);
    dispatch(w, h, [&](uint2 gid) { marenn_clarity(tex<access::sample>(tA), tex<access::write>(tB), clar, gid); });
    dumpTexture(o.dumpDir, "clarity", tB);

    BrightP bright = defaultBrightP();
    dispatch(hw, hh, [&](uint2 gid) { marenn_bright(tex<access::sample>(tB), tex<access::write>(tHalf), bright, gid); });

    float halStep = std::max(0.8f, 0.0022f * minDim);
    TextureStorage* rd = &tHalf;
    TextureStorage* wr = &tHalf2;
    for (int i = 0; i < 2; i++) {
        float2 dirH(halStep / (float)hw, 0.0f);
        dispatch(hw, hh, [&](uint2 gid) { marenn_blur(tex<access::sample>(*rd), tex<access::write>(*wr), dirH, gid); });
        std::swap(rd, wr);
        float2 dirV(0.0f, halStep / (float)hh);
        dispatch(hw, hh, [&](uint2 gid) { marenn_blur(tex<access::sample>(*rd), tex<access::write>(*wr), dirV, gid); });
        std::swap(rd, wr);
    }
    dumpTexture(o.dumpDir, "halation", *rd);

    CompP comp = defaultCompP();
    comp.seed = o.seed;
    if (o.noGrain) comp.grainAmount = 0.0f;
    comp.grainSize = std::max(1.0f, minDim / std::max(comp.grainDiv, 1.0f));
    TextureStorage* glow = rd;
    dispatch(w, h, [&](uint2 gid) { marenn_composite(tex<access::sample>(tB), tex<access::sample>(*glow), tex<access::write>(tFinal), comp, gid); });

    storeFinal(tFinal, out);
    if (o.stats) {
        std::printf("stock=marenn400 %dx%d gain=%.3f p50=%.3f\n", w, h, grade.gain, stats.p50);
    }
    return true;
}

#endif // STOCK_LEGACY

#ifdef STOCK_VESPER
#include "vesper_host.inc"
#endif

} // namespace

int main(int argc, char** argv) {
    Options o;
    std::vector<std::string> positional;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](float& dst) { if (i + 1 < argc) dst = (float)std::atof(argv[++i]); };
        if (a == "--seed") { next(o.seed); o.haveSeed = true; }
        else if (a == "--nograin") o.noGrain = true;
        else if (a == "--nohalf") o.half = false;
        else if (a == "--stats") o.stats = true;
        else if (a == "--timing") o.timing = true;
        else if (a == "--dump" && i + 1 < argc) o.dumpDir = argv[++i];
        else if (a == "--date" && i + 1 < argc) o.stampText = argv[++i];
        else if (a == "--leak") next(o.leak);
        else if (a == "--flash" && i + 1 < argc) o.flashHint = std::atoi(argv[++i]);
        else positional.push_back(a);
    }
    if (positional.size() != 2) {
        std::fprintf(stderr, "usage: ref <in.rgba> <out.rgba> [--seed N] [--nograin] [--nohalf] [--stats] [--dump dir] [--date TEXT] [--leak X] [--flash 0|1]\n");
        return 2;
    }
    o.inPath = positional[0];
    o.outPath = positional[1];
    Raw in, out;
    if (!readRaw(o.inPath, in)) { std::fprintf(stderr, "cannot read %s\n", o.inPath.c_str()); return 1; }
    auto t0 = std::chrono::steady_clock::now();
    bool ok = false;
#ifdef STOCK_LEGACY
    ok = runLegacy(o, in, out);
#endif
#ifdef STOCK_VESPER
    ok = runVesper(o, in, out);
#endif
    auto t1 = std::chrono::steady_clock::now();
    if (!ok) { std::fprintf(stderr, "processing failed\n"); return 1; }
    if (o.timing) {
        std::printf("time=%.3fs\n", std::chrono::duration<double>(t1 - t0).count());
    }
    if (!writeRaw(o.outPath, out)) { std::fprintf(stderr, "cannot write %s\n", o.outPath.c_str()); return 1; }
    return 0;
}
