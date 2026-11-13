// Mountain trail: the ground's shape, and the kernels that bake it into the clipmap's levels.
// Compiled after SceneShared.h, Common.metal and MountainScene.h.
//
//   mtnTerrain(P, cell, shape)  the height at absolute (x, z) and what it is made of. `cell` is
//                               the spacing it will be sampled at: shapes smaller than a few
//                               cells fade out (a coarse level must not alias them into noise).
//   mtn_bake_height             a level's heights and material masks
//   mtn_bake_surface            its normals, ambient occlusion and curvature, from the heights
//   mtn_bake_shadow             how much sun gets past the terrain to each point: a march toward
//                               the sun over the baked heights (this level and the coarser ones)
//
// The shape, from the trail outward:
//   - the tread: a bench cut into the slope, MountainTrailY(z) high, with a cut bank above it
//   - the slope: about 33° down to the valley floor 620 m below (steeper in the middle, with
//     bands of cliff) and up to a crest 40–120 m above (crags along it); spurs and bowls,
//     gullies down the fall line, bumps, outcrops of bedrock, the little terraces grazing leaves
//   - across the valley: a pedestal of forest and scree, and on it the towers: cells of a
//     Voronoi pattern, each a fluted column with a talus cone around its foot, needles on its
//     crown, bedding ledges across its walls
//   - beyond, and behind the crest: other ranges (eroded fractal noise)

// ---- noise ----

static float mtnHash(int2 i, uint seed) {
  return hashU(uint3(uint(i.x), uint(i.y), seed));
}

/// Value noise 0 … 1 (x) and its gradient (yz), quintic.
static float3 mtnNoiseD(float2 p, uint seed) {
  float2 i = floor(p), f = p - i;
  float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
  int2 c = int2(i);
  float a = mtnHash(c, seed), b = mtnHash(c + int2(1, 0), seed), cc = mtnHash(c + int2(0, 1), seed), d = mtnHash(c + int2(1, 1), seed);
  float k1 = b - a, k2 = cc - a, k4 = a - b - cc + d;
  return float3(a + k1 * w.x + k2 * w.y + k4 * w.x * w.y, dw * float2(k1 + k4 * w.y, k2 + k4 * w.x));
}

static float mtnNoise(float2 p, uint seed) {
  return mtnNoiseD(p, seed).x;
}

/// 1 for shapes `wavelength` metres across sampled every `cell` metres, fading to 0 below 3 cells.
static float mtnBand(float wavelength, float cell) {
  return saturate(wavelength / (cell * 3.0) - 1.0);
}

/// Fractal noise around 0 (about −1 … 1), the first octave `wavelength` metres across.
static float mtnFbm(float2 P, float wavelength, int octaves, float cell, uint seed) {
  float sum = 0.0, amp = 1.0, norm = 0.0;
  float2 p = P / wavelength;
  for (int o = 0; o < octaves; o++) {
    float fade = mtnBand(wavelength, cell);
    if (fade <= 0.0) break;
    sum += amp * fade * (mtnNoise(p, seed + uint(o)) * 2.0 - 1.0);
    norm += amp;
    amp *= 0.5;
    wavelength *= 0.5;
    p = float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.0 + 17.3;
  }
  return norm > 0.0 ? sum / norm : 0.0;
}

/// Fractal noise that looks eroded (0 … 1): each octave is damped where the slope so far is
/// steep, so ridges stay sharp and valleys smooth.
static float mtnEroded(float2 P, float wavelength, int octaves, float cell, uint seed) {
  float sum = 0.0, amp = 1.0, norm = 0.0;
  float2 p = P / wavelength, d = 0.0;
  for (int o = 0; o < octaves; o++) {
    float fade = mtnBand(wavelength, cell);
    if (fade <= 0.0) break;
    float3 n = mtnNoiseD(p, seed + uint(o));
    d += n.yz;
    sum += amp * fade * n.x / (1.0 + dot(d, d));
    norm += amp;
    amp *= 0.5;
    wavelength *= 0.5;
    p = float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.0 + 17.3;
  }
  return norm > 0.0 ? sum / norm : 0.0;
}

