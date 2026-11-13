// Medieval street: the town mesh (houses, bridges, stalls, lanterns, washing, ivy, the street).
// Compiled after SceneShared.h, Common.metal, Plants.h, Plants.metal (the foliage atlas, for the
// ivy) and MedievalScene.h. town_vs bends the street (MedievalPathX); town_fs shades every
// material: light from the strip of sky between the roofs and the facades around
// (townAmbient), reflections of the street canyon (townReflection), lanterns (townLanterns).

struct TownOut {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float3 color;
  float2 uv;
  float material;
};

vertex TownOut town_vs(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(kBufferVertices)]],
                       constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float3 &offset [[buffer(kBufferInstances)]],
                       constant TownUniforms &t [[buffer(kBufferScene)]]) {
  MeshVertex v = verts[vid];
  float3 p = float3(v.p[0], v.p[1], v.p[2]) + offset;
  float3 n = float3(v.n[0], v.n[1], v.n[2]);
  float2 uv = float2(v.uv[0], v.uv[1]);
  if (abs(v.material - kTownCloth) < 0.5 && uv.y < 0) {  // washing and valances sway
    float hang = -uv.y, ph = p.x * 1.7 + p.z * 0.9;
    p.z += hang * (0.05 * sin(u.time * 1.3 + ph) + 0.02 * sin(u.time * 3.1 + ph * 2.0));
  }
  float slope = MedievalPathSlope(p.z, t.bends);
  p.x += MedievalPathX(p.z, t.bends);
  TownOut o;
  o.world = p;
  o.position = u.viewProj * float4(p, 1.0);
  o.normal = normalize(float3(n.x, n.y, n.z - slope * n.x));
  o.color = float3(v.c[0], v.c[1], v.c[2]);
  o.uv = uv;
  o.material = v.material;
  return o;
}

fragment void town_shadow_fs(TownOut in [[stage_in]], texture2d<float> atlas [[texture(kTextureScene)]]) {
  if (in.material >= kTownCard - 0.5) {
    float a = atlas.sample(kAtlasSampler, atlasUV(in.uv, int(in.material - kTownCard + 0.5)), bias(1.0)).a;
    if (a < 0.45) discard_fragment();
  }
}

// ---- helpers ----

static float3 townRGB(float r, float g, float b) {
  return pow(float3(r, g, b) / 255.0, 2.2);
}

static float townSq(float x) {
  return x * x;
}

/// Unit vectors along which uv.x and uv.y grow on the surface (flat pieces: exact).
static void townTangents(float3 world, float2 uv, float3 n, thread float3 &T, thread float3 &B) {
  float3 dpx = dfdx(world), dpy = dfdy(world);
  float2 dux = dfdx(uv), duy = dfdy(uv);
  float det = dux.x * duy.y - dux.y * duy.x;
  if (abs(det) < 1e-14) {
    T = 0;
    B = 0;
    return;
  }
  float3 tt = (dpx * duy.y - dpy * dux.y) / det, bb = (dpy * dux.x - dpx * duy.x) / det;
  T = normalize(tt - n * dot(n, tt) + 1e-7);
  B = normalize(bb - n * dot(n, bb) + 1e-7);
}

/// A block of masonry around a point: how far its nearest edge is, which way is away from it (uv
/// space), a random number for the block.
struct TownBlock {
  float edge;
  float2 away;
  float id;
};

static float townBound(float k, uint row, uint seed, float len) {
  return (k + 0.36 * (hashU(uint3(uint(int(k) + 65536), row, seed ^ 0x5bd1u)) - 0.5)) * len;
}

/// Ashlar: courses of `course` metres, blocks of varied length with staggered joints.
static TownBlock townAshlar(float2 p, float course, uint seed) {
  // Course heights vary: the bed joints are jittered like the head joints.
  float row = floor(p.y / course);
  float r0 = townBound(row, 7u, seed, course), r1 = townBound(row + 1, 7u, seed, course);
  if (p.y < r0) {
    row -= 1;
    r1 = r0;
    r0 = townBound(row, 7u, seed, course);
  } else if (p.y >= r1) {
    row += 1;
    r0 = r1;
    r1 = townBound(row + 1, 7u, seed, course);
  }
  uint rs = uint(int(row) + 4096);
  float len = course * (1.4 + 1.7 * hashU(uint3(rs, seed, 11u)));
  float x = p.x + hashU(uint3(rs, seed, 12u)) * len * 3.0;
  float k = floor(x / len);
  float b0 = townBound(k, rs, seed, len), b1 = townBound(k + 1, rs, seed, len);
  if (x < b0) {
    k -= 1;
    b1 = b0;
    b0 = townBound(k, rs, seed, len);
  } else if (x >= b1) {
    k += 1;
    b0 = b1;
    b1 = townBound(k + 1, rs, seed, len);
  }
  float ex0 = x - b0, ex1 = b1 - x, ey0 = p.y - r0, ey1 = r1 - p.y;
  TownBlock b;
  b.edge = ex0;
  b.away = float2(1, 0);
  if (ex1 < b.edge) {
    b.edge = ex1;
    b.away = float2(-1, 0);
  }
  if (ey0 < b.edge) {
    b.edge = ey0;
    b.away = float2(0, 1);
  }
  if (ey1 < b.edge) {
    b.edge = ey1;
    b.away = float2(0, -1);
  }
  b.id = hashU(uint3(uint(int(k) + 65536), rs, seed ^ 0x9e37u));
  return b;
}

/// The light arriving at a surface in the street (what a white surface would reflect): the strip
/// of sky between the eaves, the facades on both sides (sunlit above the other side's shadow),
/// the street; open sky above the roofs.
static float townWedge(float a, float b, float psiN, float m2, float nz2) {
  float sxy = 0;
  for (int k = -1; k <= 1; k++) {
    float o = psiN + 6.2831853 * float(k);
    sxy += sin(clamp(b - o, -1.5707963, 1.5707963)) - sin(clamp(a - o, -1.5707963, 1.5707963));
  }
  return m2 * 0.5 * sxy + nz2 * (b - a) / 6.2831853;
}

