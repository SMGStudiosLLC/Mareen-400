// CPU reference renderer for Marenn 400.
//
// Runs the Metal kernels embedded in MarennFilter.swift on the CPU (see metal_stdlib
// and msl2cpp.py). The kernels and every default parameter come straight from the
// Swift file. What lives here is a line by line mirror of the host orchestration:
// MarennEngine.process(), frameParams(), pyramidSizes() and glowWeights().
// If you change one of those in Swift, change it here too; CI compares the two.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>
#include "shader.inc"
#include "uniforms.inc"

template <class F> static void dispatch(int w, int h, F f) {
    #pragma omp parallel for schedule(dynamic, 4)
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) f(uint2{uint(x), uint(y)});
}

struct RNG {  // MarennRNG
    uint32_t state;
    explicit RNG(uint32_t seed) : state(seed + 0x9E3779B9u) {}
    uint32_t next() {
        state += 0x9E3779B9u;
        uint32_t z = state;
        z = (z ^ (z >> 16)) * 0x85EBCA6Bu;
        z = (z ^ (z >> 13)) * 0xC2B2AE35u;
        return z ^ (z >> 16);
    }
    float unit() { return float(next() >> 8) / float(1 << 24); }
};

struct Stats { float p50, meanLuma, hiFrac; };

static Stats scene_stats(const uint8_t* bytes, int w, int h) {
    int total = w * h;
    int step = std::max(1, total / 40000);
    int hist[64] = {0};
    int count = 0, hiCount = 0;
    float lumaSum = 0;
    for (int idx = 0; idx < total; idx += step) {
        const uint8_t* p = bytes + size_t(idx) * 4;
        float r = p[0] / 255.0f, g = p[1] / 255.0f, b = p[2] / 255.0f;
        float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        lumaSum += l;
        if (l > 0.82f) hiCount++;
        hist[std::min(63, int(l * 64))]++;
        count++;
    }
    int acc = 0;
    float p50 = 0.45f;
    for (int i = 0; i < 64; i++) {
        acc += hist[i];
        if (acc >= count / 2) { p50 = (i + 0.5f) / 64; break; }
    }
    return {p50, lumaSum / count, float(hiCount) / count};
}

static float pixel_integral(float sigma) {  // MarennEngine.pixelIntegral
    double a = double(4 * sigma * sigma);
    double i0 = std::sqrt(M_PI * a) / 2 * std::erf(1 / std::sqrt(a));
    double i1 = a / 2 * (1 - std::exp(-1 / a));
    return float(2 * (i0 - i1));
}

struct Options { uint32_t seed; float frameVariation; int grain; int stampOn, yy, mm, dd; float leak; };

static MarennParams frame_params(MarennParams p, int w, int h, Stats st, const Options& o, float encGain) {
    MarennParams base = p;
    p.width = float(w);
    p.height = float(h);
    p.minDim = float(std::min(w, h));
    p.halfDiag = 0.5f * std::sqrt(float(w * w + h * h));
    RNG rng(o.seed);
    p.seed = float(rng.next() & 0xFFFF);
    float v = std::max(0.0f, std::min(1.0f, o.frameVariation));
    float expDrift = (rng.unit() * 2 - 1) * 0.10f * v;
    float warmDrift = (rng.unit() * 2 - 1) * 0.018f * v;
    float tintDrift = (rng.unit() * 2 - 1) * 0.010f * v;
    float g = std::pow(encGain, 2.2f) * std::pow(2.0f, expDrift) * base.exposure;
    p.gainR = g * (1 + warmDrift);
    p.gainG = g * (1 + tintDrift);
    p.gainB = g * (1 - warmDrift);

    float scale = p.minDim / 3024;
    float sigmaRaw = base.grainSigma * scale;
    float sigma = std::max(0.6f, sigmaRaw);
    p.grainSigma = sigma;
    p.grainRadius = float(std::max(1, std::min(3, int(std::ceil(2.5f * sigma)))));
    int r = int(p.grainRadius);
    float sum2 = 0;
    for (int dy = -r; dy <= r; dy++)
        for (int dx = -r; dx <= r; dx++) {
            float wgt = std::exp(-float(dx * dx + dy * dy) / (2 * sigma * sigma));
            sum2 += wgt * wgt;
        }
    p.grainNorm = pixel_integral(sigmaRaw) / pixel_integral(sigma) / std::sqrt(sum2 / 3);
    float mottleRaw = 3 * sigmaRaw;
    p.mottleCell = std::max(2.0f, std::round(mottleRaw / 0.6f));
    p.mottleSigma = 0.6f * p.mottleCell;
    p.mottleNorm = pixel_integral(mottleRaw) / pixel_integral(p.mottleSigma) /
                   std::sqrt(float(M_PI) * p.mottleSigma * p.mottleSigma / (3 * p.mottleCell * p.mottleCell));
    p.grainAmount = o.grain ? base.grainAmount : 0;
    p.grainPush = std::max(0.0f, std::min(1.0f, (0.30f - st.p50) / 0.20f));

    if (o.stampOn) {
        int yy = o.yy % 100, mm = o.mm, dd = o.dd;
        p.stampOn = 1;
        p.stampD0 = float(yy / 10); p.stampD1 = float(yy % 10);
        p.stampD2 = float(mm / 10); p.stampD3 = float(mm % 10);
        p.stampD4 = float(dd / 10); p.stampD5 = float(dd % 10);
    }
    float leak = std::max(0.0f, std::min(1.0f, o.leak));
    float side = rng.unit() < 0.5f ? 0.0f : 1.0f;
    float along = 0.15f + 0.7f * rng.unit();
    p.leakAmount = leak;
    p.leakX = side;
    p.leakY = along;
    p.leakSpread = 0.25f + 0.2f * rng.unit();
    return p;
}

