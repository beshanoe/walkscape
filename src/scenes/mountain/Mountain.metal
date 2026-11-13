// Mountain trail: drawing. Compiled after SceneShared.h, Common.metal, Plants.h, Plants.metal,
// CoastSky.h, CoastSky.metal, MountainScene.h and MountainTerrain.metal.
//
//   mtn_terrain_vs / _fs  the clipmap's levels, block by block: heights from the baked array,
//                         each level's rim morphing into the coarser one under it; materials
//                         from the baked normal, masks and height (turf, flowers, limestone,
//                         scree, snow, forest far below, the trail's rubble), lit by the sun
//                         past the baked terrain shadow, the clouds' shadows and, near the
//                         camera, the host's shadow map
//   mtn_prop_fs           stones, plants and props (the kit's plant pipeline) in the same light
//   mtnAir                the air between: blue with distance, mist lying in the valley, and
//                         the sky's own colour at the far end, so the last ridge meets the sky

// ---- detail noise ----
// Fine patterns (gravel, blades) need more precision than a float keeps kilometres from the
// origin, so they are drawn in (x, z modulo 4096 m) and repeat every 4096 m along the walk.

static float2 mtnWrapped(float3 world, constant MountainUniforms &m) {
  float z = world.z + m.wrapZ;
  return float2(world.x, z - 4096.0 * floor(z / 4096.0));
}

// A flat pattern on ground seen at a glance is squeezed along the view into streaks; real grass
// and stones stand up and don't. The camera always looks along the trail (z), so patterns can
// be drawn `along` times longer in z (0.4: 2.5 times) and look round again from where it stands.

/// Value noise 0 … 1 with about `freq` cells per metre (× `along` in z), repeating every 4096 m in z.
static float mtnDetail(float2 p, float freq, uint seed, float along) {
  float per = max(round(4096.0 * freq * along), 1.0);
  float2 q = float2(p.x * freq, p.y * (per / 4096.0));
  float2 i = floor(q), f = q - i;
  float2 w = f * f * (3.0 - 2.0 * f);
  int n = int(per);
  int y0 = ((int(i.y) % n) + n) % n, y1 = (y0 + 1) % n;
  uint x0 = uint(int(i.x) + 1048576);
  float a = hashU(uint3(x0, uint(y0), seed)), b = hashU(uint3(x0 + 1u, uint(y0), seed));
  float c = hashU(uint3(x0, uint(y1), seed)), d = hashU(uint3(x0 + 1u, uint(y1), seed));
  return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

/// Scattered things (stones, tufts): a jittered grid of about `freq` cells per metre. x: 0 at a
/// cell's rim … 1 in its middle, y: a random number per cell, z: the distance to the cell's
/// centre in cells (round blobs: 1 - smoothstep(r0, r1, z)).
static float mtnDetail(float2 p, float freq, uint seed) {
  return mtnDetail(p, freq, seed, 1.0);
}

static float3 mtnStones(float2 p, float freq, uint seed, float along) {
  float per = max(round(4096.0 * freq * along), 1.0);
  float2 q = float2(p.x * freq, p.y * (per / 4096.0));
  float2 i = floor(q), f = q - i;
  int n = int(per);
  float d1 = 9.0, d2 = 9.0, id = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int k = -1; k <= 1; k++) {
      uint3 key = uint3(uint(int(i.x) + k + 1048576), uint((((int(i.y) + j) % n) + n) % n), seed);
      float2 at = float2(k, j) + 0.15 + 0.7 * float2(hashU(key), hashU(key + uint3(0, 0, 1)));
      float dd = length(at - f);
      if (dd < d1) {
        d2 = d1;
        d1 = dd;
        id = hashU(key + uint3(0, 0, 2));
      } else if (dd < d2) {
        d2 = dd;
      }
    }
  }
  return float3(smoothstep(0.0, 0.35, d2 - d1), id, d1);
}

static float max3(float3 c) {
  return max(max(c.x, c.y), c.z);
}

/// How much of a pattern with `freq` cells per metre survives when a pixel covers `foot` metres:
/// all of it at five pixels per cell, none below two (it would only shimmer).
static float mtnSeen(float freq, float foot) {
  return saturate(1.65 - 3.3 * foot * freq);
}

static float3 mtnStones(float2 p, float freq, uint seed) {
  return mtnStones(p, freq, seed, 1.0);
}

// ---- the air ----

