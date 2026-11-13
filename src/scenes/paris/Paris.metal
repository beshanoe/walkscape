// Paris street: the city mesh (buildings, sidewalks, road). Compiled after SceneShared.h,
// Common.metal, Plants.h, Plants.metal (whose plant shaders draw the trees and props) and
// ParisScene.h. Windows use interior mapping: a room behind each pane, found by ray-casting
// the view direction into a box, plus the sky's reflection.

struct CityOut {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float3 color;
  float2 uv;
  float material;
};

// The city mesh is drawn in three groups, each with its own specialisation of city_fs (the
// function constant), so walls don't carry the windows' code: ParisScene.m sorts the triangles.
constant int kCityGroupValue [[function_constant(0)]];
constant int kCityGroup = is_function_constant_defined(kCityGroupValue) ? kCityGroupValue : -1;

vertex CityOut city_vs(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(kBufferVertices)]],
                       constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float3 &offset [[buffer(kBufferInstances)]]) {
  MeshVertex v = verts[vid];
  CityOut o;
  o.world = float3(v.p[0], v.p[1], v.p[2]) + offset;
  o.position = u.viewProj * float4(o.world, 1.0);
  o.normal = float3(v.n[0], v.n[1], v.n[2]);
  o.color = float3(v.c[0], v.c[1], v.c[2]);
  o.uv = float2(v.uv[0], v.uv[1]);
  o.material = v.material;
  return o;
}

// ---- helpers ----

/// 1 inside the rectangle lo…hi, antialiased over the pixel's footprint.
static float inRect(float2 p, float2 lo, float2 hi) {
  float2 fw = max(fwidth(p), 1e-4);
  float2 a = smoothstep(lo - fw, lo + fw, p) * (1.0 - smoothstep(hi - fw, hi + fw, p));
  return a.x * a.y;
}

/// 1 on lines at multiples of `period`, `halfWidth` wide.
static float lineMask(float x, float period, float halfWidth) {
  float d = abs(fract(x / period + 0.5) - 0.5) * period;
  float fw = max(fwidth(x), 1e-4);
  return 1.0 - smoothstep(halfWidth - fw, halfWidth + fw, d);
}

static float3 srgb(float r, float g, float b) {
  return pow(float3(r, g, b) / 255.0, 2.2);
}

/// Street lamps' light at `world` (night only): the nearest lamps on both sides.
static float3 lampLight(float3 world, float3 n, constant FrameUniforms &u, constant ParisUniforms &p) {
  if (u.night <= 0) return 0;
  float zAbs = world.z + u.originZ;
  float3 sum = 0;
  for (int side = -1; side <= 1; side += 2) {
    float offset = side > 0 ? kLampSpacing * 0.5 : 0.0;
    float k0 = floor((zAbs - offset) / kLampSpacing);
    for (int j = -1; j <= 2; j++) {
      float lz = (k0 + j) * kLampSpacing + offset;
      if (lz - floor(lz / kBlockLength) * kBlockLength < p.crossWidth + 0.5) continue;  // no lamp in a cross street
      float3 d = float3(side * p.lampX, kLampHeight - 0.15, lz - u.originZ) - world;
      float dist2 = dot(d, d);
      float down = 0.12 + 0.88 * saturate(d.y * rsqrt(dist2) * 1.6 + 0.35);  // the lantern's hood: little light upward
      sum += u.lampColor * 20.0 / (dist2 + 2.0) * saturate(dot(n, d * rsqrt(dist2)) * 0.85 + 0.15) * down;
    }
  }
  return sum * u.night;
}

// ---- lettering ----
// Shop signs in a small stroke font (capitals on an 8 × 12 grid), generated; the words are
// ordinary French shop words, no names. Letters: " ABCDEFGHILMNOPQRSTU" (0 is a space).

constant ushort kGlyphSegments[105] = {
  50176, 2244, 22098, 49152, 50880, 43206, 34984, 26248, 26208, 18534, 10312, 1576, 6, 50856, 49862, 41154,
  8352, 544, 1538, 10246, 49152, 50624, 39109, 14488, 1336, 5, 49352, 192, 2048, 26208, 49352, 192,
  26208, 50856, 49862, 41154, 8352, 544, 1538, 10246, 22568, 21592, 49152, 51208, 26720, 50180, 50882, 1538,
  192, 2048, 49152, 25792, 51300, 2248, 49152, 2240, 51208, 8194, 40992, 49824, 50882, 43206, 10408, 1576,
  518, 49152, 50880, 43206, 34984, 26248, 24678, 8194, 40992, 49824, 50882, 43206, 10408, 1576, 518, 2101,
  49152, 50880, 43206, 34984, 26248, 24678, 2148, 50856, 49862, 41154, 32928, 25216, 26210, 18534, 10312, 1576,
  518, 8194, 51392, 1220, 8384, 544, 1538, 10246, 51240,
};
  // x0 | y0 << 4 | x1 << 8 | y1 << 12
constant ushort kGlyphs[19] = {
  768, 2563, 1805, 1556, 1050, 798, 2337, 810, 813, 560, 1074, 822, 2105, 1601, 2375, 1872,
  2903, 610, 1380,
};
  // first segment | count << 8, for letters 1…
constant uchar kSignText[262] = {
  3, 1, 6, 5, 2, 16, 1, 17, 17, 5, 16, 9, 5, 10, 5, 0,
  2, 9, 17, 18, 16, 13, 18, 3, 1, 6, 5, 0, 4, 19, 0, 3,
  13, 9, 12, 2, 1, 16, 0, 18, 1, 2, 1, 3, 16, 5, 17, 18,
  1, 19, 16, 1, 12, 18, 2, 9, 17, 18, 16, 13, 18, 3, 16, 5,
  14, 5, 16, 9, 5, 2, 16, 1, 17, 17, 5, 16, 9, 5, 2, 13,
  19, 10, 1, 12, 7, 5, 16, 9, 5, 14, 1, 18, 9, 17, 17, 5,
  16, 9, 5, 2, 13, 19, 10, 1, 12, 7, 5, 16, 9, 5, 0, 14,
  1, 18, 9, 17, 17, 5, 16, 9, 5, 14, 8, 1, 16, 11, 1, 3,
  9, 5, 2, 13, 19, 18, 9, 15, 19, 5, 11, 13, 4, 5, 3, 8,
  1, 19, 17, 17, 19, 16, 5, 17, 5, 14, 9, 3, 5, 16, 9, 5,
  14, 16, 9, 11, 5, 19, 16, 6, 16, 13, 11, 1, 7, 5, 16, 9,
  5, 5, 14, 9, 3, 5, 16, 9, 5, 0, 6, 9, 12, 5, 10, 9,
  2, 16, 1, 9, 16, 9, 5, 14, 16, 5, 17, 17, 5, 14, 1, 14,
  5, 18, 5, 16, 9, 5, 6, 10, 5, 19, 16, 17, 6, 10, 5, 19,
  16, 9, 17, 18, 5, 9, 11, 11, 13, 2, 9, 10, 9, 5, 16, 13,
  14, 18, 9, 15, 19, 5, 14, 16, 5, 17, 17, 9, 12, 7, 3, 13,
  9, 6, 6, 19, 16, 5,
};

constant ushort kSignWords[29] = {
  4096, 9220, 10253, 12311, 9251, 10284, 7222, 8253, 9285, 11342, 10329, 22627, 9337, 8322, 4234, 10382,
  8344, 7328, 10407, 13489, 9406, 6343, 9421, 6358, 9436, 10469, 7407, 8438, 8446,
};
  // start | length << 10
constant ushort kSignTypes[9] = {
  1280, 1029, 777, 268, 781, 1040, 788, 535, 1049,
};
  // first word | count << 8, by shop type

/// Distance (glyph units) from p to letter `glyph`'s strokes; a space is far from everything.
static float glyphDistance(float2 p, int glyph) {
  if (glyph <= 0) return 1e3;
  ushort g = kGlyphs[glyph - 1];
  int first = g & 0xFF, count = g >> 8;
  float d = 1e3, t;
  for (int i = 0; i < count; i++) {
    ushort sg = kGlyphSegments[first + i];
    d = min(d, segDist(p, float2(sg & 15, (sg >> 4) & 15), float2((sg >> 8) & 15, sg >> 12), t));
  }
  return d;
}

