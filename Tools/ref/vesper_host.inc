// vesper_host.inc: the Vesper 800 host path, mirroring VesperEngine in
// MarennFilter.swift step for step (stats, scene derivation, parameter
// modulation, dispatch order). Keep the two in sync; check_layout.py guards
// the structs, this file guards the arithmetic by printing the same --stats
// line the Swift CLI prints.

struct VesperStats {
    float p50 = 0.45f, p90 = 0.80f, darkFrac = 0.0f, brightFrac = 0.0f;
    float meanR = 1.0f, meanG = 1.0f, meanB = 1.0f;
    uint32_t hash = 0;
};

struct VesperScene {
    float gainR, gainG, gainB, gain, wbR, wbB, flash, night, highKey, seed;
    uint32_t seedBits;
    float grainScale;
};

static float eotf(float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); }

static float smoothF(float e0, float e1, float x) {
    float t = std::min(std::max((x - e0) / (e1 - e0), 0.0f), 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

static float unitF(uint32_t h, uint32_t salt) {
    uint32_t x = (h ^ salt) * 2654435761u;
    x ^= x >> 15;
    x = x * 2246822519u;
    x ^= x >> 13;
    return (float)(x % 20001u) / 10000.0f - 1.0f;
}

static VesperStats vesperSceneStats(const Raw& raw) {
    VesperStats s;
    int total = raw.w * raw.h;
    if (total <= 0) return s;
    int step = std::max(1, total / 40000);
    if (step % 2 == 0) step += 1;
    int hist[256] = {0};
    int count = 0;
    float midR = 0.0f, midG = 0.0f, midB = 0.0f;
    int midCount = 0;
    for (int idx = 0; idx < total; idx += step) {
        const uint8_t* p = &raw.bytes[(size_t)idx * 4];
        float r = (float)p[0] / 255.0f, g = (float)p[1] / 255.0f, b = (float)p[2] / 255.0f;
        float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        hist[std::min(255, std::max(0, (int)(l * 255.0f + 0.5f)))]++;
        if (l > 0.3f && l < 0.85f) { midR += r; midG += g; midB += b; midCount++; }
        count++;
    }
    int acc = 0, p50 = -1, p90 = -1, dark = 0, bright = 0;
    for (int i = 0; i < 256; i++) {
        acc += hist[i];
        if (p50 < 0 && acc * 2 >= count) p50 = i;
        if (p90 < 0 && acc * 10 >= count * 9) p90 = i;
        if (i < 31) dark += hist[i];
        if (i > 216) bright += hist[i];
    }
    s.p50 = ((float)std::max(p50, 0) + 0.5f) / 256.0f;
    s.p90 = ((float)std::max(p90, 0) + 0.5f) / 256.0f;
    s.darkFrac = (float)dark / (float)count;
    s.brightFrac = (float)bright / (float)count;
    if (midCount > 0) {
        s.meanR = midR / (float)midCount;
        s.meanG = midG / (float)midCount;
        s.meanB = midB / (float)midCount;
    }
    uint32_t h = 2166136261u;
    for (int i = 0; i < 256; i++) h = (h ^ (uint32_t)hist[i]) * 16777619u;
    h = (h ^ (uint32_t)raw.w) * 16777619u;
    h = (h ^ (uint32_t)raw.h) * 16777619u;
    s.hash = h;
    return s;
}

static VesperScene deriveScene(const VesperStats& s, const Options& o) {
    float refLin = eotf(0.37f);
    float gain = std::pow(refLin / std::max(eotf(s.p50), 0.002f), 0.42f);
    gain = std::min(std::max(gain, 0.72f), 1.55f);
    float p90Lin = eotf(s.p90);
    if (p90Lin > 0.05f) gain = std::min(gain, 0.95f / p90Lin);
    float flash = smoothF(0.30f, 0.55f, s.darkFrac) * smoothF(0.01f, 0.04f, s.brightFrac);
    if (o.flashHint >= 0) flash = o.flashHint ? std::max(flash, 0.7f) : 0.0f;
    float night = 1.0f - smoothF(0.10f, 0.34f, s.p50);
    float highKey = smoothF(0.55f, 0.75f, s.p50);
    float wbR = 1.0f, wbB = 1.0f;
    if (s.meanR > 0.01f && s.meanG > 0.01f && s.meanB > 0.01f) {
        float satM = std::max(std::fabs(s.meanR / s.meanG - 1.0f), std::fabs(s.meanB / s.meanG - 1.0f));
        float gate = 1.0f - smoothF(0.25f, 0.45f, satM);
        float rawR = std::min(std::max(1.0f + 0.35f * (s.meanG / s.meanR - 1.0f), 0.97f), 1.03f);
        float rawB = std::min(std::max(1.0f + 0.35f * (s.meanG / s.meanB - 1.0f), 0.97f), 1.03f);
        wbR = 1.0f + (rawR - 1.0f) * gate;
        wbB = 1.0f + (rawB - 1.0f) * gate;
    }
    float seed = o.haveSeed ? o.seed : (float)(s.hash % 100000u) / 100.0f;
    if (!(seed >= 0.0f && seed < 1000000.0f)) seed = 3.0f;
    uint32_t seedBits = (uint32_t)(seed * 1000.0f);
    float u1 = unitF(seedBits, 1), u2 = unitF(seedBits, 2), u3 = unitF(seedBits, 3);
    gain *= std::pow(2.0f, 0.06f * u1);
    float warm = 1.0f + 0.015f * u2;
    VesperScene sc;
    sc.gainR = gain * wbR * warm;
    sc.gainG = gain;
    sc.gainB = gain * wbB / warm;
    sc.gain = gain;
    sc.wbR = wbR;
    sc.wbB = wbB;
    sc.flash = flash;
    sc.night = night;
    sc.highKey = highKey;
    sc.seed = seed;
    sc.seedBits = seedBits;
    sc.grainScale = 1.0f + 0.1f * u3;
    return sc;
}

static StampP stampParams(const std::string& text) {
    StampP s = defaultStampP();
    if (text.empty()) return s;
    std::vector<float> codes;
    for (unsigned char ch : text) {
        int code;
        if (ch >= '0' && ch <= '9') code = ch - '0';
        else if (ch == '\'' || ch == '`') code = 10;
        else if (ch == ' ' || ch == '.' || ch == '/' || ch == ':') code = 11;
        else if (ch == '-') code = 12;
        else continue;
        codes.push_back((float)code);
        if (codes.size() == 10) break;
    }
    if (codes.empty()) return s;
    while (codes.size() < 10) codes.push_back(11.0f);
    s.enabled = 1.0f;
    float* slots[10] = { &s.c0, &s.c1, &s.c2, &s.c3, &s.c4, &s.c5, &s.c6, &s.c7, &s.c8, &s.c9 };
    for (int i = 0; i < 10; i++) *slots[i] = codes[i];
    int n = 10;
    while (n > 0 && codes[n - 1] == 11.0f) n--;
    s.count = (float)std::max(n, 1);
    return s;
}

bool runVesper(const Options& o, const Raw& in, Raw& out) {
    int w = in.w, h = in.h;
    if (w < 1 || h < 1) return false;
    TextureStorage src(w, h, PixelFormat::rgba8Unorm);
    TextureStorage tA(w, h, interFormat(o)), tB(w, h, interFormat(o));
    TextureStorage tFinal(w, h, PixelFormat::rgba8Unorm);
    int hw = std::max(1, swiftRoundHalf(w)), hh = std::max(1, swiftRoundHalf(h));
    int qw = std::max(1, swiftRoundHalf(hw)), qh = std::max(1, swiftRoundHalf(hh));
    int ew = std::max(1, swiftRoundHalf(qw)), eh = std::max(1, swiftRoundHalf(qh));
    TextureStorage tHalf(hw, hh, interFormat(o)), tHalf2(hw, hh, interFormat(o));
    TextureStorage tQuarter(qw, qh, interFormat(o));
    TextureStorage tEighth(ew, eh, interFormat(o)), tEighth2(ew, eh, interFormat(o));
    loadSource(src, in);

    VesperStats stats = vesperSceneStats(in);
    VesperScene scene = deriveScene(stats, o);

    ExposeP expose = defaultExposeP();
    expose.gainR = scene.gainR;
    expose.gainG = scene.gainG;
    expose.gainB = scene.gainB;
    expose.leakAmount = std::min(std::max(o.leak, 0.0f), 1.0f) * 0.8f;
    expose.leakEdge = (float)(scene.seedBits % 4u);
    expose.leakSeed = (float)(scene.seedBits % 1000u) / 100.0f;

    StampP stamp = stampParams(o.stampText);

    HaloP halo = defaultHaloP();
    halo.threshold += 0.15f * scene.highKey;

    BlurP coreH = defaultBlurP();
    coreH.sigmaFrac = halo.coreSigma;
    BlurP coreV = coreH;
    coreV.dirX = 0.0f;
    coreV.dirY = 1.0f;
    BlurP auraH = defaultBlurP();
    auraH.sigmaFrac = halo.auraSigma;
    BlurP auraV = auraH;
    auraV.dirX = 0.0f;
    auraV.dirY = 1.0f;

    DevelopP develop = defaultDevelopP();
    develop.kCore *= 1.0f + 0.5f * scene.flash;
    develop.kAura *= 1.0f + 0.5f * scene.flash;
    develop.toeLift *= 1.0f - 0.3f * scene.flash;

    DiffuseP diffuse = defaultDiffuseP();

    PrintP print = defaultPrintP();
    print.vigAmount *= 1.0f + 0.4f * scene.flash;
    print.grainAmount *= (1.0f + 0.35f * scene.night) * scene.grainScale;
    if (o.noGrain) print.grainAmount = 0.0f;
    print.seed = scene.seed;

    dispatch(w, h, [&](uint2 gid) { vesper_expose(tex<access::read>(src), tex<access::write>(tA), expose, stamp, gid); });
    dumpTexture(o.dumpDir, "expose", tA);
    dispatch(hw, hh, [&](uint2 gid) { vesper_halo_source(tex<access::read>(tA), tex<access::write>(tHalf), halo, gid); });
    dispatch(qw, qh, [&](uint2 gid) { vesper_down(tex<access::read>(tHalf), tex<access::write>(tQuarter), gid); });
    dispatch(ew, eh, [&](uint2 gid) { vesper_down(tex<access::read>(tQuarter), tex<access::write>(tEighth), gid); });
    dispatch(hw, hh, [&](uint2 gid) { vesper_blur(tex<access::read>(tHalf), tex<access::write>(tHalf2), coreH, gid); });
    dispatch(hw, hh, [&](uint2 gid) { vesper_blur(tex<access::read>(tHalf2), tex<access::write>(tHalf), coreV, gid); });
    dispatch(ew, eh, [&](uint2 gid) { vesper_blur(tex<access::read>(tEighth), tex<access::write>(tEighth2), auraH, gid); });
    dispatch(ew, eh, [&](uint2 gid) { vesper_blur(tex<access::read>(tEighth2), tex<access::write>(tEighth), auraV, gid); });
    dumpTexture(o.dumpDir, "halo_core", tHalf);
    dumpTexture(o.dumpDir, "halo_aura", tEighth);
    dispatch(w, h, [&](uint2 gid) { vesper_develop(tex<access::read>(tA), tex<access::sample>(tHalf), tex<access::sample>(tEighth), tex<access::write>(tB), develop, gid); });
    dumpTexture(o.dumpDir, "develop", tB);
    dispatch(w, h, [&](uint2 gid) { vesper_diffuse(tex<access::sample>(tB), tex<access::write>(tA), diffuse, gid); });
    dumpTexture(o.dumpDir, "diffuse", tA);
    dispatch(w, h, [&](uint2 gid) { vesper_print(tex<access::sample>(tA), tex<access::write>(tFinal), print, gid); });

    storeFinal(tFinal, out);
    if (o.stats) {
        std::printf("stock=vesper800 %dx%d p50=%.3f p90=%.3f dark=%.3f bright=%.3f gain=%.3f wb=%.3f,%.3f flash=%.2f night=%.2f highkey=%.2f seed=%.2f\n",
                    w, h, stats.p50, stats.p90, stats.darkFrac, stats.brightFrac, scene.gain, scene.wbR, scene.wbB,
                    scene.flash, scene.night, scene.highKey, scene.seed);
    }
    return true;
}