static float3 townAmbient(float3 world, float s, float3 n, constant FrameUniforms &u, constant TownUniforms &t) {
  float H = t.roofHeight, hw = t.halfWidth;
  // y > 0: with fast math, atan2(d, -0.0) comes out as -π/2.
  float x = clamp(s, -hw + 0.02, hw - 0.02), y = clamp(world.y, 0.01, H - 0.3);
  float dR = hw - x, dL = hw + x;
  float rt = atan2(dR, H - y), rb = atan2(dR, -y), lt = -atan2(dL, H - y), lb = -atan2(dL, -y);
  float psiN = atan2(n.x, n.y), m2 = n.x * n.x + n.y * n.y, nz2 = n.z * n.z;
  float fSky = townWedge(lt, rt, psiN, m2, nz2), fR = townWedge(rt, rb, psiN, m2, nz2), fL = townWedge(lb, lt, psiN, m2, nz2);
  float fGround = max(1.0 - fSky - fR - fL, 0.0);
  float3 wall = mix(t.stoneA, t.stoneB, 0.5) * 0.7;
  float3 wallAmbient = u.skyAmbient * 0.45 + u.groundAmbient * 0.3;
  float tanSun = max(u.sunDir.y, 0.0) / max(abs(u.sunDir.x), 1e-3);
  float litWall = saturate(1.0 - max(H - 2.0 * hw * tanSun, 0.0) / H);
  float3 right = wall * (u.sunColor * saturate(-u.sunDir.x) * litWall + wallAmbient);
  float3 left = wall * (u.sunColor * saturate(u.sunDir.x) * litWall + wallAmbient);
  float shadowWidth = H * abs(u.sunDir.x) / max(u.sunDir.y, 1e-3);
  float litStreet = saturate(1.0 - shadowWidth / (2.0 * hw));
  float3 street = 0.15 * (u.skyAmbient * 0.25 + u.sunColor * max(u.sunDir.y, 0.0) * litStreet);
  float3 canyon = u.skyAmbient * fSky + right * fR + left * fL + street * fGround;
  float open = smoothstep(H - 3.0, H + 3.0, world.y);
  return mix(canyon, mix(u.groundAmbient, u.skyAmbient, n.y * 0.5 + 0.5), open);
}

/// What a mirror at `world` shows along `r`: the facade across, the sky above the eaves, the
/// street below, mist far along the street.
static float3 townReflection(float3 world, float s, float3 r, float rough, constant FrameUniforms &u, constant TownUniforms &t) {
  float hw = t.halfWidth, H = t.roofHeight;
  float3 wall = mix(t.stoneA, t.stoneB, 0.5) * 0.6;
  if (r.y < 0) {
    float d = world.y / max(-r.y, 1e-3);
    return mix(0.12 * u.skyAmbient * 0.3, u.fogColor, 1.0 - exp(-u.fogDensity * d));
  }
  s = clamp(s, -hw + 0.02, hw - 0.02);  // under a house set back from the street line too
  float tx = clamp(abs(r.x) > 1e-4 ? ((r.x > 0 ? hw : -hw) - s) / r.x : 1e4, 0.0, 1e4);
  float hy = world.y + r.y * tx;
  // A rough surface blurs the edge between the facade and the sky over it.
  float blur = 1.0 + tx * rough * 0.6;
  float skyward = smoothstep(H - blur, H + blur, hy);
  float3 sky = mix(skyGradient(r, u), fogColorToward(r, u), 1.0 - exp(-u.fogDensity * 300.0));
  float3 wall2 = mix(wall * (u.skyAmbient * (0.12 + 0.3 * saturate(hy / H)) + u.groundAmbient * 0.2), fogColorToward(r, u) * 0.5,
                     1.0 - exp(-u.fogDensity * tx));
  return mix(wall2, sky, skyward);
}

/// The lanterns' light at a point (irradiance on a white surface facing `n`).
static float3 townLanterns(float3 world, float3 n, float wrap, constant FrameUniforms &u, constant TownUniforms &t, const device float4 *lights) {
  if (t.lightPower <= 0) return 0;
  float zAbs = world.z + u.originZ;
  int b = int(floor(zAbs / kLightBucket) - t.lightBase);
  float3 sum = 0;
  const float reach2 = kLightReach * kLightReach;
  for (int i = max(b - 1, 0); i <= min(b + 1, kLightBuckets - 1); i++) {
    for (int k = 0; k < kLightsPerBucket; k++) {
      float4 L = lights[i * kLightsPerBucket + k];
      if (L.w <= 0) continue;
      float3 d = L.xyz - world;
      float dd = dot(d, d);
      if (dd > reach2) continue;
      float3 l = d * rsqrt(dd + 1e-6);
      float ndl = saturate((dot(n, l) + wrap) / (1.0 + wrap));
      sum += ndl * L.w / (dd + 0.12) * townSq(saturate(1.0 - dd / reach2));
    }
  }
  return sum * u.lampColor * t.lightPower * 1.6;
}

// ---- materials ----