/// Coverage of sign word `word` written across the box lo…hi (metres on the surface), centred,
/// as large as fits. Far away the strokes thin into a faint tint rather than shimmer.
static float signText(float2 q, float2 lo, float2 hi, int word) {
  if (word < 0) return 0.0;
  ushort w = kSignWords[word];
  int start = w & 1023, len = w >> 10;
  float2 size = hi - lo;
  float unit = min(size.y * 0.72 / 12.0, size.x / (len * 10.0 - 2.0));  // metres per glyph unit
  float width = (len * 10.0 - 2.0) * unit;
  float2 p = (q - float2((lo.x + hi.x - width) * 0.5, (lo.y + hi.y) * 0.5 - 6.0 * unit)) / unit;
  float px = max(length(fwidth(q)) / unit, 1e-3);  // glyph units per pixel
  if (p.x < -2.0 || p.x > len * 10.0 || p.y < -2.0 || p.y > 14.0) return 0.0;
  int i = clamp(int(floor((p.x + 1.0) / 10.0)), 0, len - 1);
  float d = glyphDistance(p - float2(i * 10.0, 0), kSignText[start + i]);
  float stroke = 0.85 + 0.3 * saturate(px - 1.0);
  return saturate(0.5 - (d - stroke) / px) * (1.0 - 0.6 * smoothstep(1.5, 4.0, px));
}

// ---- light in the street canyon ----
// The street is a long straight canyon, so the light arriving at a point can be worked out
// exactly in its cross-section: the sky between the two rooflines, the facades across and
// behind (sunlit above the line where the other side's shadow ends), the street below.

/// Cosine-weighted share of the directions around a normal (angle psiN in the cross-section, from
/// straight up toward +x; m2 = nx² + ny², nz2 = nz²) that lie in the wedge a…b of the cross-section.
static float wedgeShare(float a, float b, float psiN, float m2, float nz2) {
  float sxy = 0;
  for (int k = -1; k <= 1; k++) {
    float o = psiN + 6.2831853 * float(k);
    sxy += sin(clamp(b - o, -1.5707963, 1.5707963)) - sin(clamp(a - o, -1.5707963, 1.5707963));
  }
  return m2 * 0.5 * sxy + nz2 * (b - a) / 6.2831853;
}

/// The light arriving at a surface in the street (what a white surface would reflect, in the
/// hemisphere terms' units): sky, sunlit and shaded facades, the street. Open at cross streets.
static float3 canyonAmbient(float3 world, float3 n, constant FrameUniforms &u, constant ParisUniforms &p) {
  float zAbs = world.z + u.originZ;
  float zl = zAbs - floor(zAbs / kBlockLength) * kBlockLength;
  float gap = zl < p.crossWidth ? 0.0 : min(zl - p.crossWidth, kBlockLength - zl);
  float open = max(exp(-gap / (0.7 * p.halfWidth)), smoothstep(p.halfWidth - 0.3, p.halfWidth + 4.0, abs(world.x)));
  float H = p.roofHeight * (1.0 - 0.6 * open);
  // y > 0: with fast math, atan2(d, -0.0) came out as -π/2 on the road and flipped its wedges.
  float x = clamp(world.x, -p.halfWidth + 0.02, p.halfWidth - 0.02), y = max(world.y, 0.01);
  float dR = p.halfWidth - x, dL = p.halfWidth + x;
  float rt = atan2(dR, H - y), rb = atan2(dR, -y), lt = -atan2(dL, H - y), lb = -atan2(dL, -y);
  float psiN = atan2(n.x, n.y), m2 = n.x * n.x + n.y * n.y, nz2 = n.z * n.z;
  float fSky = wedgeShare(lt, rt, psiN, m2, nz2), fR = wedgeShare(rt, rb, psiN, m2, nz2), fL = wedgeShare(lb, lt, psiN, m2, nz2);
  float fGround = max(1.0 - fSky - fR - fL, 0.0);

  // Facades: stone with dark windows; sunlit above the other side's shadow line.
  float3 wall = mix(srgb(220, 207, 180), srgb(196, 192, 182), p.facadeTone) * 0.7;
  float tanSun = max(u.sunDir.y, 0.0) / max(abs(u.sunDir.x), 1e-3);
  float litWall = saturate(1.0 - max(H - 2.0 * p.halfWidth * tanSun, 0.0) / H) * 0.85;  // trees shade the lowest floors
  float3 wallAmbient = u.skyAmbient * 0.35 + u.groundAmbient * 0.4;
  float3 right = wall * (u.sunColor * saturate(-u.sunDir.x) * litWall + wallAmbient);  // the +x side faces −x
  float3 left = wall * (u.sunColor * saturate(u.sunDir.x) * litWall + wallAmbient);
  // The street: sunlit where neither side's shadow reaches.
  float shadowWidth = H * abs(u.sunDir.x) / max(u.sunDir.y, 1e-3);
  float litStreet = saturate(1.0 - shadowWidth / (2.0 * p.halfWidth)) * 0.75;
  float3 street = u.groundAmbient * 0.6 + 0.1 * u.sunColor * max(u.sunDir.y, 0.0) * litStreet;
  return u.skyAmbient * fSky + right * fR + left * fL + street * fGround;
}

// (parisEnvironment and parisLight follow the facade helpers they use.)

/// The facade's stone colour (keep in sync with StoneColor in ParisScene.m).
static float3 stoneColor(uint building, constant ParisUniforms &p) {
  float t = saturate(p.facadeTone + (ParisHashF(building, 9u) - 0.5) * 0.5);
  return mix(srgb(220, 207, 180), srgb(196, 192, 182), t) * (0.9 + 0.14 * ParisHashF(building, 10u));
}

/// A horizontal unit vector along the surface in the direction uv.x grows.
static float3 tangentU(float3 world, float3 n, float2 uv) {
  float3 t = normalize(cross(float3(0, 1, 0), n));
  float3 grad = dfdx(world) * dfdx(uv.x) + dfdy(world) * dfdy(uv.x);
  return dot(t, grad) < 0 ? -t : t;
}

// ---- facade ----

/// An old building's plaster (keep in sync with PlasterColor in ParisScene.m).
static float3 plasterColor(uint building) {
  const float3 palette[6] = {srgb(0xe2, 0xcf, 0xa6), srgb(0xd9, 0xc0, 0x8e), srgb(0xe8, 0xdc, 0xc4),
                             srgb(0xcf, 0xc8, 0xbb), srgb(0xdc, 0xc0, 0xa0), srgb(0xe6, 0xd6, 0xb0)};
  return palette[ParisHash(building, 44u) % 6u] * (0.92 + 0.12 * ParisHashF(building, 45u));
}

static float3 wallColor(uint building, int type, constant ParisUniforms &p) {
  return type == kTypeOld ? plasterColor(building) : stoneColor(building, p);
}

/// Shutter paint (keep in sync with ShutterPaint in ParisScene.m).
static float3 shutterPaint(uint building, int type) {
  const float3 persiennes[4] = {srgb(0xe2, 0xe0, 0xd8), srgb(0xbf, 0xc1, 0xbc), srgb(0xa9, 0xa5, 0x96), srgb(0x8e, 0x92, 0x94)};
  const float3 volets[6] = {srgb(0x5a, 0x6e, 0x7d), srgb(0x46, 0x5f, 0x4b), srgb(0xe1, 0xdc, 0xcd),
                            srgb(0x78, 0x50, 0x40), srgb(0x96, 0xa0, 0xa5), srgb(0x6b, 0x4a, 0x3a)};
  uint h = ParisHash(building, 46u);
  return type == kTypeOld ? volets[h % 6u] : persiennes[h % 4u];
}

/// Where a point of a facade is: its level and bay, the bay's opening, the building.
struct FacadeCell {
  int level, bay, bays, storeys, type, kind;
  bool corner;
  uint building;
  float bw, h, base;
  float2 q;       // from the bay's centre and the level's floor
  float2 lo, hi;  // the bay's opening, the same frame
  int shop;       // ground-floor shops: the kind of shop (kShop…), else -1
  int unitFirst;  // … its unit's first bay (15: a cut corner) and its extent along the facade
  float unit0, unit1;
};