/// Ridged fractal noise (0 … 1): sharp crests, each octave strongest on the crests of the one
/// before, so ridges carry ridges and the hollows between them stay smooth. Pyramids and arêtes.
static float mtnRidged(float2 P, float wavelength, int octaves, float cell, uint seed) {
  float sum = 0.0, amp = 0.5, weight = 1.0, norm = 0.0;
  float2 p = P / wavelength;
  for (int o = 0; o < octaves; o++) {
    float fade = mtnBand(wavelength, cell);
    if (fade <= 0.0) break;
    float n = 1.0 - abs(2.0 * mtnNoise(p, seed + uint(o)) - 1.0);
    n *= n * weight;
    weight = saturate(n * 2.2);
    sum += n * amp * fade;
    norm += amp;
    amp *= 0.52;
    wavelength /= 2.07;
    p = float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.07 + 31.7;
  }
  return norm > 0.0 ? sum / norm : 0.0;
}

// ---- the range across the valley ----

/// Where towers stand (0 … 1): a band across the valley, in groups with saddles between them.
static float mtnEnvelope(float2 fp, MountainShape s) {
  float v = s.side * fp.x;
  float w = smoothstep(720.0, 1250.0, v) * (1.0 - smoothstep(3000.0, 4200.0, v));
  float g = 0.25 + 0.75 * smoothstep(0.3, 0.6, mtnNoise(fp / 1900.0, uint(s.seed) * 7919u + 40u));
  return w * g;
}

/// Towers on a jittered grid of `size` metres, up to `height` tall: x the height at P, y how much
/// of it is the tower's rock (1) and how much the talus around its foot (0). Each is a column
/// with buttresses and couloirs (its radius varies around it), a rounded crown, and a cone of
/// scree at the angle of repose reaching `apron` of its height.
static float2 mtnSpires(float2 P, float size, float height, float apron, bool enveloped, MountainShape s, uint seed) {
  int2 ci = int2(floor(P / size));
  float best = 0.0, rock = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      int2 c = ci + int2(i, j);
      float2 fp = (float2(c) + 0.22 + 0.56 * float2(mtnHash(c, seed), mtnHash(c, seed + 1u))) * size;
      float hs = mtnHash(c, seed + 2u);
      float tall = height * (0.32 + 0.68 * hs) * (enveloped ? mtnEnvelope(fp, s) : 1.0);
      if (tall < 1.0) continue;
      float radius = size * (0.24 + 0.17 * mtnHash(c, seed + 3u));
      float2 dl = P - fp;
      float r = length(dl);
      float2 dir = dl / max(r, 1e-3);
      float flute = 1.0 + 0.34 * (mtnNoise(dir * 2.1 + hs * 91.0, seed + 4u) - 0.5) + 0.2 * (mtnNoise(dir * 6.0 + hs * 37.0, seed + 5u) - 0.5);
      float rr = r / (radius * flute);
      float wall = 1.0 - smoothstep(0.5, 0.96, rr);
      float tower = tall * wall * (1.0 - 0.3 * min(rr * rr * 5.0, 1.0));
      float talus = clamp(tall * apron - 0.68 * (r - 0.8 * radius * flute), 0.0, tall * (apron + 0.14));
      float h = max(tower, talus);
      if (h > best) {
        best = h;
        rock = saturate((tower - talus) / (0.05 * tall + 2.0));
      }
    }
  }
  return float2(best, rock);
}

// ---- the terrain ----

struct MtnTerrain {
  float h;
  float rock;   // bedrock at the surface
  float scree;  // loose rock
  float gully;  // in a gully's line
};

/// `h` with its rise cut into steps `step` metres high (ledges and risers), by `amount`;
/// returns how much of a riser the point is on.
static float mtnLedges(thread float &h, float step, float warp, float riseFrom, float amount) {
  float q = h / step + warp;
  float fl = floor(q), fr = q - fl;
  float stepped = (fl + smoothstep(riseFrom, 0.97, fr) - warp) * step;
  h = mix(h, stepped, amount);
  return smoothstep(riseFrom - 0.05, riseFrom + 0.1, fr) * (1.0 - smoothstep(0.93, 1.0, fr));
}