/// Masonry from a block pattern: colour per block, mottling, stains, moss, mortar joints, rounded
/// arrises. `px`: metres per pixel (patterns finer than that fade to their average).
static Surface townMasonry(TownBlock b, float2 p, float3 n, float3 world, float px, float3 base, uint seed, float course, constant TownUniforms &t,
                           thread float &cavity) {
  float jw = 0.005 + 0.006 * hashU(uint3(seed, 5u, 5u));
  float joint = 1.0 - smoothstep(jw - px * 0.6, jw + px * 0.6, b.edge);
  float jointFar = saturate(px / (2.0 * jw) - 0.5);
  joint = mix(joint, saturate(2.9 * jw / course), jointFar);
  float blockVis = saturate(2.0 - px / 0.06), mottVis = saturate(2.0 - px / 0.05), speckVis = saturate(2.0 - px / 0.012),
        normVis = saturate(2.0 - px / 0.02);
  float2 off = float2(float(seed % 97u), float(seed % 89u));

  // Each block its own shade, a few yellower or greyer; faces mottled and pitted.
  float bv = b.id - 0.5;
  float3 tint = float3(1.0 + bv * 0.42);
  tint *= mix(float3(1.0), float3(1.06, 1.0, 0.88), step(0.75, fract(b.id * 7.31)));
  tint *= mix(float3(1.0), float3(0.9, 0.96, 0.97), step(0.7, fract(b.id * 13.7)));
  float3 albedo = base * mix(float3(1.0), tint, blockVis);
  float mott = valueNoise(p * 5.0 + b.id * 17.0), pits = valueNoise(p * 28.0 + b.id * 41.0);
  albedo *= 1.0 + (mott - 0.5) * 0.55 * mottVis + (pits - 0.5) * 0.4 * speckVis;
  float coarse = fbm(p * 0.3 + off, 3);
  albedo *= 0.68 + 0.64 * coarse;

  // Weathering: dark streaks run down the wall, algae and moss in soft yellow-green patches
  // where it stays damp, grime at the foot.
  float w = t.weathering;
  float st = valueNoise(float2(p.x * 3.0 + off.x, p.y * 0.11 + off.y)) * 0.7 + valueNoise(float2(p.x * 8.0 + off.y, p.y * 0.35)) * 0.3;
  float streak = smoothstep(0.52, 0.85, st) * w;
  albedo *= 1.0 - 0.55 * streak;
  float foot = saturate(1.0 - world.y / 1.8);
  float green = fbm(p * 0.45 + off * 1.7 + 13.1, 4);
  float moss = smoothstep(0.43, 0.67, green + 0.2 * foot + 0.25 * saturate(n.y) + 0.15 * streak - 0.05) * w;
  albedo = mix(albedo, t.moss * (0.65 + 0.5 * mott + 0.3 * pits * speckVis), moss * 0.8);
  albedo *= 1.0 - 0.35 * foot * w;
  // Mortar: pale and flush in places, weathered out (dark) in others.
  float deep = smoothstep(0.3, 0.7, valueNoise(p * 1.7 + off * 0.3));
  float3 mortar = mix(base * float3(0.86, 0.85, 0.8), base * 0.32, deep);
  albedo = mix(albedo, mix(mortar, t.moss * 0.5, moss * 0.6), joint * mix(1.0, 0.5, jointFar));

  float3 T, B;
  townTangents(world, p, n, T, B);
  float slope = 0.6 * townSq(saturate(1.0 - b.edge / 0.035)) * normVis * (1.0 - joint) * mix(0.4, 1.0, deep);
  float2 g = b.away * slope;
  float3 nn = normalize(n - (T * g.x + B * g.y));
  cavity = 1.0 - 0.55 * joint * deep;
  Surface s = makeSurface(albedo, nn);
  s.occlusion = cavity;
  return s;
}

static Surface townStone(TownOut in, float3 n, float px, constant TownUniforms &t, thread float &cavity) {
  uint seed = uint(in.color.x);
  float course = max(in.color.y, 0.2);
  float3 base = mix(t.stoneA, t.stoneB, in.color.z) * (0.88 + 0.24 * hashU(uint3(seed, 3u, 3u)));
  TownBlock b = townAshlar(in.uv, course, seed);
  return townMasonry(b, in.uv, n, in.world, px, base, seed, course, t, cavity);
}

/// A bridge's face: ashlar, voussoirs around the arch (a keystone at the crown), on a covered
/// passage a row of small arched windows.
static Surface townArchFace(TownOut in, float3 n, float px, constant TownUniforms &t, thread float &cavity) {
  float a = in.color.x, spring = in.color.y;
  uint code = uint(in.color.z), seed = code >> 1;
  bool passage = (code & 1u) != 0;
  float2 p = in.uv;
  float2 q = float2(p.x, max(p.y - spring, 0.0));
  float r = length(q);
  float ring = 0.58;
  float3 base = mix(t.stoneA, t.stoneB, hashU(uint3(seed, 3u, 3u))) * 1.06;
  TownBlock b;
  if (p.y > spring && r < a + ring + 0.15) {
    float mid = a + ring * 0.5;
    float theta = atan2(max(q.y, 1e-4), q.x);
    float count = floor(3.14159 * mid / 0.34 * 0.5) * 2.0 + 1.0;
    float cell = theta / 3.14159 * count, k = floor(cell);
    bool key = abs(k - (count - 1.0) * 0.5) < 0.5;
    float outer = a + ring + (key ? 0.15 : 0.0);
    if (r < outer) {
      float arcW = 3.14159 * mid / count;
      float e0 = fract(cell) * arcW, e1 = (1.0 - fract(cell)) * arcW, e2 = r - a, e3 = outer - r;
      float2 rad = q / max(r, 1e-4), tang = float2(-rad.y, rad.x);
      b.edge = e0;
      b.away = tang;
      if (e1 < b.edge) {
        b.edge = e1;
        b.away = -tang;
      }
      if (e2 < b.edge) {
        b.edge = e2;
        b.away = rad;
      }
      if (e3 < b.edge) {
        b.edge = e3;
        b.away = -rad;
      }
      b.id = hashU(uint3(uint(k), seed, 77u));
      Surface s = townMasonry(b, p, n, in.world, px, base * (key ? 1.08 : 1.03), seed, 0.34, t, cavity);
      return s;
    }
  }
  b = townAshlar(p, 0.34, seed);
  Surface s = townMasonry(b, p, n, in.world, px, base, seed, 0.34, t, cavity);
  if (passage && abs(p.x) < a - 0.3) {
    float y0 = spring + a + 1.0, y1 = y0 + 1.25;
    float cx = (floor(p.x / 1.7 + 0.5)) * 1.7, hwid = 0.3;
    float2 w = float2(p.x - cx, p.y - (y1 - hwid));
    bool inside = abs(w.x) < hwid && p.y > y0 && (w.y < 0 || length(w) < hwid);
    bool frame = abs(w.x) < hwid + 0.1 && p.y > y0 - 0.1 && (w.y < 0 || length(w) < hwid + 0.1);
    if (inside) {
      s.albedo = float3(0.012, 0.011, 0.01);
      s.normal = n;
      s.occlusion = 0.3;
      cavity = 0.3;
    } else if (frame) {
      s.albedo *= 1.12;
    }
  }
  return s;
}