static FacadeCell facadeCell(float2 uv, float3 code, constant ParisUniforms &p) {
  FacadeCell c;
  c.bw = code.x;
  int k = int(code.y + 0.5);
  c.storeys = k % 16;
  c.bays = max((k / 16) % 16, 1);
  c.corner = (k / 256) % 2 == 1;
  c.type = k / 512;
  c.building = uint(code.z + 0.5);
  c.level = 0;
  c.base = 0;
  c.h = ParisLevelHeight(0, c.storeys, c.type);
  for (int i = 0; i < 9 && c.level < 1 + c.storeys && uv.y >= c.base + c.h; i++) {
    c.base += c.h;
    c.level++;
    c.h = ParisLevelHeight(c.level, c.storeys, c.type);
  }
  c.bay = clamp(int(floor(uv.x / c.bw)), 0, c.bays - 1);
  c.q = float2(uv.x - (c.bay + 0.5) * c.bw, uv.y - c.base);
  c.kind = c.level > 0 ? -1 : c.corner ? ParisCornerKind(c.building, p.shops) : ParisBayKind(c.building, c.bay, c.bays, p.shops);
  ParisOpening o = ParisOpeningIn(c.level, c.kind, c.type, c.bw, c.h);
  c.lo = o.lo;
  c.hi = o.hi;
  c.shop = -1;
  if (c.kind == kBayShop || c.kind == kBayCafe) {
    int unit = c.corner ? 15 * 16 + 1 : ParisShopUnit(c.building, c.bay, c.bays);
    c.unitFirst = unit / 16;
    c.shop = ParisShopType(c.building, c.unitFirst);
    float first = c.corner ? 0.0 : float(c.unitFirst);
    c.unit0 = first * c.bw;
    c.unit1 = (first + float(unit % 16)) * c.bw;
  }
  return c;
}

// ---- reflections ----
// A reflected ray in the street meets a facade at x = ±halfWidth (or the street, or the sky):
// the lot table says which building is there, facadeCell what part of it.

/// The street facade at absolute z on side ±1, and z along it.
static bool lotAt(float zAbs, float side, constant ParisUniforms &p, const device ParisLot *lots, thread ParisLot &lot, thread float &along) {
  float block = floor(zAbs / kBlockLength);
  int slot = int(block - p.lotBlock0);
  if (slot < 0 || slot >= int(p.lotBlocks)) return false;
  float zl = zAbs - block * kBlockLength;
  int base = (slot * 2 + (side > 0 ? 1 : 0)) * kLotsPerSide;
  for (int i = 0; i < kLotsPerSide; i++) {
    ParisLot l = lots[base + i];
    if (l.f1 < 0) break;
    if (zl >= l.f0 && zl < l.f1) {
      lot = l;
      along = zl - l.f0;
      return true;
    }
  }
  return false;
}

/// A facade as a reflection shows it: stone sunlit above the other side's shadow line, windows
/// dark with the sky in them (or lit rooms at night), closed shutters, doors.
static float3 reflectedFacade(float3 hit, float side, float3 r, float detail, constant FrameUniforms &u, constant ParisUniforms &p,
                              const device ParisLot *lots) {
  float3 n = float3(-side, 0, 0);
  float tanSun = max(u.sunDir.y, 0.0) / max(abs(u.sunDir.x), 1e-3);
  float sunlit = saturate(dot(n, u.sunDir)) * step(p.roofHeight - 2.0 * p.halfWidth * tanSun, hit.y);
  float3 light = u.sunColor * sunlit * 0.85 + u.skyAmbient * 0.4 + u.groundAmbient * 0.3;
  ParisLot lot;
  float along;
  if (!lotAt(hit.z + u.originZ, side, p, lots, lot, along)) {  // a corner, a cross street, or beyond the table
    return mix(srgb(205, 195, 175), srgb(60, 60, 64), 0.35) * light;
  }
  if (hit.y > lot.height + 0.3) {  // the mansard
    return hit.y < lot.height + 3.3 ? srgb(0x6e, 0x78, 0x83) * (u.skyAmbient * 0.6 + u.sunColor * sunlit * 0.3) : skyGradient(r, u);
  }
  FacadeCell c = facadeCell(float2(along, hit.y), float3(lot.bayWidth, lot.code, lot.building), p);
  float3 wall = wallColor(c.building, c.type, p) * (0.88 + 0.14 * valueNoise(float2(along, hit.y) * 0.7)) * light;
  float opening = inRect(c.q, c.lo, c.hi);
  if (opening < 0.001) return wall;
  opening = mix(0.35, opening, detail);  // a rough surface blurs the windows into the wall
  float3 inside;
  if (c.kind == kBayDoor) {
    inside = srgb(40, 42, 40) * light;
  } else if (ParisShutter(c.building, c.level, c.bay, c.type) == kShutterClosed) {
    inside = shutterPaint(c.building, c.type) * light;
  } else {
    bool shop = c.kind == kBayShop || c.kind == kBayCafe;
    uint room = ParisHash(c.building, uint(c.level * 64 + c.bay));
    float lit = shop ? 0.12 + 0.9 * u.night : step(0.62, ParisHashF(room, 4u)) * smoothstep(0.2, 0.8, u.night);
    float3 glow = lit * float3(1.0, 0.74, 0.45) * (shop ? 0.9 : 0.55);
    inside = mix(u.skyAmbient * 0.04 + glow, skyGradient(reflect(r, n), u), 0.22);
    float frame = 1.0 - inRect(c.q, c.lo + 0.07, c.hi - 0.07);
    inside = mix(inside, srgb(210, 208, 200) * light, frame * 0.8);
  }
  return mix(wall, inside, opening);
}

/// What a mirror at `world` shows along `r`: the facades where the ray meets them, with the
/// plane trees' crowns in front; the street below; the sky above the roofs. Fogged. `roughness`
/// blurs the detail.
static float3 parisEnvironment(float3 world, float3 r, float roughness, constant FrameUniforms &u, constant ParisUniforms &p,
                               const device ParisLot *lots) {
  float side = r.x >= 0 ? 1.0 : -1.0;
  float t = abs(r.x) > 1e-4 ? (side * p.halfWidth - world.x) / r.x : 1e5;
  if (t < 0.02) return skyGradient(r, u);
  float tGround = r.y < -1e-4 ? -world.y / r.y : 1e6;
  float3 col;
  if (tGround > 0 && tGround < t) {  // the street
    t = tGround;
    col = srgb(80, 80, 80) * (u.skyAmbient * 0.45 + u.groundAmbient * 0.5 + u.sunColor * max(u.sunDir.y, 0.0) * 0.35 + u.lampColor * 0.25 * u.night);
  } else {
    float3 hit = world + r * t;
    if (hit.y > p.roofHeight + 3.0 || t > 3000) return skyGradient(r, u);
    col = reflectedFacade(hit, side, r, saturate(1.0 - roughness * 2.0), u, p, lots);
  }
  // The plane trees' crowns (and trunks) where the ray crosses their lines, farther one first.
  if (p.treeX > 0 && abs(r.x) > 1e-4) {
    float3 leaves = srgb(62, 88, 42) * (u.skyAmbient * 0.45 + u.sunColor * max(u.sunDir.y, 0.0) * 0.35);
    for (int k = 0; k < 2; k++) {
      float lineX = (k == 0 ? side : -side) * p.treeX;
      float tl = (lineX - world.x) / r.x;
      if (tl <= 0.05 || tl >= t) continue;
      float3 at = world + r * tl;
      float z = at.z + u.originZ;
      float crown = smoothstep(4.0, 5.5, at.y) * (1.0 - smoothstep(13.0, 16.0, at.y)) * (0.55 + 0.45 * valueNoise(float2(z * 0.35, at.y * 0.4)));
      float trunk = (1.0 - smoothstep(4.5, 5.5, at.y)) * (1.0 - smoothstep(0.2, 0.3, abs(fract(z / 9.0 + 0.5) - 0.5) * 9.0));
      col = mix(col, leaves, saturate(crown * p.treeCover));
      col = mix(col, srgb(70, 62, 50) * (u.skyAmbient * 0.4 + u.groundAmbient * 0.4), trunk * step(0.0, p.treeCover - 0.01) * 0.9);
    }
  }
  return mix(col, fogColorToward(r, u), 1.0 - exp(-fogDepth(world, r * t, u)));
}

