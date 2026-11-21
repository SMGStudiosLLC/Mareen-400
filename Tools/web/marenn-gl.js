// Marenn 400 in the browser (WebGL2).
//
// The shaders come from Tools/web/marenn-shaders.js, generated from the Metal source in
// MarennFilter.swift by msl2glsl.py. This file mirrors the Swift host: sceneStats(),
// exposureGain(), frameParams(), pyramidSizes(), glowWeights() and process(). Keep it in
// step with MarennEngine, as Tools/cpu/marenn_cpu.cpp is.
//
//   const engine = new MarennGL();                  // throws if WebGL2 float targets are missing
//   const out = engine.develop(imageData, { seed: 42, dateStamp: new Date(), lightLeak: 0 });
//   // out: { width, height, data: Uint8ClampedArray (RGBA), params, gain }
(function (global) {
  "use strict";

  // ---- small numeric helpers ----------------------------------------------------
  const f32 = new Float32Array(1);
  const u32 = new Uint32Array(f32.buffer);

  // IEEE half bits, round to nearest even, like a float -> half conversion on the GPU
  function halfBits(x) {
    f32[0] = x;
    const b = u32[0];
    const sign = (b >>> 16) & 0x8000;
    const exp = (b >>> 23) & 0xff;
    let mant = b & 0x7fffff;
    if (exp === 0xff) return sign | 0x7c00 | (mant ? 0x200 : 0);
    let e = exp - 127 + 15;
    if (e >= 0x1f) return sign | 0x7c00;
    if (e <= 0) {
      if (e < -10) return sign;
      mant |= 0x800000;
      const shift = 14 - e;
      let h = mant >>> shift;
      const rem = mant & ((1 << shift) - 1), halfway = 1 << (shift - 1);
      if (rem > halfway || (rem === halfway && (h & 1))) h++;
      return sign | h;
    }
    let h = (e << 10) | (mant >>> 13);
    const rem = mant & 0x1fff;
    if (rem > 0x1000 || (rem === 0x1000 && (h & 1))) h++;
    return sign | h;
  }
  function halfToFloat(h) {
    const sign = h & 0x8000 ? -1 : 1, e = (h >>> 10) & 0x1f, m = h & 0x3ff;
    if (e === 0) return sign * m * Math.pow(2, -24);
    if (e === 31) return m ? NaN : sign * Infinity;
    return sign * (1 + m / 1024) * Math.pow(2, e - 15);
  }
  const fround = Math.fround;
  function srgbToLinear(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  function encodeSRGB(x) {
    const c = Math.max(0, Math.min(1, x));
    return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
  }
  // Abramowitz and Stegun 7.1.26, |error| < 1.5e-7
  function erf(x) {
    const s = x < 0 ? -1 : 1;
    x = Math.abs(x);
    const t = 1 / (1 + 0.3275911 * x);
    const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x);
    return s * y;
  }

  class RNG {  // MarennRNG
    constructor(seed) { this.state = (seed + 0x9e3779b9) >>> 0; }
    next() {
      this.state = (this.state + 0x9e3779b9) >>> 0;
      let z = this.state;
      z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
      z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
      return (z ^ (z >>> 16)) >>> 0;
    }
    unit() { return (this.next() >>> 8) / 16777216; }
  }

  // ---- host logic, mirrored from MarennEngine -------------------------------------
  function sceneStats(halfPixels, total) {
    const step = Math.max(1, Math.floor(total / 40000));
    const hist = new Array(64).fill(0);
    let count = 0, lumaSum = 0, hiCount = 0;
    for (let idx = 0; idx < total; idx += step) {
      const p = idx * 4;
      const r = encodeSRGB(halfToFloat(halfPixels[p]));
      const g = encodeSRGB(halfToFloat(halfPixels[p + 1]));
      const b = encodeSRGB(halfToFloat(halfPixels[p + 2]));
      const l = fround(fround(fround(0.2126 * r) + fround(0.7152 * g)) + fround(0.0722 * b));
      lumaSum += l;
      if (l > 0.82) hiCount++;
      hist[Math.min(63, Math.floor(l * 64))]++;
      count++;
    }
    let acc = 0, p50 = 0.45;
    for (let i = 0; i < 64; i++) {
      acc += hist[i];
      if (acc >= Math.floor(count / 2)) { p50 = (i + 0.5) / 64; break; }
    }
    return { p50, meanLuma: lumaSum / count, hiFrac: hiCount / count };
  }

  function exposureGain(s, expRef = 0.37, expPow = 0.45) {
    const raw = Math.pow(expRef / Math.max(s.p50, 0.05), expPow);
    return Math.max(0.85, Math.min(1.2, raw));
  }

  function pixelIntegral(sigma) {
    const a = 4 * sigma * sigma;
    const i0 = Math.sqrt(Math.PI * a) / 2 * erf(1 / Math.sqrt(a));
    const i1 = a / 2 * (1 - Math.exp(-1 / a));
    return 2 * (i0 - i1);
  }

  function frameParams(base, w, h, stats, o, encGain) {
    const p = Object.assign({}, base);
    p.width = w; p.height = h; p.minDim = Math.min(w, h);
    p.halfDiag = 0.5 * Math.sqrt(w * w + h * h);
    const rng = new RNG(o.seed == null ? (Math.random() * 4294967296) >>> 0 : o.seed >>> 0);
    p.seed = rng.next() & 0xffff;

    const v = Math.max(0, Math.min(1, o.frameVariation == null ? 1 : o.frameVariation));
    const expDrift = (rng.unit() * 2 - 1) * 0.10 * v;
    const warmDrift = (rng.unit() * 2 - 1) * 0.018 * v;
    const tintDrift = (rng.unit() * 2 - 1) * 0.010 * v;
    const g = Math.pow(encGain, 2.2) * Math.pow(2, expDrift) * base.exposure;
    const dim = Math.max(0, Math.min(1, (0.30 - stats.p50) / 0.20));
    const amber = base.dimWarmth * dim;
    p.gainR = g * (1 + warmDrift) * (1 + amber);
    p.gainG = g * (1 + tintDrift) * (1 + 0.25 * amber);
    p.gainB = g * (1 - warmDrift) * (1 - 1.2 * amber);

    const scale = p.minDim / 3024;
    const sigmaRaw = base.grainSigma * scale;
    const sigma = Math.max(0.6, sigmaRaw);
    p.grainSigma = sigma;
    p.grainRadius = Math.max(1, Math.min(3, Math.ceil(fround(2.5 * sigma))));
    const r = p.grainRadius;
    let sum2 = 0;
    for (let dy = -r; dy <= r; dy++)
      for (let dx = -r; dx <= r; dx++) {
        const wgt = Math.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
        sum2 += wgt * wgt;
      }
    p.grainNorm = pixelIntegral(sigmaRaw) / pixelIntegral(sigma) / Math.sqrt(sum2 / 3);
    const mottleRaw = 3 * sigmaRaw;
    p.mottleCell = Math.max(2, Math.round(mottleRaw / 0.6));
    p.mottleSigma = 0.6 * p.mottleCell;
    p.mottleNorm = pixelIntegral(mottleRaw) / pixelIntegral(p.mottleSigma) /
      Math.sqrt(Math.PI * p.mottleSigma * p.mottleSigma / (3 * p.mottleCell * p.mottleCell));
    p.grainAmount = o.grain === false ? 0 : base.grainAmount;
    p.grainPush = dim;

    if (o.dateStamp) {
      const d = o.dateStamp;
      const yy = d.getFullYear() % 100, mm = d.getMonth() + 1, dd = d.getDate();
      p.stampOn = 1;
      p.stampD0 = Math.floor(yy / 10); p.stampD1 = yy % 10;
      p.stampD2 = Math.floor(mm / 10); p.stampD3 = mm % 10;
      p.stampD4 = Math.floor(dd / 10); p.stampD5 = dd % 10;
    }
    const leak = Math.max(0, Math.min(1, o.lightLeak || 0));
    const side = rng.unit() < 0.5 ? 0 : 1;
    const along = 0.15 + 0.7 * rng.unit();
    p.leakAmount = leak;
    p.leakX = side;
    p.leakY = along;
    p.leakSpread = 0.25 + 0.2 * rng.unit();
    return p;
  }

  function pyramidSizes(w, h) {
    const sizes = [];
    let cw = Math.max(1, (w + 1) >> 1), ch = Math.max(1, (h + 1) >> 1);
    sizes.push([cw, ch]);
    while (Math.min(cw, ch) >= 32 && sizes.length < 8) {
      cw = Math.max(1, (cw + 1) >> 1);
      ch = Math.max(1, (ch + 1) >> 1);
      sizes.push([cw, ch]);
    }
    return sizes;
  }

  function glowWeights(n) {
    const veilTop = [0.34, 0.28, 0.18, 0.10, 0.06, 0.04, 0, 0];
    const halTop = [0.02, 0.06, 0.16, 0.30, 0.28, 0.18, 0, 0];
    let vs = 0, hs = 0;
    for (let i = 0; i < n; i++) { const t = n - 1 - i; vs += veilTop[t]; hs += halTop[t]; }
    const out = [];
    for (let i = 0; i < n; i++) {
      const t = n - 1 - i;
      const v = vs > 0 ? veilTop[t] / vs : 0, a = hs > 0 ? halTop[t] / hs : 0;
      out.push([v, v, v, a]);
    }
    return out;
  }

  // ---- WebGL plumbing ----------------------------------------------------------------
  const VS = "#version 300 es\nvoid main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));" +
    " gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";

  class MarennGL {
    constructor(canvas) {
      const shaders = global.MARENN_SHADERS;
      if (!shaders) throw new Error("marenn-shaders.js is not loaded");
      this.shaders = shaders;
      this.canvas = canvas || document.createElement("canvas");
      const gl = this.canvas.getContext("webgl2", { antialias: false, depth: false, stencil: false, premultipliedAlpha: false, preserveDrawingBuffer: false });
      if (!gl) throw new Error("WebGL2 is not available in this browser");
      if (!gl.getExtension("EXT_color_buffer_float") && !gl.getExtension("EXT_color_buffer_half_float"))
        throw new Error("This browser cannot render to half float textures");
      this.gl = gl;
      this.maxSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
      this.programs = {};
      for (const [name, k] of Object.entries(shaders.kernels)) this.programs[name] = this._program(name, k);
      this.vao = gl.createVertexArray();
    }

    _program(name, k) {
      const gl = this.gl;
      const compile = (type, src) => {
        const s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(name + ": " + gl.getShaderInfoLog(s));
        return s;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl.VERTEX_SHADER, VS));
      gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, k.source));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(name + ": " + gl.getProgramInfoLog(prog));
      const loc = {};
      for (const f of this.shaders.fields) loc["P." + f] = gl.getUniformLocation(prog, "P." + f);
      for (const u of ["uOutSize", "coarseScale", "fineWeight"]) loc[u] = gl.getUniformLocation(prog, u);
      const samplers = k.samplers.map((s) => gl.getUniformLocation(prog, s));
      return { prog, loc, samplers };
    }

    _texture(w, h, internal, format, type, data) {
      const gl = this.gl;
      const t = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, format, type, data || null);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      t.w = w; t.h = h;
      return t;
    }

    _pass(name, target, inputs, params, extra) {
      const gl = this.gl;
      const pr = this.programs[name];
      gl.useProgram(pr.prog);
      gl.bindFramebuffer(gl.FRAMEBUFFER, this.fb);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target, 0);
      gl.viewport(0, 0, target.w, target.h);
      inputs.forEach((t, i) => {
        gl.activeTexture(gl.TEXTURE0 + i);
        gl.bindTexture(gl.TEXTURE_2D, t);
        gl.uniform1i(pr.samplers[i], i);
      });
      if (params) for (const f of this.shaders.fields) {
        const l = pr.loc["P." + f];
        if (l) gl.uniform1f(l, params[f]);
      }
      gl.uniform2ui(pr.loc.uOutSize, target.w, target.h);
      if (extra) for (const [k, v] of Object.entries(extra)) gl.uniform4fv(pr.loc[k], v);
      gl.bindVertexArray(this.vao);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    /// imageData: { width, height, data } with 8 bit sRGB RGBA, rows top first.
    develop(imageData, options = {}, overrides = {}) {
      const gl = this.gl;
      const w = imageData.width, h = imageData.height;
      if (w < 2 || h < 2) throw new Error("image too small");
      if (Math.max(w, h) > this.maxSize) throw new Error("image larger than this GPU's " + this.maxSize + " px limit");

      // bake: decode to linear half floats, like MarennEngine.bake()
      const src = imageData.data;
      const lut = new Uint16Array(256);
      for (let i = 0; i < 256; i++) lut[i] = halfBits(fround(srgbToLinear(i / 255)));
      const halfPx = new Uint16Array(w * h * 4);
      for (let i = 0, n = w * h * 4; i < n; i += 4) {
        halfPx[i] = lut[src[i]]; halfPx[i + 1] = lut[src[i + 1]]; halfPx[i + 2] = lut[src[i + 2]];
        halfPx[i + 3] = 0x3c00;
      }
      const stats = sceneStats(halfPx, w * h);
      const encGain = exposureGain(stats);
      const base = Object.assign({}, this.shaders.defaults, overrides);
      const p = frameParams(base, w, h, stats, options, encGain);

      const textures = [];
      const tex = (...a) => { const t = this._texture(...a); textures.push(t); return t; };
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      const srcTex = tex(w, h, gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT, halfPx);
      const lensTex = tex(w, h, gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT, null);
      const outTex = tex(w, h, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, null);
      const sizes = pyramidSizes(w, h);
      const levels = [], ups = [];
      sizes.forEach(([sw, sh], i) => {
        levels.push(tex(sw, sh, gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT, null));
        if (i < sizes.length - 1) ups.push(tex(sw, sh, gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT, null));
      });
      this.fb = gl.createFramebuffer();

      this._pass("marenn_lens", lensTex, [srcTex], p);
      this._pass("marenn_extract", levels[0], [lensTex], p);
      for (let i = 1; i < levels.length; i++) this._pass("marenn_down", levels[i], [levels[i - 1]], null);
      const weights = glowWeights(levels.length);
      let coarse = levels[levels.length - 1], coarseScale = weights[levels.length - 1];
      for (let i = levels.length - 2; i >= 0; i--) {
        this._pass("marenn_up", ups[i], [coarse, levels[i]], null, { coarseScale, fineWeight: weights[i] });
        coarse = ups[i];
        coarseScale = [1, 1, 1, 1];
      }
      const glow = ups.length ? ups[0] : levels[0];
      const bloomLevel = levels[Math.max(0, levels.length - 4)];
      this._pass("marenn_film", outTex, [lensTex, glow, bloomLevel], p);

      const out = new Uint8ClampedArray(w * h * 4);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, out);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.deleteFramebuffer(this.fb);
      textures.forEach((t) => gl.deleteTexture(t));
      return { width: w, height: h, data: out, params: p, gain: encGain, stats };
    }
  }

  global.MarennGL = MarennGL;
})(typeof window !== "undefined" ? window : globalThis);