/// `col` at `world` seen through the air: thin air scatters blue (far slopes turn blue, pale
/// rock a little warm), mist fills the valley on a cold morning, and at the far end of the
/// terrain everything fades into the sky's own horizon.
static float3 mtnAir(float3 col, float3 world, constant FrameUniforms &u, constant MountainUniforms &m, texture2d<float> clouds) {
  float3 ray = world - u.camPos;
  float dist = length(ray);
  float3 dir = ray / max(dist, 1e-3);
  if (m.mist > 0.0 && world.y < m.mistTop + 90.0) {
    // The mist's top billows; the ray enters it where it crosses the top.
    float tt = clamp((u.camPos.y - m.mistTop) / max(u.camPos.y - world.y, 1.0), 0.0, 1.0);
    float3 entry = u.camPos + ray * tt;
    float2 q = (entry.xz + float2(0.0, u.originZ)) * (1.0 / 5200.0) + u.time * float2(0.0006, 0.0002);
    float4 nz = clouds.sample(kCloudSampler, q, level(log2(max(dist * tt / u.projScale * 0.1, 1.0))));
    float4 nz2 = clouds.sample(kCloudSampler, q * 3.7 + 0.31, level(log2(max(dist * tt / u.projScale * 0.37, 1.0))));
    float top = m.mistTop + 240.0 * (nz.r - 0.5) + 110.0 * (nz2.g - 0.5);
    float inside = max(top - world.y, 0.0) * dist / max(u.camPos.y - world.y, 1.0);
    float a = (1.0 - exp(-inside * 0.006)) * m.mist;
    // Its swells catch the sun on the side facing it.
    float4 nzs = clouds.sample(kCloudSampler, q + u.sunDir.xz * 0.012, level(1.0));
    float lit = 0.62 + 1.6 * (nz.r - nzs.r) + 0.5 * (nz2.g - 0.5) + 0.3 * (nz.r - 0.5);
    float3 mistCol = (u.skyAmbient * 0.75 + u.sunColor * 0.22 * saturate(u.sunDir.y * 2.0 + 0.2)) * lit;
    col = mix(col, mistCol, a);
  }
  float od = fogDepth(u.camPos, ray, u);
  float3 through = exp(-od * float3(0.5, 1.0, 1.9));
  col = col * through + coastHazeColor(dir, u) * (1.0 - through);
  float end = smoothstep(24000.0, 40000.0, dist);
  if (end > 0.0) col = mix(col, coastSky(float3(dir.x, max(dir.y, 0.0), dir.z), u, clouds, 0, 0.0, 0.0), end);
  return col;
}

// ---- the terrain ----

struct MtnVertexOut {
  float4 position [[position]];
  float3 world;
  float level [[flat]];
  float clip [[clip_distance]][1];
};

struct MtnFragmentIn {
  float4 position [[position]];
  float3 world;
  float level [[flat]];
};

/// How far a level's point (in cells) has morphed into the next coarser level: 0 inside, 1 at the rim.
static float mtnMorph(float2 g, int level) {
  if (level >= kMtnLevels - 1) return 0.0;
  float2 e = abs(g - float(kMtnGrid / 2)) / float(kMtnGrid / 2);
  return smoothstep(0.84, 0.965, max(e.x, e.y));
}

vertex MtnVertexOut mtn_terrain_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device MountainBlock *blocks [[buffer(kBufferInstances)]],
                                   constant FrameUniforms &u [[buffer(kBufferFrame)]], constant MountainUniforms &m [[buffer(kBufferMountain)]],
                                   texture2d_array<float> heights [[texture(0)]]) {
  float4 b = blocks[iid].block;
  int level = int(b.z);
  float4 lev = m.levels[level];
  uint2 cell = uint2(b.xy) + uint2(vid % uint(kMtnBlock + 1), vid / uint(kMtnBlock + 1));
  float2 xz = lev.xy + float2(cell) * lev.z;
  float h = heights.read(cell, level).r;
  float morph = mtnMorph(float2(cell), level);
  if (morph > 0.0) h = mix(h, mtnHeightAt(heights, m.levels[level + 1], xz, level + 1), morph);
  // The earth is round: far ridges sink behind the horizon.
  float2 away = xz - u.camPos.xz;
  MtnVertexOut o;
  o.world = float3(xz.x, h - dot(away, away) * (0.5 / kMtnEarthRadius), xz.y);
  o.position = u.viewProj * float4(o.world, 1.0);
  o.level = float(level);
  // The finer level covers the middle (but for a rim this one still draws under it).
  o.clip[0] = 1.0;
  if (level > 0) {
    float4 fine = m.levels[level - 1];
    float2 lo = fine.xy + float(kMtnOverlap) * fine.z, hi = fine.xy + float(kMtnGrid - kMtnOverlap) * fine.z;
    o.clip[0] = -min(min(xz.x - lo.x, hi.x - xz.x), min(xz.y - lo.y, hi.y - xz.y));
  }
  return o;
}

static float2 mtnLevelUV(float3 world, float4 lev) {
  return ((world.xz - lev.xy) / lev.z + 0.5) / float(kMtnGrid + 1);
}

static float3 mtnHex(float r, float g, float b) {
  return pow(float3(r, g, b) / 255.0, 2.2);
}

/// What the baked terrain says at `world`: normal, occlusion, curvature, masks and the terrain's
/// own shadow, each level blended into the coarser one at its rim.
struct MtnGround {
  float3 normal;
  float ao, hollow;  // hollow: 0.5 flat, more in a hollow, less on a ridge
  float rock, scree, gully;
  float sun;         // 0 in the terrain's shadow … 1
};