/// Light from lit shop windows at night onto a surface near the facade: each window a glowing
/// rectangle, its irradiance worked out exactly (Lambert's formula for a polygon).
static float3 shopLight(float3 world, float3 n, constant FrameUniforms &u, constant ParisUniforms &p, const device ParisLot *lots) {
  if (u.night < 0.05 || world.y > 4.0 || abs(world.x) < p.halfWidth - 5.5 || abs(world.x) > p.halfWidth + 0.05) return 0;
  float side = world.x > 0 ? 1.0 : -1.0;
  ParisLot lot;
  float along;
  if (!lotAt(world.z + u.originZ, side, p, lots, lot, along)) return 0;
  uint lit = uint(lot.litShops), cool = uint(lot.coolShops);
  if (lit == 0) return 0;
  int code = int(lot.code + 0.5), bays = max((code / 16) % 16, 1), type = code / 512;
  int bay = int(floor(along / lot.bayWidth));
  float z0 = world.z - along;  // the facade's start, world z
  float x = side * p.halfWidth, top = type == kTypeOld ? 2.75 : 3.15, halfW = lot.bayWidth * 0.43;
  float3 sum = 0;
  for (int b = max(bay - 1, 0); b <= min(bay + 1, bays - 1); b++) {
    if (!(lit & (1u << b))) continue;
    float zc = z0 + (b + 0.5) * lot.bayWidth;
    float3 q[4] = {float3(x, 0.12, zc - halfW), float3(x, 0.12, zc + halfW), float3(x, top, zc + halfW), float3(x, top, zc - halfW)};
    float e = 0;
    for (int i = 0; i < 4; i++) {
      float3 a = normalize(q[i] - world), c = normalize(q[(i + 1) % 4] - world);
      float3 cr = cross(a, c);
      float len = length(cr);
      if (len > 1e-5) e += acos(clamp(dot(a, c), -1.0, 1.0)) * dot(n, cr / len);
    }
    sum += (cool & (1u << b) ? float3(0.9, 1.0, 1.08) : float3(1.0, 0.8, 0.56)) * abs(e) * 0.5;
  }
  return sum * 0.55 * u.night;
}

/// Street lamps mirrored in wet ground: each a streak stretched toward the camera, tight in
/// puddles, broad on wet asphalt.
static float3 lampStreaks(float3 world, float wet, float roughness, constant FrameUniforms &u, constant ParisUniforms &p) {
  if (u.night <= 0 || wet <= 0) return 0;
  float3 v = normalize(world - u.camPos);
  float az = atan2(v.x, -v.z), el = asin(clamp(v.y, -1.0, 1.0));
  float zAbs = u.camPos.z + u.originZ;
  float3 sum = 0;
  float sh = 0.004 + roughness * 0.03, sv = 0.02 + roughness * 0.25;
  for (int side = -1; side <= 1; side += 2) {
    float offset = side > 0 ? kLampSpacing * 0.5 : 0.0;
    float k0 = floor((zAbs - offset) / kLampSpacing);
    for (int j = -8; j <= 0; j++) {
      float lz = (k0 + j) * kLampSpacing + offset;
      if (lz - floor(lz / kBlockLength) * kBlockLength < p.crossWidth + 0.5) continue;
      float3 image = float3(side * p.lampX, -(kLampHeight - 0.15), lz - u.originZ) - u.camPos;  // the lantern mirrored in the ground
      float dist2 = dot(image, image);
      float3 d = image * rsqrt(dist2);
      float daz = atan2(d.x, -d.z) - az, del = asin(clamp(d.y, -1.0, 1.0)) - el;
      // The lantern's solid angle spread over the lobe's, at most a mirror image.
      float spread = min(1.0, 0.12 / (dist2 * 3.14159 * sh * sv));
      sum += exp(-(daz * daz) / (sh * sh) - (del * del) / (sv * sv)) * spread;
    }
  }
  float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(-v.y), 5.0);  // water
  return u.lampColor * 9.0 * u.night * wet * fresnel * sum;
}

/// A Paris surface lit in the canyon (and by the lamps at night), with its ambient part.
static float3 parisLight(Surface s, float3 world, float shadow, constant FrameUniforms &u, constant ParisUniforms &p, const device ParisLot *lots,
                         thread float3 &ambientPart) {
  // Reflections are traced for the wet street and the props (cars); walls' zinc and iron see the sky.
  bool trace = kCityGroup == kCityGroupGround || kCityGroup < 0;
  float3 r = reflect(normalize(world - u.camPos), s.normal);
  float3 env = s.specular <= 0 ? float3(0) : trace ? parisEnvironment(world, r, s.roughness, u, p, lots) : skyGradient(r, u);
  // Shop windows light the sidewalk and what stands on it (not the walls they're in).
  float3 shops = kCityGroup == kCityGroupGround || kCityGroup < 0 ? shopLight(world, s.normal, u, p, lots) : float3(0);
  return lightSurfaceIn(u, world, s, shadow, canyonAmbient(world, s.normal, u, p), env, ambientPart) +
         s.albedo * (lampLight(world, s.normal, u, p) + shops);
}

// ---- windows ----