/// Granite setts in rows across the street (running bond), flat-topped with worn arrises, thin
/// dark joints; damp.
static Surface townCobbles(TownOut in, float3 n, float px, constant FrameUniforms &u, constant TownUniforms &t, float sStreet, thread float &cavity) {
  float2 p = in.uv;
  const float rowL = 0.1;
  float row = floor(p.y / rowL);
  uint rs = uint(int(row) + 100000);
  float len = 0.17 + 0.07 * hashU(uint3(rs, 1u, 7u));
  float x = p.x + hashU(uint3(rs, 2u, 7u)) * len * 4.0;
  float k = floor(x / len);
  float b0 = townBound(k, rs, 31u, len), b1 = townBound(k + 1, rs, 31u, len);
  if (x < b0) {
    k -= 1;
    b1 = b0;
    b0 = townBound(k, rs, 31u, len);
  } else if (x >= b1) {
    k += 1;
    b0 = b1;
    b1 = townBound(k + 1, rs, 31u, len);
  }
  uint ks = uint(int(k) + 65536);
  float id = hashU(uint3(ks, rs, 99u));
  // Each stone a little smaller than its cell, shifted, rounder or squarer: irregular joints.
  float2 shrink = float2(hashU(uint3(ks, rs, 96u)), hashU(uint3(ks, rs, 95u))) * 0.006;
  float2 c = float2((b0 + b1) * 0.5, (row + 0.5) * rowL) + (float2(hashU(uint3(ks, rs, 98u)), hashU(uint3(ks, rs, 94u))) - 0.5) * shrink * 1.6;
  float2 q = float2(x, p.y) - c;
  float gap = 0.003 + 0.004 * hashU(uint3(ks, rs, 97u));
  float rad = 0.008 + 0.012 * hashU(uint3(ks, rs, 93u));
  float2 half_ = max(float2((b1 - b0) * 0.5, rowL * 0.5) - gap - shrink - rad, 0.005);
  float2 d = abs(q) - half_;
  float sdf = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - rad;
  float2 grad = (d.x > 0.0 || d.y > 0.0) ? normalize(max(d, 0.0) + 1e-6) * sign(q) : (d.x > d.y ? float2(sign(q.x), 0) : float2(0, sign(q.y)));

  float patternVis = saturate(2.0 - px / 0.03), normVis = saturate(2.0 - px / 0.02);
  float inStone = smoothstep(px * 0.6, -px * 0.6, sdf);
  float gapAvg = 0.12;
  inStone = mix(inStone, 1.0 - gapAvg, 1.0 - patternVis);

  float3 stoneC = townRGB(150, 146, 132);
  float3 tint = float3(0.8 + 0.4 * id) * mix(float3(1.0), float3(0.93, 0.97, 1.04), step(0.6, fract(id * 5.7))) *
                mix(float3(1.0), float3(1.06, 1.0, 0.9), step(0.75, fract(id * 11.3)));
  float3 stone = stoneC * mix(float3(1.0), tint, patternVis);
  float2 pn = float2(p.x, p.y - floor(p.y / 64.0) * 64.0);  // noise inputs kept small (float precision)
  float fine = valueNoise(pn * 40.0 + id * 17.0) * 0.6 + valueNoise(pn * 85.0) * 0.4 * saturate(2.0 - px / 0.006);
  stone *= 1.0 + (fine - 0.5) * 0.4 * saturate(2.0 - px / 0.012);
  float wear = fbm(pn * 0.35, 3);
  stone *= 0.8 + 0.4 * wear;
  float edgeDist = t.halfWidth - abs(sStreet);
  // Joints packed with grit, some nearly flush, some washed out and dark.
  float3 grit = mix(townRGB(92, 86, 74), townRGB(40, 36, 30), smoothstep(0.3, 0.7, valueNoise(pn * float2(9.0, 23.0))));
  float mossy = smoothstep(0.9, 0.1, edgeDist) * t.weathering;
  grit = mix(grit, t.moss * 0.6, mossy * 0.7);
  float3 albedo = mix(grit, stone, inStone);
  albedo *= 1.0 - 0.35 * smoothstep(0.7, 0.0, edgeDist);  // grime along the house fronts

  float3 T, B;
  townTangents(in.world, p, n, T, B);
  float dome = saturate(-sdf / 0.014);
  float slope = 0.8 * townSq(1.0 - dome) * step(sdf, 0.0) * normVis;
  float2 g = -grad * slope;  // the height rises inward (−∇sdf)
  float3 nn = normalize(n - (T * g.x + B * g.y));
  float wet = max(t.damp, u.wetness);
  albedo *= 1.0 - 0.3 * wet;
  cavity = mix(0.55, 1.0, inStone);
  Surface s = makeSurface(albedo, nn);
  s.occlusion = cavity;
  s.specular = mix(0.02, 0.05, wet) * mix(1.6, 1.0, inStone);
  s.roughness = mix(0.85, 0.2, wet) * mix(0.6, 1.0, inStone);
  return s;
}

static Surface townWood(TownOut in, float3 n, float px) {
  float2 p = in.uv;
  float grain = valueNoise(float2(p.x * 2.0, p.y * 30.0)) * 0.6 + valueNoise(float2(p.x * 6.0, p.y * 90.0)) * 0.4 * saturate(2.0 - px / 0.01);
  float3 albedo = in.color * (0.62 + 0.6 * grain);
  float plank = abs(fract(p.y / 0.19) - 0.5) * 0.19;
  albedo *= mix(1.0, 0.55, (1.0 - smoothstep(0.004, 0.009, plank)) * saturate(2.0 - px / 0.006));
  float grey = dot(albedo, float3(0.3, 0.55, 0.15));
  albedo = mix(albedo, grey * float3(0.95, 0.95, 0.9), 0.25);
  return makeSurface(albedo, n);
}