static MtnGround mtnGround(float3 world, int level, constant MountainUniforms &m, texture2d_array<float> surface,
                           texture2d_array<float> mask, texture2d_array<float> sunShadow) {
  float4 lev = m.levels[level];
  float morph = mtnMorph((world.xz - lev.xy) / lev.z, level);
  float2 uv = mtnLevelUV(world, lev);
  float4 sf = surface.sample(kLinearClamp, uv, level), mk = mask.sample(kLinearClamp, uv, level);
  int coarse = min(level + 1, kMtnLevels - 1);
  float2 uv2 = mtnLevelUV(world, m.levels[coarse]);
  if (morph > 0.0) {
    sf = mix(sf, surface.sample(kLinearClamp, uv2, coarse), morph);
    mk = mix(mk, mask.sample(kLinearClamp, uv2, coarse), morph);
  }
  MtnGround g;
  float2 nxz = sf.xy * 2.0 - 1.0;
  g.normal = float3(nxz.x, sqrt(max(1.0 - dot(nxz, nxz), 0.0004)), nxz.y);
  g.ao = sf.z;
  g.hollow = sf.w;
  g.rock = mk.r;
  g.scree = mk.g;
  g.gully = mk.b;
  if (level >= kMtnShadowLevel) {
    g.sun = sunShadow.sample(kLinearClamp, uv, level).r;
    if (morph > 0.0) g.sun = mix(g.sun, sunShadow.sample(kLinearClamp, uv2, coarse).r, morph);
  } else {
    g.sun = sunShadow.sample(kLinearClamp, mtnLevelUV(world, m.levels[kMtnShadowLevel]), kMtnShadowLevel).r;
  }
  return g;
}