/// What you see through a window: a room behind it (interior mapping). `vt` is the view direction
/// in room space (x along the facade, y up, z into the building), `at` the point on the window
/// in room coordinates (metres). `shop`: −1 for a flat, else the kind of shop (its walls, goods
/// and light).
static float3 roomInterior(float3 vt, float2 at, float2 room, uint seed, float lit, int shop, constant FrameUniforms &u) {
  const float depth = 4.5;
  float3 p = float3(at, 0.0);
  float tx = vt.x > 1e-4 ? (room.x - p.x) / vt.x : vt.x < -1e-4 ? -p.x / vt.x : 1e5;
  float ty = vt.y > 1e-4 ? (room.y - p.y) / vt.y : vt.y < -1e-4 ? -p.y / vt.y : 1e5;
  float tz = depth / max(vt.z, 1e-3);
  float t = min(tz, min(tx, ty));
  float3 h = p + vt * t;
  float3 wall = mix(srgb(150, 138, 118), srgb(118, 128, 128), ParisHashF(seed, 1u)) * mix(0.8, 1.15, ParisHashF(seed, 3u));
  float3 lightColor = float3(1.0, 0.74, 0.45);
  float2 w = t == tz ? h.xy : t == tx ? float2(h.z, h.y) : h.xz;  // where on the surface hit
  float cellRnd = ParisHashF(seed, uint(w.x * 4.0) * 31u + uint(w.y * 3.0) + 7u);
  if (shop >= 0) {
    switch (shop) {
      case kShopCafe:
      case kShopRestaurant: wall = srgb(96, 40, 30) * (0.8 + 0.3 * ParisHashF(seed, 5u)); break;
      case kShopBakery: wall = srgb(214, 196, 158); break;
      case kShopPharmacy: wall = srgb(226, 230, 226); lightColor = float3(0.95, 1.0, 1.05); break;
      case kShopFashion: wall = srgb(220, 218, 212); lightColor = float3(1.0, 0.92, 0.8); break;
      case kShopGrocer: wall = srgb(160, 130, 95); break;
      case kShopBooks: wall = srgb(120, 90, 60); break;
      case kShopFlorist: wall = srgb(90, 110, 80); break;
      default: wall = srgb(228, 228, 224); lightColor = float3(0.98, 1.0, 1.03); break;
    }
  }
  float3 c;
  if (t == ty) {
    c = vt.y > 0 ? srgb(205, 200, 190) : shop >= 0 ? srgb(120, 100, 80) * (0.8 + 0.4 * step(0.5, fract(h.x * 2.0 + h.z * 2.0)))
                                                   : srgb(110, 72, 45) * (0.85 + 0.3 * step(0.5, fract(h.x * 1.5 + h.z * 0.2)));  // ceiling, floor
  } else {
    c = t == tz ? wall : wall * 0.82;
    float pick = ParisHashF(seed, 2u);
    if (shop < 0) {
      if (t == tz && pick < 0.45 && abs(h.x - room.x * 0.5) < 0.45 && h.y > 1.3 && h.y < 2.0) c = srgb(60, 45, 35);  // a painting
      else if (t == tz && pick > 0.55 && abs(h.x - room.x * (0.25 + 0.5 * pick)) < 0.55 && h.y < 2.0) c = srgb(55, 38, 28);  // a wardrobe
    } else if (shop == kShopCafe || shop == kShopRestaurant) {  // a zinc bar, bottles on shelves, a mirror
      if (h.y < 1.1 && t == tz) c = srgb(70, 42, 26) * (0.8 + 0.4 * step(0.9, fract(h.x * 1.2)));
      else if (h.y > 1.3 && h.y < 2.1) c = mix(srgb(150, 140, 120), mix(srgb(40, 70, 40), srgb(150, 90, 30), cellRnd), step(0.55, fract(w.x * 9.0)) * step(0.3, fract(w.y * 3.0)));
    } else if (shop == kShopBakery) {  // loaves standing in racks, a glass counter of cakes
      float loaf = ParisHashF(seed, uint(w.x * 14.0) + uint(w.y * 4.0) * 53u + 3u);
      float3 bread = mix(srgb(206, 146, 72), srgb(160, 100, 45), loaf);
      if (t == tz && h.y > 1.15 && h.y < 2.25) c = mix(c * 0.6, bread, step(0.3, fract(w.y * 4.0)) * step(0.22, fract(w.x * 14.0)));
      else if (h.y < 1.05) c = mix(srgb(70, 50, 35), mix(srgb(232, 200, 205), srgb(150, 90, 50), loaf), step(0.55, h.y) * step(0.2, fract(w.x * 9.0)));
    } else if (shop == kShopAgency) {  // a bright office: desks, framed pictures
      if (h.y < 0.75 && t == tz) c = srgb(60, 62, 66) * (0.8 + 0.4 * step(0.5, fract(h.x * 0.8)));
      else if (t == tz && h.y > 1.4 && h.y < 2.0 && fract(h.x * 0.9) < 0.55) c = mix(srgb(90, 110, 140), srgb(200, 170, 120), cellRnd);
    } else if (shop == kShopClosed) {
      c *= 0.3;
    } else {  // shelves of goods: boxes, clothes, books, produce, flowers
      float3 goods;
      float spacing = shop == kShopBooks ? 22.0 : shop == kShopFashion ? 6.0 : 10.0;
      float item = ParisHashF(seed, uint(w.x * spacing) + uint(w.y * 3.0) * 97u + 13u);
      if (shop == kShopPharmacy) goods = mix(srgb(235, 235, 230), mix(srgb(40, 140, 80), srgb(50, 90, 170), item), step(0.6, item));
      else if (shop == kShopGrocer) goods = mix(mix(srgb(200, 40, 30), srgb(230, 150, 30), item), srgb(90, 150, 40), step(0.55, item));
      else if (shop == kShopFlorist) goods = mix(srgb(50, 90, 40), mix(srgb(220, 90, 140), srgb(240, 230, 210), item), step(0.65, cellRnd));
      else goods = mix(srgb(60, 50, 45), mix(srgb(170, 60, 50), srgb(60, 100, 160), item), 0.6 + 0.4 * item) * (0.6 + 0.6 * item);
      float shelf = shop == kShopFashion ? step(h.y, 1.75) * step(0.9, h.y) : step(0.2, fract(w.y * 2.6)) * step(h.y, 2.3);
      c = mix(c, goods, shelf * step(0.08, fract(w.x * spacing)));
    }
  }
  if (shop < 0) {  // flats: mostly warm lamps, some cooler, now and then the blue of a television
    float k = ParisHashF(seed, 9u);
    lightColor = k < 0.68 ? float3(1.0, 0.74, 0.45) : k < 0.9 ? float3(1.0, 0.88, 0.72) : float3(0.55, 0.7, 1.0) * 0.6;
    lit *= 0.6 + 0.6 * ParisHashF(seed, 10u);
  }
  float day = exp(-h.z * 0.28) * (1.0 - 0.9 * u.night);
  float3 light = (u.skyAmbient * 0.3 + u.sunColor * 0.025) * day;
  light += lit * lightColor * (shop >= 0 ? 1.3 : 0.8) * (0.55 + 0.45 * exp(-h.z * 0.2));
  return c * light;
}

/// A pane of glass at `world`: the room behind, mixed with reflections by the Fresnel factor.
static float3 windowGlass(float3 world, float3 n, float3 t, float2 roomAt, float2 room, uint seed, int shop, float shadow,
                          constant FrameUniforms &u, constant ParisUniforms &p, const device ParisLot *lots) {
  float3 v = normalize(world - u.camPos);
  float3 vt = float3(dot(v, t), v.y, dot(v, -n));
  // Shops keep their lights on in the daytime too.
  float lit = shop >= 0 ? (shop == kShopClosed ? 0.0 : 0.35 + 0.25 * u.night) : step(0.62, ParisHashF(seed, 4u)) * smoothstep(0.2, 0.8, u.night);
  float3 inside = roomInterior(vt, roomAt, room, seed, lit, shop, u) * (shop >= 0 ? 0.8 : 1.0);  // shop glass is slightly tinted
  float3 r = reflect(v, n);
  float3 env = parisEnvironment(world, r, 0.0, u, p, lots);  // the buildings across, the trees, the sky
  float fresnel = 0.04 + 0.96 * pow(1.0 - saturate(dot(-v, n)), 5.0);
  float3 col = mix(inside, env, fresnel);
  return col + u.sunColor * shadow * pow(saturate(dot(r, u.sunDir)), 600.0) * 4.0;
}