static std::vector<std::pair<int, int>> pyramid_sizes(int w, int h) {
    std::vector<std::pair<int, int>> s;
    int cw = std::max(1, (w + 1) / 2), ch = std::max(1, (h + 1) / 2);
    s.push_back({cw, ch});
    while (std::min(cw, ch) >= 32 && s.size() < 8) {
        cw = std::max(1, (cw + 1) / 2);
        ch = std::max(1, (ch + 1) / 2);
        s.push_back({cw, ch});
    }
    return s;
}

static std::vector<float4> glow_weights(int n) {
    const float veilTop[8] = {0.34f, 0.28f, 0.18f, 0.10f, 0.06f, 0.04f, 0, 0};
    const float halTop[8] = {0.02f, 0.06f, 0.16f, 0.30f, 0.28f, 0.18f, 0, 0};
    std::vector<float4> out(n);
    float vs = 0, hs = 0;
    for (int i = 0; i < n; i++) { int t = n - 1 - i; vs += veilTop[t]; hs += halTop[t]; }
    for (int i = 0; i < n; i++) {
        int t = n - 1 - i;
        float v = vs > 0 ? veilTop[t] / vs : 0, a = hs > 0 ? halTop[t] / hs : 0;
        out[i] = float4{v, v, v, a};
    }
    return out;
}

static float exposure_gain(Stats s) {
    float raw = std::pow(0.37f / std::max(s.p50, 0.05f), 0.45f);
    return std::max(0.85f, std::min(1.20f, raw));
}

static void apply_overrides(MarennParams& p, const char* spec) {
    if (!spec) return;
    std::stringstream ss(spec);
    std::string item;
    while (std::getline(ss, item, ';')) {
        auto eq = item.find('=');
        if (eq == std::string::npos) continue;
        if (float* f = field_MarennParams(p, item.substr(0, eq))) *f = std::stof(item.substr(eq + 1));
    }
}

extern "C" int marenn_process(const uint8_t* in, int w, int h, uint8_t* out, uint32_t seed, float frameVariation,
                              int grain, int stampOn, int yy, int mm, int dd, float leak, const char* overrides,
                              float* info) {
    if (w < 2 || h < 2) return 1;
    Stats st = scene_stats(in, w, h);
    MarennParams base = default_MarennParams();
    apply_overrides(base, overrides);
    Options o{seed, frameVariation, grain, stampOn, yy, mm, dd, leak};
    float encGain = exposure_gain(st);
    MarennParams p = frame_params(base, w, h, st, o, encGain);
    if (info) { info[0] = encGain; info[1] = st.p50; info[2] = p.grainPush; }

    TexStore src(w, h, pixfmt::rgba8unorm_srgb), lensT(w, h, pixfmt::rgba16float), outT(w, h, pixfmt::rgba8unorm);
    src.upload_rgba8(in);
    auto sizes = pyramid_sizes(w, h);
    int n = int(sizes.size());
    std::vector<TexStore> levels, ups;
    levels.reserve(n);
    ups.reserve(n);
    for (int i = 0; i < n; i++) {
        levels.emplace_back(sizes[i].first, sizes[i].second, pixfmt::rgba16float);
        if (i < n - 1) ups.emplace_back(sizes[i].first, sizes[i].second, pixfmt::rgba16float);
    }

    dispatch(w, h, [&](uint2 id) { marenn_lens(&src, &lensT, p, id); });
    dispatch(sizes[0].first, sizes[0].second, [&](uint2 id) { marenn_extract(&lensT, &levels[0], p, id); });
    for (int i = 1; i < n; i++)
        dispatch(sizes[i].first, sizes[i].second, [&](uint2 id) { marenn_down(&levels[i - 1], &levels[i], id); });

    auto weights = glow_weights(n);
    TexStore* coarse = &levels[n - 1];
    float4 coarseScale = weights[n - 1];
    for (int i = n - 2; i >= 0; i--) {
        float4 fineW = weights[i], cs = coarseScale;
        dispatch(sizes[i].first, sizes[i].second, [&](uint2 id) { marenn_up(coarse, &levels[i], &ups[i], cs, fineW, id); });
        coarse = &ups[i];
        coarseScale = float4{1, 1, 1, 1};
    }
    TexStore* glow = ups.empty() ? &levels[0] : &ups[0];
    dispatch(w, h, [&](uint2 id) { marenn_film(&lensT, glow, &outT, p, id); });
    outT.download_rgba8(out);
    return 0;
}