/// Pale dolomite at `Pa` (absolute x, z), `alt` metres above the trail's mean: buff and grey
/// beds, darker and ochre layers, black streaks where water runs down steep faces. `fine`: how
/// much fine detail the distance leaves (0 … 1).
static float3 mtnRock(float2 Pa, float2 Pd, float alt, float3 n, float foot, float mid, thread float &relief, thread float2 &tilt) {
  float fine = mtnSeen(1.1, foot);
  float steep = smoothstep(0.75, 0.35, n.y);
  float beds = mtnNoise(float2(alt / 24.0 + 2.0 * mtnNoise(Pa / 260.0, 301u), 0.5 + alt / 140.0), 302u) * 0.6 +
               mtnNoise(float2(alt / 7.0 + 1.5 * mtnNoise(Pa / 120.0, 319u), 2.5), 320u) * 0.4 * mtnSeen(1.0 / 7.0, foot * 0.5) + 0.2 * (1.0 - mtnSeen(1.0 / 7.0, foot * 0.5));
  float2 Pr = float2(0.82 * Pa.x - 0.57 * Pa.y, 0.57 * Pa.x + 0.82 * Pa.y);
  float beds2 = mtnNoise(float2(alt / 2.2 + 3.0 * mtnNoise(Pa / 90.0, 303u), 1.5), 304u);
  float patch = mtnNoise(Pa / 130.0, 305u) * 0.6 + mtnNoise(Pa / 31.0, 306u) * 0.4;
  float3 c = mix(mtnHex(102, 102, 101), mtnHex(120, 119, 116), mix(0.5, beds, 0.35 + 0.65 * mid));
  c = mix(c, mtnHex(120, 108, 88), smoothstep(0.62, 0.8, beds2 * 0.55 + patch * 0.45) * 0.35);       // ochre, iron-stained beds
  c = mix(c, mtnHex(78, 80, 84), smoothstep(0.55, 0.8, patch) * 0.5);                               // weathered grey
  c *= 0.9 + 0.2 * mix(0.5, beds2, mid);
  // On a wall, anything that varies only with (x, z) runs straight down it: water streaks.
  float sf = mtnSeen(1.25, foot);
  float streak = mid > 0.0 ? mtnNoise(Pa / float2(2.4, 2.4), 307u) * 0.55 + (sf > 0.0 ? mtnNoise(Pa / 0.8, 308u) : 0.0) * 0.45 * sf + 0.2 * (1.0 - sf) : 0.5;
  float wide = mtnNoise(Pa / 14.0, 309u);
  float streaks = steep * mid * smoothstep(0.52, 0.85, streak * 0.6 + wide * 0.5);
  c = mix(c, mtnHex(44, 46, 52), streaks * 0.6);
  // From afar the streaks merge into dark bands down the walls, tens of metres wide.
  float2 Pb = Pr + 30.0 * patch;
  float bandsFar = steep * smoothstep(0.52, 0.8, mtnNoise(Pb / 19.0, 321u) * 0.5 * mtnSeen(1.0 / 19.0, foot) + mtnNoise(Pb / 61.0, 322u) * 0.65);
  c = mix(c, mtnHex(52, 54, 60), bandsFar * 0.3);
  // Fissures: dark lines where ridged noise crests, at every size; down a wall they are its
  // chimneys and cracks, on gentler rock its joints.
  float2 Pf = Pr + 14.0 * float2(mtnNoise(Pa / 47.0, 328u), mtnNoise(Pa / 47.0 + 9.0, 329u));
  float f1 = 1.0 - abs(2.0 * mtnNoise(Pf / 58.0, 330u) - 1.0), f2 = 1.0 - abs(2.0 * mtnNoise(Pf / 19.0, 331u) - 1.0);
  float fs3 = mtnSeen(1.0, foot), fs4 = mtnSeen(3.0, foot);  // (octaves the pixel can't show aren't worked out)
  float f3 = fs3 > 0.0 ? 1.0 - abs(2.0 * mtnNoise(Pf / 6.3, 332u) - 1.0) : 0.0, f4 = fs4 > 0.0 ? 1.0 - abs(2.0 * mtnNoise(Pf / 2.1, 333u) - 1.0) : 0.0;
  float fissure = max(max(pow(f1, 8.0) * mtnSeen(1.0 / 9.0, foot), pow(f2, 8.0) * mtnSeen(1.0 / 3.0, foot)), max(pow(f3, 8.0) * fs3, pow(f4, 8.0) * fs4) * 0.8);
  // (Unresolved fissures still darken the rock a little: it is not a clean surface.)
  c *= 1.0 - 0.62 * fissure * (0.4 + 0.6 * steep);
  c *= 0.8 + 0.4 * (mtnNoise(Pf / 27.0, 334u) * 0.6 + mtnNoise(Pf / 8.0, 335u) * 0.4 * mtnSeen(1.0 / 8.0, foot) + 0.2 * (1.0 - mtnSeen(1.0 / 8.0, foot)));
  // The walls' ribs and chimneys, smaller than the baked normals show: a tilt of the normal
  // from the noise's own gradient (screen derivatives hatch at a glance).
  relief = 0.0;
  float t3 = mtnSeen(1.0 / 5.3, foot), t4 = mtnSeen(1.0 / 1.7, foot);
  tilt = mtnNoiseD(Pr / 47.0, 316u).yz * 0.7 * mtnSeen(1.0 / 47.0, foot) + mtnNoiseD(Pr / 16.0, 317u).yz * 0.45 * mtnSeen(1.0 / 16.0, foot);
  if (t3 > 0.0) tilt += mtnNoiseD(Pr / 5.3, 318u).yz * 0.3 * t3;
  if (t4 > 0.0) tilt += mtnNoiseD(Pr / 1.7, 327u).yz * 0.25 * t4;
  tilt *= 0.35 + 0.65 * steep;
  if (fine > 0.0) {
    // Close up: blocks split by joints (drawn out into columns on a wall), thin bedding lines
    // across them, pitted faces.
    float3 blocks = mtnStones(Pd, 0.7, 311u), chips = mtnStones(Pd, 2.9, 312u);
    float cf = mtnSeen(2.9, foot), pf = mtnSeen(13.0, foot);
    float joints = (1.0 - smoothstep(0.0, 0.07, blocks.x)) * 0.5 * smoothstep(0.3, 0.6, mtnDetail(Pd, 0.5, 325u)) + (1.0 - smoothstep(0.0, 0.12, chips.x)) * 0.2 * cf * smoothstep(0.4, 0.7, mtnDetail(Pd, 1.9, 326u));
    float bq = alt / 0.55 + 3.0 * mtnNoise(Pa / 5.0, 313u);
    float bedLine = (1.0 - smoothstep(0.0, 0.1, abs(bq - floor(bq) - 0.5) * 2.0)) * steep * smoothstep(0.4, 0.6, mtnNoise(Pa / 3.0, 315u));
    float pits = mix(0.5, mtnDetail(Pd, 13.0, 314u), pf);
    // Weathering: mottled grey, dark lichen in spots.
    float mottle = mix(0.5, mtnDetail(Pd, 3.3, 323u), cf);
    float lichen = smoothstep(0.6, 0.72, mtnDetail(Pd, 1.3, 324u) * 0.6 + mottle * 0.4) * fine;
    c = mix(c * (0.84 + 0.32 * mottle), mtnHex(88, 90, 86), lichen * 0.5);
    c *= mix(1.0, (0.97 + 0.06 * blocks.y) * (1.0 - 0.4 * min(joints + bedLine * 0.4, 1.0)) * (0.82 + 0.36 * pits), fine);
    relief += fine * (smoothstep(0.0, 0.3, blocks.x) * 0.02 + smoothstep(0.0, 0.3, chips.x) * 0.008 * cf + pits * 0.004 * pf);
  }
  return c;
}