static Surface townCloth(TownOut in, float3 n, float px, constant TownUniforms &t) {
  float2 p = float2(in.uv.x, abs(in.uv.y));
  const float cs = 0.55;
  float2 cell = floor(p / cs);
  float h = hashU(uint3(uint(int(cell.x) + 4096), uint(int(cell.y) + 4096), 5u));
  float patch_ = step(0.65, h);
  float3 albedo = in.color * mix(1.0, 0.6 + 0.7 * hashU(uint3(uint(int(cell.x) + 4096), uint(int(cell.y) + 4096), 6u)), patch_);
  albedo = mix(albedo, dot(albedo, float3(0.33)) * float3(1.08, 1.0, 0.85), patch_ * step(0.85, h) * 0.6);
  float2 f = abs(fract(p / cs) - 0.5) * cs;
  float seam = (1.0 - smoothstep(cs * 0.5 - 0.01, cs * 0.5 - 0.004, max(f.x, f.y))) * patch_;
  albedo *= 1.0 - 0.35 * (1.0 - seam) * patch_ * saturate(2.0 - px / 0.01);
  float weave = valueNoise(p * float2(160.0, 140.0));
  albedo *= 1.0 + (weave - 0.5) * 0.25 * saturate(2.0 - px / 0.004);
  float stain = fbm(p * 1.8 + in.color.xy * 40.0, 3);
  albedo *= 0.78 + 0.35 * stain;
  Surface s = makeSurface(albedo, n);
  s.translucency = 0.35;
  return s;
}

/// Glass in lead cames (diamond quarries) or closed shutters, in a frame; arched heads.
static Surface townWindow(TownOut in, float3 n, float px, constant FrameUniforms &u, thread float3 &emit) {
  uint seed = uint(in.color.x);
  float riseV = in.color.y;
  bool shutters = in.color.z > 0.5;
  float2 p = in.uv;
  float2 fw = max(fwidth(p), 1e-5);
  // The frame follows the arch: an ellipse above v = 1.
  float frameD = min(min(p.x, 1.0 - p.x) / 0.07, p.y / 0.05);
  if (riseV > 0.0 && p.y > 1.0) frameD = min(frameD, (1.0 - length(float2((p.x - 0.5) / 0.5, (p.y - 1.0) / riseV))) / 0.1);
  else frameD = min(frameD, (1.0 + riseV - p.y) / 0.05);
  float frame = 1.0 - smoothstep(0.9, 1.1, frameD);
  emit = 0;
  if (shutters) {
    const float3 paints[5] = {townRGB(70, 82, 64), townRGB(92, 72, 52), townRGB(64, 72, 80), townRGB(96, 52, 40), townRGB(84, 74, 60)};
    float3 paint = paints[seed % 5u];
    float plank = abs(fract(p.x * 6.0) - 0.5) / 6.0;
    float split = abs(p.x - 0.5);
    float3 albedo = paint * (0.75 + 0.4 * valueNoise(float2(p.x * 30.0, p.y * 3.0)));
    albedo *= 1.0 - 0.45 * (1.0 - smoothstep(0.004, 0.01 + fw.x, plank));
    albedo *= 1.0 - 0.6 * (1.0 - smoothstep(0.006, 0.012 + fw.x, split));
    float strap = (1.0 - smoothstep(0.02, 0.03, abs(p.y - 0.18))) + (1.0 - smoothstep(0.02, 0.03, abs(p.y - 0.8)));
    albedo = mix(albedo, float3(0.03), saturate(strap) * step(0.2, abs(p.x - 0.5)));
    albedo = mix(albedo, townRGB(70, 55, 40), frame);
    return makeSurface(albedo, n);
  }
  // Leaded diamonds.
  float2 dq = float2(p.x * 5.0 + p.y * 3.2, p.x * 5.0 - p.y * 3.2);
  float2 cell = floor(dq);
  float2 e = abs(fract(dq) - 0.5);
  float lead = 1.0 - smoothstep(0.42, 0.47, max(e.x, e.y));
  lead *= saturate(2.0 - max(fw.x, fw.y) * 30.0);
  float h = hashU(uint3(uint(int(cell.x) + 512), uint(int(cell.y) + 512), seed));
  float3 glass = float3(0.016, 0.018, 0.015) * (0.7 + 0.6 * h);
  // Each quarry tilts a little: old glass shows the street wavering.
  float3 tilt = float3(hashU(uint3(uint(int(cell.x) + 512), uint(int(cell.y) + 512), seed + 1u)) - 0.5, 0,
                       hashU(uint3(uint(int(cell.x) + 512), uint(int(cell.y) + 512), seed + 2u)) - 0.5) * 0.06;
  float mull = (1.0 - smoothstep(0.025, 0.035, abs(p.x - 0.5))) + (1.0 - smoothstep(0.02, 0.03, abs(p.y - 0.62)));
  float3 albedo = mix(glass, float3(0.035, 0.032, 0.03), lead);
  float wood = saturate(frame + saturate(mull));
  albedo = mix(albedo, townRGB(60, 48, 36), wood);
  Surface s = makeSurface(albedo, normalize(n + tilt));
  s.specular = 0.04 * (1.0 - wood) * (1.0 - lead);
  s.roughness = 0.3;
  if (u.night > 0 && hashU(uint3(seed, 9u, 9u)) < 0.35) emit = u.lampColor * 0.5 * u.night * (1.0 - wood) * (1.0 - lead) * (0.7 + 0.6 * h);
  return s;
}

static Surface townDoor(TownOut in, float3 n, float px) {
  uint seed = uint(in.color.x);
  float2 p = in.uv;
  const float3 woods[3] = {townRGB(72, 52, 36), townRGB(58, 44, 32), townRGB(84, 64, 44)};
  float3 albedo = woods[seed % 3u] * (0.7 + 0.5 * valueNoise(float2(p.x * 22.0, p.y * 2.0)));
  float plank = abs(fract(p.x * 5.0) - 0.5) / 5.0;
  albedo *= 1.0 - 0.5 * (1.0 - smoothstep(0.004, 0.012, plank)) * saturate(2.0 - px / 0.006);
  float strap = (1.0 - smoothstep(0.025, 0.035, abs(p.y - 0.2))) + (1.0 - smoothstep(0.025, 0.035, abs(p.y - 0.78)));
  float side = (seed & 1u) ? p.x : 1.0 - p.x;
  albedo = mix(albedo, float3(0.03, 0.028, 0.026), saturate(strap) * step(side, 0.75));
  float2 stud = abs(fract(p * float2(5.0, 9.0)) - 0.5);
  albedo = mix(albedo, float3(0.04), (1.0 - smoothstep(0.08, 0.14, length(stud))) * saturate(2.0 - px / 0.004));
  float ring = abs(length((p - float2((seed & 1u) ? 0.82 : 0.18, 0.48)) * float2(1.0, 0.55)) - 0.06);
  albedo = mix(albedo, float3(0.03), 1.0 - smoothstep(0.008, 0.016, ring));
  return makeSurface(albedo, n);
}