static MtnTerrain mtnTerrain(float2 P, float cell, MountainShape s) {
  uint seed = uint(s.seed) * 7919u + 13u;
  float z = P.y;
  float ty = MountainTrailY(z), ps = MountainPathSlope(z);
  float dx = P.x - MountainPathX(z);
  float d = dx * rsqrt(1.0 + ps * ps);  // metres across the trail
  float ad = abs(d);
  // Near the trail the slope follows it; far away the valley and the range are straight.
  float v = s.side * mix(d, P.x, smoothstep(150.0, 500.0, abs(dx)));  // metres toward the valley
  float av = abs(v);
  const float kDepth = 460.0, kFloor = 620.0;
  MtnTerrain t;
  t.rock = 0.0;
  t.scree = 0.0;
  t.gully = 0.0;

  // The slope's cross-section: down to the valley floor and up the pedestal of the range; up to
  // the crest and down behind it.
  float crest = 42.0 + 75.0 * mtnNoise(float2(z / 230.0, 3.7), seed + 20u) + 520.0 * max(mtnNoise(float2(z / 2400.0, 9.1), seed + 21u) - 0.55, 0.0);
  float up = -v * 0.66 / crest;  // 1 at about the crest
  float h;
  if (v >= 0.0) {
    float q = min(v / kFloor, 1.0);
    h = -kDepth * (0.95 * q + 1.1 * q * q - 1.05 * q * q * q);
    h += 400.0 * smoothstep(660.0, 1500.0, v) - 330.0 * smoothstep(3600.0, 4900.0, v);
  } else {
    h = crest * tanh(up) - 430.0 * (1.0 - exp(-max(-v - 320.0, 0.0) / 900.0));
  }
  h += ty * (1.0 - smoothstep(120.0, 700.0, av));
  h += 150.0 * (mtnNoise(P / 5200.0, seed + 61u) - 0.5) * smoothstep(300.0, 1500.0, av);

  // Other ranges, far off on both sides.
  float farField = smoothstep(4400.0, 7500.0, v) + smoothstep(900.0, 3200.0, -v);
  if (farField > 0.0) {
    float f = mtnEroded(P, 9000.0, 8, cell, seed + 70u);
    float f2 = mtnNoise(P / 23000.0, seed + 71u);
    h = mix(h, -420.0 + 2300.0 * f * (0.55 + 0.9 * f2), min(farField, 1.0));
  }

  // The range: a massif of sharp ridges and pyramids (ridged noise raised to a power, so its
  // crests stand as towers and the hollows between them run down as gullies of scree), cut by
  // a wall or two where its smooth shape passes a threshold, needles on its crests.
  if (v > 600.0 && v < 5200.0) {
    float env = mtnEnvelope(P, s);
    if (env > 0.0) {
      float2 W = P + 110.0 * float2(mtnFbm(P, 430.0, 3, cell, seed + 50u), mtnFbm(P + 311.0, 430.0, 3, cell, seed + 51u));
      float e = mtnEroded(W, 1700.0, 6, cell, seed + 100u);
      float B = env * smoothstep(0.1, 0.5, e);
      float rm = mtnRidged(W, 760.0, 8, cell, seed + 104u);
      float tall = smoothstep(0.12, 0.5, B);
      float crest = pow(rm, 1.35);
      float m = 230.0 * smoothstep(0.0, 0.4, B) + tall * (980.0 * crest + 120.0 * smoothstep(0.4, 0.46, B + 0.25 * rm));
      float2 mid = mtnSpires(W + 97.0, 190.0, 210.0, 0.15, false, s, seed + 110u);
      float2 small = mtnSpires(W + 41.0, 70.0, 90.0, 0.12, false, s, seed + 120u);
      float onCrest = tall * smoothstep(0.25, 0.5, rm);
      m += onCrest * (mid.x * mtnBand(190.0, cell * 2.0) + (0.4 + 0.6 * mid.y) * small.x * mtnBand(70.0, cell * 2.0));
      float hm = h + m * s.peaks;
      float rock = tall * smoothstep(0.16, 0.3, rm);
      // Bedding: the walls rise in bands with ledges between them.
      mtnLedges(hm, 46.0, 1.3 * mtnNoise(P / 350.0, seed + 131u), 0.3, 0.4 * rock * saturate(2.0 - cell / 8.0));
      h = hm;
      t.rock = rock;
      t.scree = (1.0 - rock) * smoothstep(0.05, 0.2, B);
    }
  }

  // The slope the trail crosses.
  float nearW = 1.0 - smoothstep(450.0, 620.0, av);
  if (nearW > 0.0) {
    float off = smoothstep(3.0, 45.0, ad);
    // Spurs and bowls.
    h += nearW * (mtnNoise(float2(z / 270.0, v / 800.0 + 5.0), seed + 22u) - 0.5) * 2.0 * min(0.11 * av, 55.0) * smoothstep(6.0, 60.0, ad);
    // Gullies down the fall line.
    float gn = mtnNoise(float2((z + 0.25 * v) / 48.0 + 1.3 * mtnNoise(P / 140.0, seed + 23u), v / 500.0), seed + 24u);
    float g = pow(1.0 - abs(2.0 * gn - 1.0), 4.0);
    h -= nearW * saturate(2.0 - cell / 3.0) * min(1.0 + 0.05 * av, 16.0) * off * g;
    t.gully = g * nearW * off;
    // Bumps, large and small.
    h += nearW * 9.0 * mtnFbm(P, 170.0, 3, cell, seed + 35u) * smoothstep(8.0, 80.0, ad);
    h += nearW * 3.0 * mtnFbm(P, 46.0, 5, cell, seed + 25u) * smoothstep(1.5, 16.0, ad);
    h += nearW * 0.22 * mtnFbm(P, 3.1, 3, cell, seed + 30u) * smoothstep(0.8, 3.0, ad);

    // Bedrock: bands of cliff below the trail, crags along the crest above it.
    float rk = mtnFbm(P, 110.0, 3, cell, seed + 26u);
    float crags = v < 0.0 ? smoothstep(0.55, 1.0, up) * (1.0 - smoothstep(1.7, 3.2, up)) : 0.0;
    float bands = v > 0.0 ? smoothstep(70.0, 160.0, v) * (1.0 - smoothstep(380.0, 540.0, v)) : crags;
    float cliff = nearW * bands * smoothstep(-0.2, 0.2, rk);
    if (cliff > 0.0) {
      float riser = mtnLedges(h, 38.0, 0.9 * mtnNoise(P / 90.0, seed + 27u), 0.55, cliff * 0.8 * saturate(2.5 - cell / 4.0));
      t.rock = max(t.rock, cliff * riser);
    }
    // Outcrops: knobs of rock breaking the turf, layered, in patches.
    float patch = nearW * smoothstep(0.0, 0.33, rk + 0.3 * crags + 0.06) * smoothstep(1.7, 4.5, ad);
    if (patch > 0.0) {
      float o = mtnNoise(P / 4.6, seed + 28u) * 0.62 + mtnNoise(P / 1.7, seed + 29u) * 0.38;
      float rise = smoothstep(0.52, 0.68, o);
      float knob = (0.5 + 2.8 * mtnNoise(P / 11.0, seed + 32u)) * rise;
      mtnLedges(knob, 0.38, mtnNoise(P / 3.0, seed + 33u), 0.6, 0.7);
      h += patch * knob * saturate(2.0 - cell / 1.5);
      t.rock = max(t.rock, patch * smoothstep(0.08, 0.4, rise));
    }
    // Terracettes: narrow steps along the contours.
    float steps = saturate(1.5 - cell / 0.5) * nearW * smoothstep(2.0, 6.0, ad) * (1.0 - t.rock);
    if (steps > 0.0) {
      float q = h / 0.85 + 0.6 * mtnNoise(P / 7.0, seed + 34u);
      float fr = q - floor(q);
      h += steps * 0.085 * (smoothstep(0.55, 1.0, fr) - fr);
    }
    // The tread: a bench, dished a little and tilted outward, with a cut bank above it.
    float hw = s.trailHalf;
    float bench = 1.0 - smoothstep(hw, hw + 0.9, ad);
    float tread = ty - 0.035 * (1.0 - saturate(ad / hw)) - 0.045 * clamp(s.side * d / hw, -1.0, 1.0) + 0.03 * (mtnNoise(P * 1.7, seed + 31u) - 0.5);
    h = mix(h, tread, bench);
    t.rock *= 1.0 - bench;
  }
  t.h = h;
  return t;
}