fragment float4 mtn_terrain_fs(MtnFragmentIn in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                               constant MountainUniforms &m [[buffer(kBufferMountain)]], depth2d_array<float> shadowMap [[texture(kTextureShadow)]],
                               texture2d<float> clouds [[texture(kTextureClouds)]], texture2d_array<float> surface [[texture(kTextureSurface)]],
                               texture2d_array<float> mask [[texture(kTextureMask)]], texture2d_array<float> sunShadow [[texture(kTextureSunShadow)]]) {
  int level = int(in.level + 0.5);
  MtnGround g = mtnGround(in.world, level, m, surface, mask, sunShadow);
  float3 ray = in.world - u.camPos;
  float dist = length(ray);
  float3 n = g.normal;
  float zAbs = in.world.z + u.originZ;
  float2 Pa = float2(in.world.x, zAbs), Pd = mtnWrapped(in.world, m);
  float alt = in.world.y + dist * dist * (0.5 / kMtnEarthRadius);
  float mid = 1.0 - smoothstep(250.0, 1400.0, dist);
  // A pixel's size on the ground (longer at a glance): fine patterns fade before they shimmer.
  float foot = dist / u.projScale / max(dot(-ray / dist, n), 0.25);
  float fine = mtnSeen(5.0, foot);

  float sun = g.sun;
  if (max3(u.sunColor) > 0.0) {
    sun *= coastSunlight(in.world, u, clouds);
    if (dist < u.shadowSplits.y) sun *= shadowAt(in.world, n, u, shadowMap);
  }

  if (m.debug > 0.5) {  // the shape alone
    Surface s = makeSurface(float3(0.45), n);
    s.occlusion = g.ao;
    return float4(mtnAir(lightSurface(u, in.world, s, sun), in.world, u, m, clouds), 1.0);
  }

  // The trail.
  float ps = MountainPathSlope(zAbs);
  float d = (in.world.x - MountainPathX(zAbs)) * rsqrt(1.0 + ps * ps), ad = abs(d);
  float hw = m.shape.trailHalf;

  // Large patterns.
  float n37 = mtnNoise(Pa / 37.0, 201u), n9 = mix(0.5, mtnNoise(Pa / 9.0, 202u), mtnSeen(0.11, foot));
  float3 n2d = mtnNoiseD(Pa / 2.3, 203u);
  float n2 = mix(0.5, n2d.x, mtnSeen(0.43, foot));
  float2 turfTilt = n2d.yz * (0.2 / 2.3) * mtnSeen(0.43, foot);
  float n300 = mtnNoise(Pa / 300.0, 204u);
  // Blades: strokes drawn out along the view, which stand upright in the picture.
  float bs = mtnSeen(14.0, foot * 0.6), bs2 = mtnSeen(40.0, foot * 0.6);
  float blades = mix(0.5, bs > 0.0 ? mtnDetail(Pd, 14.0, 205u, 0.12) : 0.5, bs) * 0.55 + mix(0.5, bs2 > 0.0 ? mtnDetail(Pd, 40.0, 206u, 0.1) : 0.5, bs2) * 0.45;

  // Turf: tussock grass, olive, lusher in the hollows and gullies, straw-dry on the ribs. Tufts
  // are soft round blobs, lighter on their crowns, with dark gaps between them; patches of
  // every size on top, so that no pattern shows.
  float lush = saturate(0.5 + (g.hollow - 0.5) * 2.5 + g.gully * 0.5 + (n37 - 0.5) * 0.9);
  float ts = mtnSeen(2.6, foot), ts2 = mtnSeen(7.5, foot);
  float3 tus = float3(0.5), tus2 = float3(0.5);
  float2 warp = 0.0;
  if (ts > 0.0) {
    warp = (float2(mtnDetail(Pd, 1.9, 228u), mtnDetail(Pd + 7.3, 1.9, 229u)) - 0.5) * 0.5;
    tus = mtnStones(Pd + warp, 2.6, 226u, 0.4);
    if (ts2 > 0.0) tus2 = mtnStones(Pd + warp * 0.5, 7.5, 227u, 0.35);
  }
  float tuft = (1.0 - smoothstep(0.1, 0.62, tus.z)) * (0.5 + 0.5 * tus.y), tuft2 = 1.0 - smoothstep(0.1, 0.6, tus2.z);
  if (dist < 7.0) {  // at the camera's feet the view is steep: round tufts there
    float3 r1 = mtnStones(Pd + warp, 2.6, 226u), r2 = mtnStones(Pd + warp * 0.5, 7.5, 227u);
    float nearby = 1.0 - smoothstep(2.5, 7.0, dist);
    tuft = mix(tuft, (1.0 - smoothstep(0.1, 0.62, r1.z)) * (0.5 + 0.5 * r1.y), nearby);
    tuft2 = mix(tuft2, 1.0 - smoothstep(0.1, 0.6, r2.z), nearby);
    tus.y = mix(tus.y, r1.y, step(0.5, nearby));
  }
  float3 turf = mix(mtnHex(92, 90, 42), mtnHex(60, 80, 30), lush);
  turf = mix(turf, mtnHex(44, 58, 24), smoothstep(0.5, 0.8, n9 * 0.6 + n2 * 0.4) * 0.65);
  turf = mix(turf, mtnHex(122, 112, 58), smoothstep(0.6, 0.9, tus.y) * tuft * ts * 0.6);
  float cs1 = mtnSeen(1.1, foot), cs2 = mtnSeen(4.3, foot);
  float clumps = mix(0.5, cs1 > 0.0 ? mtnDetail(Pd, 1.1, 225u, 0.5) : 0.5, cs1), clumps2 = mix(0.5, cs2 > 0.0 ? mtnDetail(Pd, 4.3, 230u, 0.4) : 0.5, cs2);
  turf *= mix(1.0, 0.42 + 0.95 * tuft, ts) * mix(1.0, 0.6 + 0.72 * tuft2, ts2) * (0.55 + 0.9 * blades) * (0.78 + 0.44 * clumps) * (0.8 + 0.4 * clumps2);
  turf *= 0.8 + 0.4 * n2 * mid + 0.2 * (1.0 - mid);
  // The wind runs over it in waves of lighter grass.
  if (m.wind > 0.0 && dist < 400.0) {
    float2 w = Pa * (1.0 / 13.0) + u.windDir * (u.time * 0.55);
    float wave = mtnNoise(w, 207u) * 0.6 + mtnNoise(w * 2.7 + 5.0, 208u) * 0.4;
    turf *= 1.0 + m.wind * 0.22 * (wave - 0.5) * (1.0 - smoothstep(150.0, 400.0, dist));
  }
  // Flowers: yellow in drifts, a few white and violet; from afar a yellow cast on the drifts.
  float drift = smoothstep(0.5, 0.75, mtnNoise(Pa / 17.0, 209u) * 0.7 + n37 * 0.4) * m.flowers;
  float level_ = smoothstep(0.7, 0.85, n.y);  // patterns drawn from above smear on a steep bank
  if (drift > 0.0 && dist < 70.0) {
    float3 fl = mtnStones(Pd, 13.0, 210u, 0.45);
    float show = smoothstep(4.0, 9.0, dist) * mtnSeen(13.0, foot * 0.5) * level_;
    float dot_ = (1.0 - smoothstep(0.1, 0.24, fl.z)) * step(fl.y, 0.34 * drift) * show;
    float3 petal = fl.y < 0.24 * drift ? mtnHex(246, 206, 24) : fl.y < 0.29 * drift ? mtnHex(240, 240, 232) : mtnHex(126, 88, 190);
    turf = mix(turf, petal, dot_);
  }
  turf = mix(turf, turf * float3(1.2, 1.12, 0.7), drift * 0.2 * smoothstep(12.0, 60.0, dist));
  // Small pale stones lie in the turf.
  if (fine > 0.0) {
    float3 st = mtnStones(Pd, 7.0, 223u, 0.5);
    float lying = (1.0 - smoothstep(0.12, 0.3, st.z)) * step(0.94 - 0.08 * (1.0 - smoothstep(0.3, 2.5, ad - hw)), st.y) * mtnSeen(7.0, foot) * level_;
    turf = mix(turf, mtnHex(150, 148, 142) * (0.8 + 0.4 * st.x), lying);
  }
  // High up the turf thins out; far below it gives way to dwarf pine and then to forest.
  float line = -225.0 + 70.0 * (n300 - 0.5) + 30.0 * (n37 - 0.5);
  float forest = smoothstep(line + 30.0, line - 40.0, alt) * smoothstep(0.5, 0.64, n.y);
  float pines = smoothstep(line + 190.0, line + 60.0, alt) * smoothstep(0.48, 0.56, mtnNoise(Pa / 23.0, 211u) * 0.45 + mtnNoise(Pa / 7.0, 224u) * 0.3 * mtnSeen(1.0 / 7.0, foot) + n37 * 0.3) * (1.0 - forest);
  float3 crownD = alt < line + 200.0 ? mtnNoiseD(Pa / 6.0, 212u) : float3(0.5, 0.0, 0.0);
  float crowns = crownD.x * 0.6 + (mid > 0.0 && alt < line + 200.0 ? mtnNoise(Pa / 2.5, 213u) : 0.5) * 0.4 * mid + 0.2 * (1.0 - mid);
  float2 woodTilt = crownD.yz * (1.5 / 6.0) * mtnSeen(1.0 / 6.0, foot);
  float3 woods = mix(mtnHex(22, 38, 24), mtnHex(44, 62, 30), smoothstep(0.6, 0.8, mtnNoise(Pa / 90.0, 214u))) * (0.4 + 1.0 * crowns);
  float meadow = smoothstep(0.6, 0.72, mtnNoise(Pa / 210.0, 215u)) * smoothstep(0.88, 0.96, n.y);
  float3 ground = mix(turf, mtnHex(26, 42, 24) * (0.6 + 0.7 * crowns), pines);
  ground = mix(ground, mix(woods, mtnHex(84, 98, 44) * (0.85 + 0.3 * n9), meadow), forest);
  float woody = max(forest * (1.0 - meadow), pines);

  // Rock where the bake says so, where it is too steep for soil, and more of it higher up.
  float bare = smoothstep(380.0, 700.0, alt + 120.0 * (n37 - 0.5));
  float steep = smoothstep(0.66, 0.5, n.y + 0.06 * (n9 - 0.5));
  float bank = (1.0 - smoothstep(hw + 1.6, hw + 3.0, ad)) * (1.0 - g.rock);  // the cut above the tread is earth
  float rock = max(max(g.rock, steep * (1.0 - bank)), bare * (1.0 - g.scree));
  // Grass holds on the ledges of the lower walls.
  rock *= 1.0 - smoothstep(0.8, 0.93, n.y) * (1.0 - smoothstep(100.0, 420.0, alt)) * smoothstep(0.35, 0.6, n9) * g.rock * 0.8;
  float relief = 0.0;
  float2 rockTilt = 0.0;
  float3 rockC = 0.3;
  if (rock > 0.004 || g.scree > 0.004) rockC = mtnRock(Pa, Pd, alt, n, foot, mid, relief, rockTilt);

  // Scree: grey rubble, streaked down the fall line, coarser stones showing close up.
  float2 fall = n.xz * rsqrt(max(dot(n.xz, n.xz), 1e-6));
  float2 sc = float2(dot(Pa, float2(-fall.y, fall.x)), dot(Pa, fall));
  float lanes = 0.5;
  if (g.scree > 0.004) lanes = mtnNoise(float2(sc.x / 23.0, sc.y / 300.0), 336u) * 0.5 + mtnNoise(float2(sc.x / 7.0, sc.y / 90.0), 216u) * 0.3 + (mid > 0.0 ? mtnNoise(float2(sc.x / 2.2, sc.y / 40.0), 217u) : 0.5) * 0.4 * mid + 0.2 * (1.0 - mid);
  float3 screeC = mix(mtnHex(112, 111, 107), mtnHex(176, 175, 170), smoothstep(0.25, 0.75, lanes)) * (0.9 + 0.2 * n2 * mid + 0.1 * (1.0 - mid));
  float scree = g.scree * (1.0 - rock);
  // Below the tree line the old talus is overgrown.
  scree *= 1.0 - forest * 0.85 * smoothstep(0.45, 0.6, n37);

  float cut = bank * smoothstep(0.8, 0.62, n.y);
  ground = mix(ground, mtnHex(92, 78, 58) * (0.8 + 0.4 * clumps) * (0.7 + 0.6 * blades), cut * 0.6 * smoothstep(0.35, 0.6, clumps * 0.6 + n2 * 0.4));
  float3 albedo = mix(ground, screeC, scree);
  albedo = mix(albedo, rockC, rock);
  float roughRelief = mix(blades * 0.015 * (1.0 - woody), relief, max(rock, scree * 0.5));
  float2 tilt = mix(mix(turfTilt, woodTilt, woody), rockTilt, max(rock, scree * 0.6));

  // The valley floor: a pale river winding through meadows.
  float specular = 0.0, gloss = 1.0;
  if (alt < -400.0) {
    float v = m.shape.side * in.world.x;
    float bed = abs(v - (628.0 + 30.0 * sin(zAbs / 230.0) + 14.0 * sin(zAbs / 87.0 + 1.0)));
    float gravel = 1.0 - smoothstep(9.0, 16.0, bed + 5.0 * (n9 - 0.5));
    float water = 1.0 - smoothstep(3.0, 5.0, bed + 3.0 * (n9 - 0.5));
    albedo = mix(albedo, mtnHex(150, 149, 144), gravel);
    albedo = mix(albedo, mtnHex(40, 78, 86), water);
    specular = 0.03 * water;
    gloss = mix(1.0, 0.25, water);
    roughRelief *= 1.0 - gravel;
  }

  // The trail: a narrow line of white limestone gravel, every size from grit to fist, dark in
  // the gaps between the stones; tufts break into its ragged edges.
  float edge = (mtnDetail(Pd, 0.5, 234u, 0.4) - 0.5) * 0.22 + (mtnDetail(Pd, 1.7, 218u, 0.35) - 0.5) * 0.24 + (0.5 - tuft) * 0.16 * ts;
  float onTrail = (1.0 - smoothstep(hw - 0.1, hw + 0.1, ad + edge)) * (1.0 - rock * 0.6);
  if (onTrail > 0.0 && dist < 600.0) {
    // Separate stones lying in pale dust: round blobs of three sizes, each with its own shade,
    // a dark crescent of shadow beside it; grit over everything.
    float s1 = mtnSeen(4.0, foot), s2 = mtnSeen(11.0, foot), s3 = mtnSeen(27.0, foot);
    float2 tw = (float2(mtnDetail(Pd, 9.0, 231u), mtnDetail(Pd + 3.1, 9.0, 232u)) - 0.5) * 0.06;
    float3 cobble = mtnStones(Pd + tw, 4.0, 219u, 0.6), pebble = mtnStones(Pd + tw, 11.0, 220u, 0.6), grit = mtnStones(Pd, 27.0, 221u, 0.6);
    float big = (1.0 - smoothstep(0.2, 0.3, cobble.z / (0.5 + 0.5 * cobble.y))) * step(0.6, cobble.y) * s1;
    float mid_ = (1.0 - smoothstep(0.22, 0.36, pebble.z / (0.55 + 0.45 * pebble.y))) * step(0.25, pebble.y) * s2;
    float fineSt = (1.0 - smoothstep(0.2, 0.42, grit.z)) * step(0.3, grit.y) * s3;
    float sand = mix(0.5, mtnDetail(Pd, 60.0, 233u), mtnSeen(60.0, foot));
    float3 dust = mtnHex(150, 144, 130) * (0.82 + 0.2 * n2 + 0.2 * sand);
    float3 stone = mix(mtnHex(146, 145, 140), mtnHex(186, 185, 178), fract(cobble.y * 7.0 + pebble.y * 3.0)) * (0.92 + 0.16 * sand);
    float stones = max(max(big, mid_), fineSt * 0.8);
    // A stone's shadow falls on the dust on the side away from the sun.
    float3 shB = mtnStones(Pd + tw + u.sunDir.xz * 0.03, 4.0, 219u, 0.6), shM = mtnStones(Pd + tw + u.sunDir.xz * 0.012, 11.0, 220u, 0.6);
    float cast = max((1.0 - smoothstep(0.2, 0.34, shB.z / (0.5 + 0.5 * shB.y))) * step(0.6, shB.y) * s1,
                     (1.0 - smoothstep(0.22, 0.4, shM.z / (0.55 + 0.45 * shM.y))) * step(0.25, shM.y) * s2);
    dust *= 1.0 - 0.45 * cast * (1.0 - stones);
    float3 tread = mix(mix(dust, stone, 0.5), mix(dust, stone, stones), max(s2, s3 * 0.6));
    albedo = mix(albedo, tread, onTrail);
    roughRelief = mix(roughRelief, big * 0.015 + mid_ * 0.005, onTrail);
    if (u.wetness > 0.0) {
      float puddle = onTrail * smoothstep(0.62, 0.72, n2 * 0.7 + mtnDetail(Pd, 0.6, 222u) * 0.4) * u.wetness;
      albedo *= 1.0 - 0.45 * puddle;
      specular = max(specular, 0.03 * puddle);
      gloss = mix(gloss, 0.05, puddle);
      roughRelief *= 1.0 - puddle;
    }
  }

  float lev_cell = m.levels[level].z * 16.0;  // (snow patches are large: only the coarser levels' hollows count)
  // Snow: in the gullies and hollows of the high walls, on ledges, lower with more of it.
  float snow = 0.0;
  if (m.snow > 0.0) {
    float snowLine = mix(820.0, -260.0, m.snow);
    float shade = 1.0 - g.sun * saturate(dot(n, u.sunDir) * 2.0 + 0.3);
    float score = (alt - snowLine) / 380.0 + (g.hollow - 0.5) * 5.0 * smoothstep(-300.0, -60.0, alt - snowLine) + shade * 0.25 + (n37 - 0.5) * 0.5 + (n9 - 0.5) * 0.3 * mid - 0.45;
    snow = smoothstep(0.0, 0.22, score) * smoothstep(0.42, 0.7, n.y) * (1.0 - onTrail) * smoothstep(8.0, 30.0, lev_cell);
    albedo = mix(albedo, float3(0.86, 0.88, 0.93) * (0.94 + 0.06 * n2), snow);
    roughRelief *= 1.0 - snow * 0.9;
  }

  tilt *= 1.0 - max(snow, onTrail);
  float3 nt = normalize(n - float3(tilt.x, 0.0, tilt.y));
  Surface s = makeSurface(albedo, fine > 0.0 ? bump(nt, in.world, roughRelief * fine) : nt);
  s.occlusion = g.ao * mix(1.0, 0.75 + 0.25 * crowns, woody) * mix(1.0, saturate(1.35 - 1.5 * max(g.hollow - 0.42, 0.0)), rock);
  s.specular = specular;
  s.roughness = gloss;
  float3 col = lightSurface(u, in.world, s, sun);
  // Light bounced up from the sunlit ground onto steep faces; the velvet of grass seen at a glance.
  col += albedo * u.sunColor * (0.05 * (1.0 - n.y) * saturate(u.sunDir.y * 2.0) * g.ao);
  float turfShare = (1.0 - rock) * (1.0 - scree) * (1.0 - woody) * (1.0 - snow) * (1.0 - onTrail);  // (the trail's share is already out of `rock`)
  float glance = pow(1.0 - saturate(dot(-ray / dist, s.normal)), 3.0);
  col += turfShare * glance * (u.sunColor * sun * 0.012 + u.skyAmbient * 0.02) * float3(0.9, 1.0, 0.6);
  return float4(mtnAir(col, in.world, u, m, clouds), 1.0);
}