static Surface townRoof(TownOut in, float3 n, float px, constant TownUniforms &t) {
  uint seed = uint(in.color.x);
  float2 p = in.uv;
  float row = floor(p.y / 0.17);
  float x = p.x / 0.21 + (fmod(row, 2.0) * 0.5);
  float k = floor(x);
  float id = hashU(uint3(uint(int(k) + 65536), uint(int(row) + 4096), seed));
  float fy = fract(p.y / 0.17), fx = fract(x);
  float vis = saturate(2.0 - px / 0.03);
  float3 tiles = mix(townRGB(92, 72, 58), townRGB(70, 66, 60), hashU(uint3(seed, 4u, 4u)));
  float3 albedo = tiles * mix(1.0, 0.75 + 0.5 * id, vis);
  float shade = mix(1.0, 0.55 + 0.45 * smoothstep(0.0, 0.25, fy) * (0.8 + 0.2 * sin(fx * 3.14159)), vis);
  albedo *= shade;
  float lichen = smoothstep(0.55, 0.8, fbm(p * 0.8 + float(seed % 31u), 3)) * t.weathering;
  albedo = mix(albedo, t.moss * 0.8, lichen * 0.6);
  return makeSurface(albedo, n);
}

/// A carved panel: a winged beast, rampant, in a sunken field.
static float townBeast(float2 p) {
  float t;
  float body = length((p - float2(0.48, 0.42)) / float2(0.2, 0.11)) - 1.0;
  body *= 0.11;
  float d = body;
  d = min(d, segDist(p, float2(0.58, 0.47), float2(0.68, 0.66), t) - 0.065);
  d = min(d, length(p - float2(0.7, 0.74)) - 0.07);
  d = min(d, segDist(p, float2(0.74, 0.75), float2(0.84, 0.7), t) - 0.025);
  d = min(d, segDist(p, float2(0.68, 0.79), float2(0.64, 0.88), t) - 0.018);
  // A broad raised wing: a fan of overlapping feathers, smoothly joined.
  float wing = 1e3;
  for (int i = 0; i < 3; i++) {
    float a = 1.8 + 0.32 * float(i);
    wing = min(wing, segDist(p, float2(0.46, 0.52), float2(0.46, 0.52) + float2(cos(a), sin(a)) * (0.34 - 0.04 * float(i)), t) - 0.075 * (1.0 - 0.45 * t));
  }
  d = min(d, wing);
  d = min(d, segDist(p, float2(0.62, 0.42), float2(0.76, 0.52), t) - 0.03);
  d = min(d, segDist(p, float2(0.76, 0.52), float2(0.8, 0.46), t) - 0.02);
  d = min(d, segDist(p, float2(0.58, 0.36), float2(0.64, 0.18), t) - 0.03);
  d = min(d, segDist(p, float2(0.36, 0.36), float2(0.3, 0.16), t) - 0.035);
  d = min(d, segDist(p, float2(0.44, 0.33), float2(0.47, 0.15), t) - 0.03);
  d = min(d, segDist(p, float2(0.3, 0.42), float2(0.14, 0.32), t) - 0.02);
  d = min(d, segDist(p, float2(0.14, 0.32), float2(0.1, 0.46), t) - 0.017);
  d = min(d, p.y - 0.1);
  return d;
}

static Surface townRelief(TownOut in, float3 n, float px, constant TownUniforms &t, thread float &cavity) {
  float2 p = in.uv;
  if (in.color.z < 0) p.x = 1.0 - p.x;
  float d = townBeast(p);
  const float e = 0.006;
  float2 g = float2(townBeast(p + float2(e, 0)) - townBeast(p - float2(e, 0)), townBeast(p + float2(0, e)) - townBeast(p - float2(0, e))) / (2.0 * e);
  float raised = smoothstep(0.01, -0.01, d);
  float edge = saturate(-d / 0.05);
  float slope = (1.0 - edge) * raised * 0.7;
  float3 T, B;
  townTangents(in.world, in.uv, n, T, B);
  if (in.color.z < 0) T = -T;
  float2 grad = -g * slope;
  float3 nn = normalize(n - (T * grad.x + B * grad.y));
  float3 base = mix(t.stoneA, t.stoneB, in.color.y);
  float fine = valueNoise(p * 40.0);
  float3 albedo = base * (0.8 + 0.3 * fine) * mix(0.8, 0.95, raised);
  float green = fbm(p * 3.0 + in.color.x * 0.01, 3);
  albedo = mix(albedo, t.moss * 0.8, smoothstep(0.55, 0.75, green) * t.weathering * 0.7);
  cavity = mix(0.7, 1.0, raised) * mix(1.0, 0.8, (1.0 - edge) * raised);
  Surface s = makeSurface(albedo, nn);
  s.occlusion = cavity;
  return s;
}