/// The wall around the openings: ashlar (Haussmann) or plaster (old), weathered; raised window
/// surrounds; the painted shop front and the carriage door's stone frame.
static float3 wallAlbedo(FacadeCell c, float2 uv, constant ParisUniforms &p, thread float &relief) {
  bool old = c.type == kTypeOld;
  float age = ParisAge(c.building);
  float3 stone = stoneColor(c.building, p), base = wallColor(c.building, c.type, p);
  float n1 = valueNoise(uv * float2(0.5, 0.3) + float(c.building % 97u)), n2 = valueNoise(uv * 3.0);
  float3 albedo;
  float joint = 0;
  relief = 0;
  if (old && c.level > 0) {
    // Plaster: broad patches and repairs; stone quoins at the building's edges.
    float patches = fbm(uv * 0.35 + float(c.building % 53u), 3);
    albedo = base * (0.86 + 0.24 * patches) * (0.95 + 0.08 * n2);
    float repair = smoothstep(0.62, 0.66, valueNoise(uv * 0.9 + 7.0));
    albedo = mix(albedo, base * 1.07, repair * 0.6);
    relief = n2 * 0.002 + repair * 0.003;
    float edge = min(uv.x, c.bays * c.bw - uv.x);
    float quoinW = fmod(floor(uv.y / 0.42), 2.0) < 0.5 ? 0.55 : 0.32;
    float quoin = 1.0 - smoothstep(quoinW - 0.01, quoinW + 0.01, edge);
    albedo = mix(albedo, stone * (0.92 + 0.1 * n1), quoin);
    joint = quoin * lineMask(uv.y, 0.42, 0.008);
  } else {
    // Ashlar: courses 0.5 m, blocks 1.2 m staggered, each its own tone; deep rustication low down.
    bool rustic = c.level <= (old ? 0 : 1);
    float course = rustic ? 0.55 : 0.5;
    float row = floor(uv.y / course);
    float col = floor((uv.x + fmod(row, 2.0) * 0.6) / 1.2);
    float tone = ParisHashF(uint(row + 64.0) * 977u + uint(col + 4096.0), c.building);
    albedo = stone * (0.955 + 0.09 * tone) * (0.93 + 0.12 * n1 - 0.05 * n2);
    joint = rustic ? lineMask(uv.y, course, 0.03) : max(lineMask(uv.y, course, 0.005), lineMask(uv.x + fmod(row, 2.0) * 0.6, 1.2, 0.005));
    relief -= joint * (rustic ? 0.025 : 0.004);
  }
  albedo *= 1.0 - (0.22 + 0.15 * age) * joint;

  // Weathering: dirt washed down from every ledge, soot in patches, splashes near the ground.
  float below = c.base + c.h - uv.y;
  float streaks = valueNoise(float2(uv.x * 6.0, uv.y * 0.35)) * 0.6 + valueNoise(float2(uv.x * 19.0, uv.y * 1.1)) * 0.4;
  albedo *= 1.0 - (0.04 + 0.2 * age) * exp(-below / 1.1) * smoothstep(0.35, 0.75, streaks) * step(0.5, float(c.level));
  albedo *= 1.0 - 0.12 * age * smoothstep(0.45, 0.8, fbm(uv * float2(0.2, 0.06) + float(c.building % 31u), 2));
  albedo *= 1.0 - (0.14 + 0.12 * age) * (1.0 - smoothstep(0.0, 1.3, uv.y));
  albedo *= 1.0 - 0.3 * p.wetness * (1.0 - smoothstep(0.0, 0.5, uv.y));  // splashed after rain

  float2 q = c.q, lo = c.lo, hi = c.hi;
  if (c.level >= 1) {  // window surrounds (raised stone, or a painted band on plaster); streaks under the sills
    float2 so = lo - (old ? 0.13 : 0.17), sh = hi + float2(old ? 0.13 : 0.17, c.level == 2 && !old ? 0.5 : 0.2);
    float surround = inRect(q, so, sh) * (1.0 - inRect(q, lo - 0.01, hi + 0.01));
    albedo = mix(albedo, old ? base * 1.12 : stone * 1.05, surround);
    relief += surround * (old ? 0.004 : 0.02);
    float streak = inRect(q, float2(lo.x + 0.1, -2.5), float2(hi.x - 0.1, lo.y - 0.18)) * (0.5 + 0.5 * valueNoise(float2(uv.x * 9.0, uv.y * 0.6)));
    albedo *= 1.0 - (0.06 + 0.12 * age) * streak * smoothstep(-2.5, lo.y - 0.2, q.y);
  }
  if (c.shop >= 0) {  // the shop front: painted woodwork across the unit, a fascia with its name
    float3 paints[8] = {srgb(30, 60, 42), srgb(92, 24, 30), srgb(28, 38, 70), srgb(25, 25, 25), srgb(200, 190, 165), srgb(120, 150, 170),
                        srgb(225, 222, 212), srgb(70, 70, 72)};
    int pick = int(ParisHash(c.building, 23u + uint(c.unitFirst)) % 8u);
    if (c.shop == kShopPharmacy) pick = 6;
    if (c.shop == kShopCafe || c.shop == kShopRestaurant) pick = pick % 4;
    float3 paint = paints[pick];
    if (c.shop == kShopClosed) paint = mix(paint, srgb(120, 118, 112), 0.6);
    float top = old ? c.h - 0.12 : 3.88;
    float2 u2 = float2(uv.x, q.y);
    float fascia = inRect(u2, float2(c.unit0, hi.y + 0.07), float2(c.unit1, top));
    float front = inRect(q, float2(-c.bw * 0.5, 0.0), float2(c.bw * 0.5, hi.y + 0.07));
    albedo = mix(albedo, paint * (0.9 + 0.1 * n2), max(fascia, front));
    relief += max(fascia, front) * 0.01;
    float2 board0 = float2(c.unit0 + 0.25, hi.y + 0.2), board1 = float2(c.unit1 - 0.25, top - 0.12);
    float letters = signText(u2, board0, board1, ParisSignWord(c.building, c.unitFirst, c.shop));
    float light = dot(paint, float3(0.2126, 0.7152, 0.0722)) > 0.3 ? 0.0 : 1.0;
    float3 ink = c.shop == kShopPharmacy ? srgb(30, 140, 70) : light > 0.5 ? srgb(226, 196, 120) : srgb(30, 32, 40);
    albedo = mix(albedo, ink, letters);
  }
  if (c.kind == kBayDoor) {  // the door's stone frame
    float archY = old ? hi.y - 0.7 : 2.9, r = hi.x;
    float ring = length(float2(q.x, q.y - archY));
    float frame = q.y < archY ? inRect(q, lo - 0.22, float2(hi.x + 0.22, archY)) : 1.0 - smoothstep(r + 0.2, r + 0.24, ring);
    albedo = mix(albedo, stone * 1.06, frame);
    relief += frame * 0.02;
  }
  return albedo;
}

/// A window's glass, lit after the frame around it (city_fs).
struct Glass {
  float cover;    // 0 … 1
  float2 roomAt, room;
  uint seed;
  int shop;       // the kind of shop, -1 for a flat
  float curtain;  // net curtains, 0 … 1
};

/// What's set back in an opening: a door, closed shutters, or a window's frame and glazing bars
/// (the surface) with glass between them (`g`).
static Surface openingSurface(CityOut in, float3 n, FacadeCell c, constant ParisUniforms &p, thread Glass &g) {
  float2 q = c.q, lo = c.lo, hi = c.hi, size = hi - lo, w01 = (q - lo) / size;
  bool old = c.type == kTypeOld;
  g.cover = 0;
  if (c.kind == kBayDoor) {  // carriage door: arched, painted, panelled; stone above the arch
    float3 doors[4] = {srgb(32, 48, 40), srgb(34, 40, 56), srgb(58, 34, 32), srgb(46, 42, 38)};
    float3 paint = doors[ParisHash(c.building, 24u) % 4u];
    float archY = old ? hi.y - 0.7 : 2.9, r = hi.x;
    float ring = length(float2(q.x, q.y - archY));
    float arch = q.y < archY ? 1.0 : 1.0 - smoothstep(r - 0.03, r + 0.01, ring);
    float panels = max(lineMask(q.x, r, 0.025), lineMask(q.y, 1.0, 0.025));
    float split = 1.0 - smoothstep(0.012, 0.03, abs(q.x));
    float3 albedo = mix(stoneColor(c.building, p) * 1.04, paint * (1.0 - 0.35 * panels) * (1.0 - 0.6 * split), arch);
    return makeSurface(albedo, bump(n, in.world, -0.01 * panels * arch));
  }
  if (ParisShutter(c.building, c.level, c.bay, c.type) == kShutterClosed) {  // closed shutters: louvres, two leaves
    float louvre = lineMask(q.y, 0.07, 0.012);
    float split = 1.0 - smoothstep(0.008, 0.02, abs(q.x));
    float3 albedo = shutterPaint(c.building, c.type) * (1.0 - 0.3 * louvre) * (1.0 - 0.6 * split) * (0.92 + 0.12 * valueNoise(q * 8.0));
    return makeSurface(albedo, bump(n, in.world, -0.004 * louvre));
  }
  bool shop = c.shop >= 0;
  if (c.shop == kShopClosed) {  // a roller shutter: grey ribs, grime, a few tags
    float rib = lineMask(q.y, 0.075, 0.012);
    float3 metal = srgb(140, 142, 140) * (0.85 + 0.2 * valueNoise(q * float2(1.5, 0.4) + float(c.building % 41u))) * (1.0 - 0.3 * rib);
    metal *= 1.0 - 0.25 * (1.0 - smoothstep(0.1, 0.9, q.y));
    float tag = smoothstep(0.62, 0.66, fbm(q * float2(1.6, 2.4) + float(c.building % 17u) * 3.1, 3)) * step(q.y, 1.8);
    float3 spray = mix(srgb(40, 40, 160), srgb(200, 40, 50), ParisHashF(c.building, 120u + uint(c.bay)));
    return makeSurface(mix(metal, spray, tag * 0.85), bump(n, in.world, -0.004 * rib));
  }
  float frame = 1.0 - inRect(q, lo + 0.07, hi - 0.07);
  float bars;
  if (shop) {
    bars = max(lineMask(q.x - lo.x, size.x / max(round(size.x / 1.1), 1.0), 0.03), lineMask(q.y - (hi.y - 0.62), 100.0, 0.03));
    // The door, in the unit's middle bay: its frame and a push bar.
    int doorBay = c.corner ? c.bay : c.unitFirst + int((c.unit1 - c.unit0) / c.bw + 0.5) / 2;
    if (c.bay == doorBay) {
      float2 d0 = float2(-0.48, lo.y), d1 = float2(0.48, min(hi.y - 0.62, 2.35));
      bars = max(bars, inRect(q, d0 - 0.05, d1 + 0.05) * (1.0 - inRect(q, d0 + 0.02, d1 - 0.02)));
      bars = max(bars, inRect(q, float2(-0.4, 1.0), float2(0.35, 1.05)));
    }
    // An estate agent's or similar: listings on sheets in the window.
    if (c.shop == kShopAgency) {
      float2 sheet = float2(fract((q.x - lo.x) / 0.27), fract((q.y - 1.0) / 0.36));
      float sheets = step(1.0, q.y) * step(q.y, 2.08) * step(0.12, sheet.x) * step(0.1, sheet.y) * step(lo.x + 0.15, q.x) * step(q.x, hi.x - 0.15);
      if (sheets > 0.5) return makeSurface(mix(srgb(236, 236, 232), srgb(90, 110, 150), step(0.62, sheet.y) * step(sheet.y, 0.9) * 0.6), n);
    }
  } else if (old) {  // small panes: two leaves of four
    bars = max(1.0 - smoothstep(0.02, 0.035, abs(q.x)), lineMask(q.y - lo.y, size.y / 4.0, 0.014));
  } else {
    bars = max(1.0 - smoothstep(0.02, 0.04, abs(q.x)), lineMask(q.y - lo.y, size.y / 3.0, 0.018));
  }
  g.cover = 1.0 - saturate(max(frame, bars));
  g.roomAt = float2(q.x + c.bw * 0.5, q.y);
  g.room = float2(c.bw, c.h);
  g.seed = ParisHash(c.building, uint(c.level * 64 + c.bay));
  g.shop = c.shop;
  g.curtain = shop ? 0.0 : ((1.0 - smoothstep(0.18, 0.24, w01.x)) + smoothstep(0.76, 0.82, w01.x)) * step(0.3, ParisHashF(g.seed, 8u)) * 0.65;
  return makeSurface(shop ? srgb(40, 38, 34) : old ? srgb(225, 220, 205) : srgb(215, 212, 202), n);
}