// ---- stones, plants, props ----

fragment float4 mtn_prop_fs(PlantOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                            constant PlantUniforms &f [[buffer(kBufferScene)]], constant MountainUniforms &m [[buffer(kBufferMountain)]],
                            depth2d_array<float> shadowMap [[texture(kTextureShadow)]], texture2d<float> atlas [[texture(kTextureScene)]],
                            texture2d<float> clouds [[texture(kTextureClouds)]], texture2d_array<float> sunShadow [[texture(kTextureSunShadow)]]) {
  float alpha;
  Surface s = plantSurface(in, u, f, atlas, alpha);
  int mat = int(in.material + 0.5);
  if (mat == kMaterialRock) {  // the terrain's limestone
    float3 w = in.world + float3(0.0, 0.0, u.originZ);
    float relief;
    float2 tilt;
    float dist = length(in.world - u.camPos);
    s.albedo = mtnRock(w.xz + w.y * 0.7, mtnWrapped(in.world, m) + in.world.y * 0.7, w.y * 6.0, s.normal, dist / u.projScale, 1.0, relief, tilt) * in.color * in.bright;
    s.albedo = mix(s.albedo, mtnHex(120, 126, 58) * in.bright, smoothstep(0.75, 0.95, s.normal.y) * smoothstep(0.5, 0.7, valueNoise(w.xz * 1.3)) * f.moss);
  }
  float sun = shadowAt(in.world, normalize(in.normal), u, shadowMap);
  if (max3(u.sunColor) > 0.0) {
    sun *= sunShadow.sample(kLinearClamp, mtnLevelUV(in.world, m.levels[kMtnShadowLevel]), kMtnShadowLevel).r;
    sun *= coastSunlight(in.world, u, clouds);
  }
  return float4(mtnAir(lightSurface(u, in.world, s, sun), in.world, u, m, clouds), alpha);
}