/// A half-timbered storey: oak posts at the window pitch (halved in wide bays), a sole plate, a
/// head beam and a rail under the windows, braces in the lower panels; lime plaster between.
static Surface townTimber(TownOut in, float3 n, float px, constant TownUniforms &t, thread float &cavity) {
  float pitch = max(in.color.x, 0.5), H = in.color.z;
  float2 p = float2(in.uv.x - in.color.y, in.uv.y);
  float sub = pitch > 1.7 ? pitch * 0.5 : pitch;
  float cell = floor(p.x / sub), lx = p.x - cell * sub;
  float ex = min(lx, sub - lx);  // to the nearest post's centre
  float aa = max(px, 1e-4);
  float post = 1.0 - smoothstep(0.085 - aa, 0.085 + aa, ex);
  float rail = max(1.0 - smoothstep(0.2 - aa, 0.2 + aa, p.y), smoothstep(H - 0.2 - aa, H - 0.2 + aa, p.y));
  rail = max(rail, 1.0 - smoothstep(0.06 - aa, 0.06 + aa, abs(p.y - 0.84)));
  float brace = 0;
  if (p.y > 0.2 && p.y < 0.8) {
    bool flip = hashU(uint3(uint(int(cell) + 4096), 3u, 3u)) > 0.5;
    float x = flip ? sub - lx : lx;
    float2 a = float2(0.0, 0.2), b = float2(sub * 0.55, 0.8);
    float tt;
    brace = 1.0 - smoothstep(0.06 - aa, 0.06 + aa, segDist(float2(x, p.y), a, b, tt));
  }
  float beam = saturate(max(max(post, rail), brace));
  float grain = valueNoise(float2(p.x * 3.0 + p.y * 9.0, p.y * 30.0));
  float3 oak = townRGB(62, 48, 36) * (0.7 + 0.5 * grain);
  float dirt = fbm(p * 1.3 + float2(in.color.y, 7.0), 3);
  float3 plaster = townRGB(178, 164, 132) * (0.72 + 0.4 * dirt) * (0.9 + 0.2 * valueNoise(p * 14.0) * saturate(2.0 - px / 0.02));
  plaster = mix(plaster, t.moss * 0.9, smoothstep(0.6, 0.8, dirt) * t.weathering * 0.5);
  // Plaster greys toward the timbers, where rain runs off them.
  float nearBeam = 1.0 - smoothstep(0.08, 0.25, min(ex - 0.085, min(abs(p.y - 0.84), min(p.y - 0.2, H - 0.2 - p.y))));
  plaster *= 1.0 - 0.25 * nearBeam * t.weathering;
  float3 albedo = mix(plaster, oak, beam);
  cavity = 1.0 - 0.25 * nearBeam * (1.0 - beam);
  Surface s = makeSurface(albedo, n);
  s.occlusion = cavity;
  return s;
}

/// A shop sign: a faded painted field in a border, a gilded emblem (a ring, a key, a cup, a fish, a boot).
static Surface townSign(TownOut in, float3 n, float px) {
  uint seed = uint(in.color.x);
  float2 p = in.uv;
  const float3 fields[5] = {townRGB(104, 40, 30), townRGB(46, 66, 44), townRGB(44, 54, 74), townRGB(140, 104, 48), townRGB(32, 30, 28)};
  float3 field = fields[seed % 5u] * (0.75 + 0.45 * valueNoise(p * 9.0 + float(seed % 13u)));
  float2 q = (p - 0.5) * float2(1.2, 1.0);
  float tt, d;
  switch ((seed / 5u) % 5u) {
    case 0: d = abs(length(q) - 0.25) - 0.06; break;
    case 1: d = min(abs(length(q - float2(-0.22, 0)) - 0.1) - 0.035, segDist(q, float2(-0.12, 0), float2(0.3, 0), tt) - 0.035);
            d = min(d, segDist(q, float2(0.22, 0), float2(0.22, -0.12), tt) - 0.03); break;
    case 2: d = min(segDist(q, float2(0, 0.08), float2(0, -0.22), tt) - 0.035, length((q - float2(0, 0.15)) / float2(1.0, 0.7)) * 0.7 - 0.13);
            d = min(d, segDist(q, float2(-0.12, -0.24), float2(0.12, -0.24), tt) - 0.03); break;
    case 3: d = min(length((q - float2(0.05, 0)) / float2(1.0, 0.5)) * 0.5 - 0.12, segDist(q, float2(-0.2, 0), float2(-0.32, 0.12), tt) - 0.04);
            d = min(d, segDist(q, float2(-0.2, 0), float2(-0.32, -0.12), tt) - 0.04); break;
    default: d = min(segDist(q, float2(-0.05, 0.25), float2(-0.05, -0.12), tt) - 0.09, segDist(q, float2(-0.05, -0.17), float2(0.22, -0.17), tt) - 0.07); break;
  }
  float aa = max(fwidth(d), 1e-4);
  float emblem = 1.0 - smoothstep(-aa, aa, d);
  float border = 1.0 - smoothstep(0.05, 0.05 + fwidth(p.x) * 2.0, min(min(p.x, 1.0 - p.x), min(p.y, 1.0 - p.y)));
  float wear = smoothstep(0.55, 0.8, valueNoise(p * 14.0 + 3.0));
  float3 gold = townRGB(168, 128, 60) * (0.8 + 0.3 * valueNoise(p * 30.0));
  float3 albedo = mix(field, gold, max(emblem, border * 0.8));
  albedo = mix(albedo, townRGB(70, 56, 42), wear * 0.7);
  Surface s = makeSurface(albedo, n);
  s.specular = 0.03 * max(emblem, border);
  s.roughness = 0.5;
  return s;
}

// ---- the main pass ----

/// sceneColor with the lane's mist: lit by the lane itself near the ground and close by (a
/// fraction of the open sky's light), as bright as the sky far along the street and high up.
static SceneColor townSceneColor(float3 lit, float3 ambientPart, float3 world, float alpha, constant FrameUniforms &u, constant TownUniforms &t) {
  float3 ray = world - u.camPos;
  float dist = length(ray);
  float fog = 1.0 - exp(-fogDepth(u.camPos, ray, u));
  float lane = saturate(dist / 70.0 + max(world.y - 2.0, 0.0) / t.roofHeight * 0.15);
  float3 c = mix(lit, fogColorToward(ray / max(dist, 1e-4), u) * mix(0.2, 1.0, lane), fog);
  const float3 lum = float3(0.2126, 0.7152, 0.0722);
  SceneColor o;
  o.color = float4(c, alpha);
  o.ambient = saturate(dot(ambientPart, lum) * (1.0 - fog) / max(dot(c, lum), 1e-5));
  return o;
}