/// A dormer: stone cheeks, a frame, glass.
static Surface dormerSurface(CityOut in, float3 n, constant FrameUniforms &u, thread Glass &g) {
  float2 q = in.uv;
  float pane = inRect(q, float2(0.14, 0.08), float2(0.86, 0.94));
  float frame = saturate(1.0 - inRect(q, float2(0.2, 0.13), float2(0.8, 0.9)) + (1.0 - smoothstep(0.015, 0.03, abs(q.x - 0.5))));
  g.cover = pane * (1.0 - frame);
  g.roomAt = float2(q.x, q.y * 1.5);
  g.room = float2(2.2, 2.4);
  g.seed = uint(abs(in.world.z + u.originZ) * 3.0) + 11u;
  g.shop = -1;
  g.curtain = 0;
  return makeSurface(mix(in.color, srgb(215, 212, 202), pane * frame), n);
}

// ---- railings ----

/// Wrought iron: rails, bars and a row of rings (uv: metres along, 0…1 up).
static float railing(float2 uv) {
  float bars = lineMask(uv.x, 0.11, 0.007);
  float rails = max(max(step(0.92, uv.y), step(uv.y, 0.05)), 1.0 - smoothstep(0.012, 0.022, abs(uv.y - 0.3)));
  float2 c = float2(fract(uv.x / 0.22) * 0.22 - 0.11, uv.y - 0.62);
  float ring = 1.0 - smoothstep(0.006, 0.012, abs(length(c * float2(1.0, 4.5)) - 0.075));
  return saturate(max(max(bars, rails), ring));
}

// ---- ground ----

static float3 groundAlbedo(CityOut in, int material, constant FrameUniforms &u, constant ParisUniforms &p, thread float &puddle,
                           thread float &relief, thread float &water) {
  float zAbs = in.world.z + u.originZ;
  float2 w = float2(in.world.x, zAbs);
  float zl = zAbs - floor(zAbs / kBlockLength) * kBlockLength;
  float ax = abs(in.world.x);
  float n1 = valueNoise(w * 0.5), n2 = valueNoise(w * 6.0);
  puddle = 0;
  relief = 0;
  water = 0;
  // Manhole covers: iron discs with a raised grid, here and there on the road and the sidewalk.
  float2 cell = floor(w / float2(4.0, 11.0));
  float2 centre = (cell + 0.25 + 0.5 * float2(hash21(cell), hash21(cell + 7.3))) * float2(4.0, 11.0);
  float manhole = step(0.82, hash21(cell + 3.1)) * (1.0 - smoothstep(0.3, 0.32, length(w - centre)));
  if (material == kCityCurb) {
    return srgb(120, 118, 112) * (0.85 + 0.2 * n2) * (1.0 - 0.3 * lineMask(zAbs, 1.0, 0.01));
  }
  if (material == kCitySidewalk) {
    float3 c = srgb(84, 84, 82) * (0.88 + 0.16 * n1) * (0.92 + 0.12 * n2);
    float edge = 1.0 - smoothstep(p.curbX + 0.3, p.curbX + 0.34, ax);  // granite edge stones
    c = mix(c, srgb(118, 116, 110) * (0.9 + 0.15 * n2) * (1.0 - 0.3 * lineMask(zAbs, 1.0, 0.01)), edge);
    // Old chewing gum: small dark spots, thicker near benches and doors.
    float2 g = w / 0.22, gc = floor(g);
    float gum = step(0.86, hash21(gc)) * (1.0 - smoothstep(0.035, 0.06, length(fract(g) - 0.5 - (hash21(gc + 1.7) - 0.5) * 0.6)));
    c *= 1.0 - 0.35 * gum * (1.0 - edge);
    c *= 1.0 - 0.12 * smoothstep(0.55, 0.85, fbm(w * 0.4 + 11.0, 2));  // stains
    c = mix(c, srgb(52, 52, 50) * (0.8 + 0.4 * step(0.5, fract(w.x * 6.0) * fract(w.y * 6.0) * 4.0)), manhole);
    relief = n2 * 0.004 + manhole * 0.004 * lineMask(w.x, 0.08, 0.01);
    return c;
  }
  // Road: asphalt or cobbles; granite setts in the gutters.
  float3 c;
  bool main = ax < p.curbX;
  if (p.paving > 0.5) {
    float row = floor(w.y / 0.16);
    float2 cell = float2((w.x + fmod(row, 2.0) * 0.06) / 0.12, w.y / 0.16);
    float2 f = fract(cell);
    float stoneEdge = max(1.0 - smoothstep(0.0, 0.12, min(f.x, 1.0 - f.x)), 1.0 - smoothstep(0.0, 0.1, min(f.y, 1.0 - f.y)));
    float tone = hash21(floor(cell));
    c = mix(srgb(70, 68, 66), srgb(105, 98, 90), tone) * (1.0 - 0.55 * stoneEdge);
    relief = (1.0 - stoneEdge) * 0.008;
  } else {
    c = srgb(90, 90, 91) * (0.85 + 0.25 * n1) * (0.9 + 0.18 * n2);
    c *= 1.0 - 0.15 * smoothstep(0.55, 0.75, valueNoise(w * 0.15));  // patched tar
    relief = n2 * 0.002;
  }
  if (main && ax > p.curbX - 0.35) {  // the gutter: granite setts, water running along the curb here and there, drains
    c = srgb(110, 108, 102) * (0.8 + 0.3 * n2) * (1.0 - 0.4 * lineMask(zAbs, 0.2, 0.02));
    float side = in.world.x > 0 ? 1.0 : 0.0;
    water = (1.0 - smoothstep(0.08, 0.16, p.curbX - ax)) * step(0.45, hash21(float2(floor(zAbs / 23.0), side)));
    float drain = step(fract(zAbs / 24.0 + side * 0.37) * 24.0, 0.9) * step(ax, p.curbX - 0.03) * step(p.curbX - 0.3, ax);
    c = mix(c, srgb(28, 28, 28) * (1.0 - 0.7 * lineMask(zAbs, 0.07, 0.014)), drain);
    water *= 1.0 - drain;
  }
  if (main) c = mix(c, srgb(48, 48, 46) * (0.8 + 0.4 * step(0.5, fract(w.x * 6.0) * fract(w.y * 6.0) * 4.0)), manhole);
  float paint = 0;
  // Parking lanes: a dashed line along the lane and a tick between bays.
  float lane = p.curbX - 2.05;
  bool parked = p.parking > 1.5 || (p.parking > 0.5 && in.world.x < 0);
  if (main && parked && zl > p.crossWidth + 6.0) {
    float dash = inRect(float2(ax, fract(zAbs / 1.2) * 1.2), float2(lane - 0.06, 0.0), float2(lane + 0.06, 0.6));
    float tick = inRect(float2(ax, fract(zAbs / 5.4) * 5.4), float2(lane, 0.0), float2(p.curbX - 0.4, 0.12));
    paint = max(dash, tick);
  }
  if (main && p.centerLine > 0.5 && zl > p.crossWidth + 5.0) paint = inRect(float2(in.world.x, fract(zAbs / 9.0) * 9.0), float2(-0.07, 0.0), float2(0.07, 4.5));
  if (main && zl > p.crossWidth + 0.8 && zl < p.crossWidth + 4.8 && ax < p.curbX - 0.5) paint = step(0.5, fract(in.world.x / 1.0 + 0.25));
  if (!main && zl > 2.3 && zl < p.crossWidth - 2.3 && ax > p.curbX + 0.8 && ax < p.curbX + 4.2) paint = step(0.5, fract(zAbs / 1.0));
  c = mix(c, srgb(200, 200, 195) * (0.8 + 0.2 * n2), paint * 0.92);
  puddle = smoothstep(0.62, 0.72, valueNoise(w * 0.35) + (n2 - 0.5) * 0.1) * (1.0 - paint);
  return c;
}