// ---- baking ----

kernel void mtn_bake_height(texture2d_array<float, access::write> heights [[texture(0)]],
                            texture2d_array<float, access::write> mask [[texture(1)]], constant MountainBake &b [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
  if (gid.x > kMtnGrid || gid.y > kMtnGrid) return;
  MtnTerrain t = mtnTerrain(b.origin + float2(gid) * b.cell, b.cell, b.shape);
  heights.write(float4(t.h, 0, 0, 0), gid, b.level);
  mask.write(float4(t.rock, t.scree, t.gully, 0.0), gid, b.level);
}

kernel void mtn_bake_surface(texture2d_array<float, access::read> heights [[texture(0)]],
                             texture2d_array<float, access::write> surface [[texture(1)]], constant MountainBake &b [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
  if (gid.x > kMtnGrid || gid.y > kMtnGrid) return;
  int2 g = int2(gid);
  const int n = kMtnGrid;
#define MTN_H(dx, dy) heights.read(uint2(clamp(g + int2(dx, dy), 0, n)), b.level).r
  float c = MTN_H(0, 0), l = MTN_H(-1, 0), r = MTN_H(1, 0), dn = MTN_H(0, -1), up = MTN_H(0, 1);
  float sx = (r - l) / (float(min(g.x + 1, n) - max(g.x - 1, 0)) * b.cell);
  float sz = (up - dn) / (float(min(g.y + 1, n) - max(g.y - 1, 0)) * b.cell);
  float3 nrm = normalize(float3(-sx, 1.0, -sz));
  // Hollows are darker (less sky), and are where snow and water gather.
  float lap1 = (l + r + dn + up - 4.0 * c) / b.cell;
  float lap4 = (MTN_H(-4, 0) + MTN_H(4, 0) + MTN_H(0, -4) + MTN_H(0, 4) - 4.0 * c) / (4.0 * b.cell);
  float lap12 = (MTN_H(-12, 0) + MTN_H(12, 0) + MTN_H(0, -12) + MTN_H(0, 12) - 4.0 * c) / (12.0 * b.cell);
#undef MTN_H
  float ao = saturate(1.0 - 0.16 * max(lap1, 0.0) - 0.3 * max(lap4, 0.0) - 0.35 * max(lap12, 0.0));
  surface.write(float4(nrm.x * 0.5 + 0.5, nrm.z * 0.5 + 0.5, ao, saturate(0.5 + 0.25 * (lap4 + lap12))), gid, b.level);
}

/// The baked height at `xz` (relative to the floating origin) in `level`, bilinear.
template <typename T>
static float mtnHeightAt(T heights, float4 lev, float2 xz, int level) {
  float2 q = clamp((xz - lev.xy) / lev.z, 0.0, float(kMtnGrid) - 0.001);
  float2 i = floor(q), f = q - i;
  uint2 c = uint2(i);
  float a = heights.read(c, level).r, b = heights.read(c + uint2(1, 0), level).r;
  float cc = heights.read(c + uint2(0, 1), level).r, d = heights.read(c + uint2(1, 1), level).r;
  return mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
}

/// Whether `xz` lies inside `lev` (with a margin of `margin` cells).
static bool mtnInside(float4 lev, float2 xz, float margin) {
  float2 q = (xz - lev.xy) / lev.z;
  return all(q >= margin) && all(q <= float(kMtnGrid) - margin);
}

kernel void mtn_bake_shadow(texture2d_array<float, access::read> heights [[texture(0)]],
                            texture2d_array<float, access::write> shadow [[texture(1)]], constant MountainUniforms &m [[buffer(0)]],
                            constant int &level [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x > kMtnGrid || gid.y > kMtnGrid) return;
  float4 lev = m.levels[level];
  float2 xz = lev.xy + float2(gid) * lev.z;
  float h0 = heights.read(gid, level).r;
  float3 sun = m.bakedSun;
  float level0 = length(sun.xz);
  if (sun.y <= 0.0 || level0 < 1e-4) {
    shadow.write(float4(sun.y > 0.0 ? 1.0 : 0.0), gid, level);
    return;
  }
  float2 dir = sun.xz / level0;
  float rise = sun.y / level0;
  // Toward the sun in growing steps: the lowest clearance over the ground, as an angle, is how
  // deep in shadow (or how far into the penumbra) the point is.
  float res = 1.0, t = lev.z * 1.5;
  int lv = level;
  for (int i = 0; i < 56; i++) {
    float2 q = xz + dir * t;
    while (lv < kMtnLevels - 1 && !mtnInside(m.levels[lv], q, 1.0)) lv++;
    if (!mtnInside(m.levels[lv], q, 0.0)) break;
    float ray = h0 + rise * t + lev.z * 0.6;
    float clear = ray - mtnHeightAt(heights, m.levels[lv], q, lv);
    res = min(res, clear / (t * 0.014) + 0.5);
    if (res <= 0.0 || ray > 1400.0) break;
    t = t * 1.16 + max(lev.z, m.levels[lv].z) * 0.6;
  }
  shadow.write(float4(saturate(res)), gid, level);
}