fragment SceneColor town_fs(TownOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                            constant TownUniforms &t [[buffer(kBufferScene)]], const device float4 *lights [[buffer(kBufferTownLights)]],
                            depth2d_array<float> shadowMap [[texture(kTextureShadow)]], texture2d<float> atlas [[texture(kTextureScene)]]) {
  int m = int(in.material + 0.5);
  float3 n = normalize(in.normal);
  float3 v = normalize(in.world - u.camPos);
  bool twoSided = m == kTownCloth || m == kTownRoof || m >= kTownCard;
  if (twoSided && dot(n, v) > 0) n = -n;
  float px = max(length(fwidth(in.world)), 1e-5);
  float sStreet = in.world.x - MedievalPathX(in.world.z, t.bends);
  float alpha = 1.0, cavity = 1.0, wrap = 0.0;
  float3 emit = 0;
  Surface s;
  if (m >= kTownCard) {
    float2 auv = atlasUV(in.uv, m - kTownCard);
    float4 tx = atlas.sample(kAtlasSampler, auv);
    float lod = atlas.calculate_unclamped_lod(kAtlasSampler, auv);
    float a = tx.a * (1.0 + max(lod, 0.0) * 0.22);
    alpha = saturate((a - 0.5) / max(fwidth(a), 1e-4) + 0.5);
    float3 ivy = townRGB(74, 98, 42) * (0.7 + 0.6 * in.color.y);
    float3 albedo = ivy * tx.r * mix(float3(0.9, 0.95, 1.06), float3(1.12, 1.05, 0.84), tx.g);
    albedo = mix(albedo, float3(0.05, 0.04, 0.03), tx.b);
    s = makeSurface(albedo, n);
    s.occlusion = in.color.x;
    s.translucency = 0.4 * (1.0 - tx.b);
    wrap = 0.4;
  } else if (m == kTownStone) {
    s = townStone(in, n, px, t, cavity);
  } else if (m == kTownSign) {
    s = townSign(in, n, px);
  } else if (m == kTownTimber) {
    s = townTimber(in, n, px, t, cavity);
  } else if (m == kTownArch) {
    s = townArchFace(in, n, px, t, cavity);
  } else if (m == kTownCobble) {
    s = townCobbles(in, n, px, u, t, sStreet, cavity);
  } else if (m == kTownWood) {
    s = townWood(in, n, px);
  } else if (m == kTownCloth) {
    s = townCloth(in, n, px, t);
    wrap = 0.3;
  } else if (m == kTownWindow) {
    s = townWindow(in, n, px, u, emit);
    s.occlusion = 0.6;
  } else if (m == kTownDoor) {
    s = townDoor(in, n, px);
    s.occlusion = 0.7;
  } else if (m == kTownRoof) {
    s = townRoof(in, n, px, t);
  } else if (m == kTownRelief) {
    s = townRelief(in, n, px, t, cavity);
  } else if (m == kTownRecess) {
    float3 albedo = townRGB(40, 34, 28) * (0.7 + 0.5 * valueNoise(in.uv * 3.0));
    s = makeSurface(albedo, n);
    s.occlusion = 0.22;
    uint h = uint(abs(in.uv.x) * 0.5 + 1000.0);
    if (hashU(uint3(h, 3u, 3u)) < 0.5) emit = u.lampColor * 0.08 * u.night * smoothstep(3.0, 0.5, in.world.y);
  } else if (m == kTownIron) {
    float rust = smoothstep(0.55, 0.8, valueNoise(in.world.xy * 23.0 + in.world.z * 17.0));
    s = makeSurface(mix(in.color, townRGB(70, 42, 26), rust * 0.6), n);
    s.specular = 0.04;
    s.roughness = 0.45;
  } else if (m == kTownFlame) {
    float2 p = in.uv;
    float frame = 1.0 - smoothstep(0.05, 0.09, min(min(p.x, 1.0 - p.x), min(p.y, 1.0 - p.y)));
    float glow = exp(-(townSq(p.x - 0.5) * 9.0 + townSq(p.y - 0.42) * 6.0));
    float flicker = 0.9 + 0.1 * sin(u.time * 11.0 + in.world.z * 7.0) * sin(u.time * 7.3 + in.world.x * 5.0);
    s = makeSurface(float3(0.1, 0.085, 0.06) * (1.0 - frame) + 0.03 * frame, n);
    emit = u.lampColor * float3(1.0, 0.7, 0.38) * t.flame * (1.0 - frame) * (0.6 + 10.0 * glow * glow) * flicker;
  } else if (m == kTownJar) {
    float speck = valueNoise(float2(in.uv.x * 60.0, in.uv.y * 160.0));
    s = makeSurface(in.color * (0.6 + 0.7 * speck), n);
    s.specular = 0.045;
    s.roughness = 0.05;
  } else if (m == kTownProduce) {
    s = makeSurface(in.color * (0.85 + 0.3 * valueNoise(in.world.xz * 40.0 + in.world.y * 30.0)), n);
    s.specular = 0.025;
    s.roughness = 0.4;
  } else if (m == kTownWicker) {
    float2 p = float2(in.uv.x * 90.0, in.uv.y * 55.0);
    float weave = step(0.5, fract(p.x * 0.5 + step(0.5, fract(p.y)) * 0.5));
    float strand = sin(fract(p.x) * 3.14159) * sin(fract(p.y) * 3.14159);
    s = makeSurface(in.color * (0.55 + 0.35 * weave + 0.3 * strand), n);
  } else {
    s = makeSurface(in.color, n);
  }
  float shadow = m >= kTownCard ? shadowAt(in.world, n, u, shadowMap) : shadowSoftAt(in.world, n, u, shadowMap);
  float3 ambient = townAmbient(in.world, sStreet, s.normal, u, t);
  float3 env = s.specular > 0 ? townReflection(in.world, sStreet, reflect(v, s.normal), s.roughness, u, t) : float3(0);
  float3 ambientPart;
  float3 col = lightSurfaceIn(u, in.world, s, shadow, ambient, env, ambientPart);
  col += s.albedo * s.occlusion * townLanterns(in.world, s.normal, wrap, u, t, lights) + emit;
  if (m == kTownCloth) col += s.albedo * townAmbient(in.world, sStreet, -s.normal, u, t) * 0.35;  // daylight through the cloth
  return townSceneColor(col, ambientPart, in.world, alpha, u, t);
}