fragment SceneColor city_fs(CityOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                            constant ParisUniforms &p [[buffer(kBufferScene)]], const device ParisLot *lots [[buffer(kBufferLots)]],
                            depth2d_array<float> shadowMap [[texture(kTextureShadow)]]) {
  float3 n = normalize(in.normal);
  int material = int(in.material + 0.5);
  float shadow = shadowSoftAt(in.world, n, u, shadowMap);
  float alpha = 1.0;
  Surface s = makeSurface(in.color, n);
  Glass g;
  g.cover = 0;
  if (kCityGroup == kCityGroupGlass) {
    s = material == kCityWindow ? openingSurface(in, n, facadeCell(in.uv, in.color, p), p, g) : dormerSurface(in, n, u, g);
  } else if (kCityGroup == kCityGroupGround) {
    float relief, puddle, water;
    s.albedo = groundAlbedo(in, material, u, p, puddle, relief, water);
    s.normal = bump(n, in.world, relief);
    float wet = max(u.wetness, water);
    if (wet > 0) {  // wet streets: darker, a sheen, puddles on the road; the gutter's running water
      float pool = material == kCityRoad ? max(puddle * u.wetness, water) : 0.0;
      s.albedo *= (1.0 - 0.35 * wet) * (1.0 - 0.4 * pool);
      s.specular = 0.02;
      s.roughness = mix(0.55, 0.03, pool);
      s.normal = normalize(mix(s.normal, float3(0, 1, 0), pool));
    }
  } else if (material == kCityFacade) {
    FacadeCell c = facadeCell(in.uv, in.color, p);
    float relief;
    float3 albedo = wallAlbedo(c, in.uv, p, relief);
    s = makeSurface(albedo, bump(n, in.world, relief));
  } else if (material == kCityReveal || material == kCityShutter) {
    float3 w = in.world + float3(0, 0, u.originZ);
    s.albedo *= 0.9 + 0.15 * valueNoise(float2(w.x + w.z, w.y) * 4.0);
    if (material == kCityShutter) {
      float louvre = lineMask(in.uv.y, 0.07, 0.012);
      s.albedo *= 1.0 - 0.3 * louvre;
      s.normal = bump(n, in.world, -0.004 * louvre);
    } else {
      s.occlusion = 1.0 - 0.3 * saturate(in.uv.y);
    }
  } else {
    if ((material == kCityAwning || material == kCityRailing) && dot(n, u.camPos - in.world) < 0) n = -n;  // thin: lit from the side we see
    s.normal = n;
    if (material == kCityTrim || material == kCityPlain) {
      float3 w = in.world + float3(0, 0, u.originZ);
      s.albedo *= 0.9 + 0.15 * valueNoise(float2(w.x + w.z, w.y) * 1.5);
    } else if (material == kCityZinc) {
      float seam = lineMask(in.uv.x, 0.55, 0.012);
      s.albedo *= (0.9 + 0.1 * valueNoise(in.uv * float2(2.0, 0.5))) * (1.0 + 0.25 * seam);
      s.normal = bump(n, in.world, seam * 0.01);
      s.specular = 0.05;
      s.roughness = 0.45;
    } else if (material == kCityRailing) {
      alpha = railing(in.uv);
      s.albedo = srgb(16, 17, 18);
      s.specular = 0.04;
      s.roughness = 0.5;
    } else if (material == kCityAwning) {
      float stripes = step(0.6, ParisHashF(uint(in.color.x * 1000.0 + in.color.y * 300.0), 3u)) * step(0.5, fract(in.uv.x / 0.25));
      s.albedo = mix(s.albedo, srgb(215, 205, 180), stripes * 0.6);
      s.translucency = 0.6 * (1.0 - 0.4 * u.wetness);
      s.albedo *= 1.0 - 0.3 * u.wetness;
      if (in.uv.y >= 1.5) {  // the valance: uv.y = 2 + 2 (word + 32 × width in dm) + (0…1 up); the name printed on it
        int k = int(floor((in.uv.y - 2.0) / 2.0));
        float v = in.uv.y - 2.0 - 2.0 * float(k), width = float(k / 32) * 0.1;
        float text = signText(float2(in.uv.x, v * 0.25), float2(0.2, 0.04), float2(width - 0.2, 0.21), k % 32);
        s.albedo = mix(s.albedo, srgb(232, 224, 204), text);
      }
    } else if (material == kCityGlow) {  // lit signs: bright by day, glowing at night
      s.emission = in.color * (0.35 + 1.6 * u.night);
      s.albedo = in.color * 0.6;
    }
  }
  float3 ambientPart;
  float3 col = parisLight(s, in.world, shadow, u, p, lots, ambientPart);
  if (kCityGroup == kCityGroupGround && s.specular > 0) col += lampStreaks(in.world, max(u.wetness, s.roughness < 0.1 ? 1.0 : 0.0), s.roughness, u, p);
  if (kCityGroup == kCityGroupGlass && g.cover > 0.001) {
    float3 pane = windowGlass(in.world, n, tangentU(in.world, n, in.uv), g.roomAt, g.room, g.seed, g.shop, shadow, u, p, lots);
    float3 net = srgb(235, 232, 222) * (u.skyAmbient * 0.35 + float3(1.0, 0.74, 0.45) * 0.6 * u.night * step(0.62, ParisHashF(g.seed, 4u)));
    pane = mix(pane, net, g.curtain);
    col = mix(col, pane, g.cover);
    ambientPart *= 1.0 - g.cover;
  }
  return sceneColor(col, ambientPart, in.world, alpha, u);
}

// ---- props and trees (the forest's plant meshes and surfaces, lit in the canyon) ----

fragment SceneColor paris_prop_fs(PlantOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                                  constant PlantUniforms &f [[buffer(kBufferScene)]], constant ParisUniforms &p [[buffer(kBufferParis)]],
                                  const device ParisLot *lots [[buffer(kBufferLots)]],
                                  depth2d_array<float> shadowMap [[texture(kTextureShadow)]], texture2d<float> atlas [[texture(kTextureScene)]]) {
  float alpha;
  Surface s = plantSurface(in, u, f, atlas, alpha);
  if (abs(in.material - kMaterialBark) < 0.5) {  // plane bark: patches of cream and olive where the old bark flaked off
    float2 b = float2(in.uv.x * 9.0, in.uv.y * 2.6);
    float flake = fbm(b, 3), green = valueNoise(b * 1.7 + 5.0), dark = valueNoise(b * 0.6 + 9.0);
    float3 bark = srgb(128, 124, 104) * (0.92 + 0.12 * valueNoise(b * 6.0));
    bark = mix(bark, srgb(184, 178, 148), smoothstep(0.5, 0.6, flake) * 0.85);
    bark = mix(bark, srgb(146, 146, 112), smoothstep(0.58, 0.68, green) * (1.0 - smoothstep(0.5, 0.6, flake)) * 0.8);
    bark = mix(bark, srgb(96, 90, 76), smoothstep(0.64, 0.74, dark) * 0.6);
    s.albedo = bark * in.bright * (1.0 - 0.15 * (1.0 - smoothstep(0.0, 1.5, in.uv.y))) * (1.0 - 0.25 * u.wetness);
  }
  // Leaves take the plain shadow filter: inside a crown the soft one costs much and shows little.
  bool leaf = in.material >= kMaterialCard - 0.5;
  float shadow = leaf ? shadowAt(in.world, normalize(in.normal), u, shadowMap) : shadowSoftAt(in.world, normalize(in.normal), u, shadowMap);
  float3 ambientPart;
  float3 col = parisLight(s, in.world, shadow, u, p, lots, ambientPart);
  return sceneColor(col, ambientPart, in.world, alpha, u);
}

fragment void city_shadow_fs(CityOut in [[stage_in]]) {
  if (int(in.material + 0.5) == kCityRailing && railing(in.uv) < 0.5) discard_fragment();
}
