// Seaside promenade (SeasideScene.h). Compiled after SceneShared.h, Common.metal, Plants.h,
// Plants.metal (plant_vs and plantSurface draw the props, pines and balusters), CoastSky.h,
// CoastSky.metal (the sky the sea and wet stone mirror) and SeasideScene.h.
//
//   strip_vs / strip_fs: the paving, the balustrade's plinth, coping and piers, the sea wall and
//     the beach (per-tile meshes), and the distant balusters as a cut-out pattern.
//   park_vs / park_fs: the pine park's ground inland of the promenade.
//   sea_vs / sea_fs: the sea out to the far plane: rings around the camera, moved by the longest
//     waves. Every wave shapes the normal where the pixel resolves it; the slopes of those it
//     doesn't become roughness, which is what spreads the sun into a glitter path far out.
//   far_vs / far_fs: beyond the far plane: the sea to the horizon (the earth's curvature hides the
//     rest), the far shore, hills and headlands. The sky itself is CoastEnvironment's.
//   seaside_prop_fs: balusters, lamps, benches, pines, shrubs (plant_vs).

static float3 rgb8(float r, float g, float b) {
  return pow(float3(r, g, b) / 255.0, 2.2);
}

static float seawardOf(float3 world, constant FrameUniforms &u, constant SeasideUniforms &c) {
  return (world.x - SeasidePathX(world.z + u.originZ)) * c.seaSign;
}

// ---- light by the sea ----

/// The light arriving at a surface on the promenade (what a white surface reflects, in the
/// hemisphere terms' units): the sky above, the ground below, and from the sea's side the bright
/// open horizon.
static float3 seasideAmbient(float3 n, constant FrameUniforms &u, constant SeasideUniforms &c) {
  float3 amb = mix(u.groundAmbient, u.skyAmbient, n.y * 0.5 + 0.5);
  float toSea = saturate(n.x * c.seaSign) * (1.0 - abs(n.y));
  return amb + (u.skyHorizon * 0.22 + u.fogColor * 0.12) * toSea;
}

/// The lamps' light (in a storm's gloom): the nearest few lanterns along the balustrade.
static float3 lampLight(float3 world, float3 n, constant FrameUniforms &u, constant SeasideUniforms &c) {
  if (u.night <= 0.0) return 0.0;
  float zAbs = world.z + u.originZ;
  float k0 = floor(zAbs / kPromenadeLampSpacing);
  float sum = 0.0;
  for (int j = -1; j <= 2; j++) {
    float lz = (k0 + float(j)) * kPromenadeLampSpacing;
    float3 d = float3(SeasidePathX(lz) + c.seaSign * kLanternS, kPromenadeY + kLanternY, lz - u.originZ) - world;
    float dist2 = dot(d, d), inv = rsqrt(dist2);
    float down = 0.15 + 0.85 * saturate(d.y * inv * 1.6 + 0.35);  // the lantern's cap: little light upward
    sum += 14.0 / (dist2 + 1.5) * saturate(dot(n, d * inv) * 0.85 + 0.15) * down;
  }
  return u.lampColor * sum * u.night;
}

/// A surface lit by the coast: sun (shadowed), the coast's ambient, the sky (its clouds in a few
/// steps) in glossy and wet surfaces, the lamps. `ambientPart` gets the ambient share.
static float3 seasideLight(Surface s, float3 world, float shadow, float2 pixel, constant FrameUniforms &u, constant SeasideUniforms &c,
                           texture2d<float> clouds, thread float3 &ambientPart) {
  float3 env = 0.0;
  if (s.specular > 0.0) {
    float3 r = reflect(normalize(world - u.camPos), s.normal);
    r.y = abs(r.y);
    env = coastSky(r, u, clouds, s.roughness < 0.3 ? 3 : 0, 1.0 + s.roughness * 5.0, coastIGN(pixel));  // clouds in wet stone
  }
  float3 col = lightSurfaceIn(u, world, s, shadow, seasideAmbient(s.normal, u, c), env, ambientPart);
  return col + s.albedo * lampLight(world, s.normal, u, c);
}

// ---- stone, paving, wall, sand ----

/// Limestone weathered by the sea air: pale, mottled, grey lichen, grime low down, darker wet.
static float3 stoneAlbedo(float3 world, constant FrameUniforms &u) {
  float3 p = float3(world.x, world.y, world.z + u.originZ);
  float m = valueNoise(p.xz * 1.3 + p.y * 2.1) * 0.6 + valueNoise(p.xz * 7.0 + p.y * 9.0) * 0.4;
  float3 col = rgb8(206, 198, 180) * (0.86 + 0.22 * m);
  float lichen = smoothstep(0.72, 0.82, valueNoise(p.xz * 3.1 + p.y * 4.3 + 17.0));
  col = mix(col, rgb8(120, 118, 108), lichen * 0.45);
  float grime = 1.0 - smoothstep(kPromenadeY, kPromenadeY + 0.3, world.y);
  return col * (1.0 - 0.2 * grime) * (1.0 - 0.3 * u.wetness);
}

/// The promenade's paving: pale limestone slabs, 0.9 m across and 0.55 m along the coast in
/// staggered rows, a border of long kerbs by the balustrade; worn and stained; each slab a little
/// tilted (it shows in reflections); darker and glossy when wet, with puddles. `uv` = (s, z in
/// the tile), `tile` its index.
static Surface pavingSurface(float2 uv, float tile, float3 world, constant FrameUniforms &u) {
  float s = uv.x, lz = uv.y;
  float2 fw = max(fwidth(uv), 1e-4);
  float2 cell;
  float dz, ds, tone;
  const float border = kBalustradeIn - 0.42;
  if (s > border) {  // the border: kerbs 1.1 m long
    cell = float2(tile * 20.0 + floor(lz / 1.1), 99.0);
    dz = abs(fract(lz / 1.1 + 0.5) - 0.5) * 1.1;
    ds = abs(s - border);
    tone = 0.84;
  } else {
    float row = floor(lz / 0.55) + tile * 40.0;
    float shift = fmod(row, 2.0) * 0.45;
    cell = float2(row, floor((s + shift) / 0.9));
    dz = abs(fract(lz / 0.55 + 0.5) - 0.5) * 0.55;
    ds = abs(fract((s + shift) / 0.9 + 0.5) - 0.5) * 0.9;
    tone = 1.0;
  }
  float joint = max(1.0 - smoothstep(0.003, 0.003 + fw.y * 1.5, dz), 1.0 - smoothstep(0.003, 0.003 + fw.x * 1.5, ds));
  float h = hash21(cell * float2(1.17, 7.31)), h2 = hash21(cell * float2(3.7, 1.9) + 5.0);
  float2 p = float2(world.x, world.z + u.originZ);
  float detail = 1.0 - smoothstep(15.0, 50.0, length(world - u.camPos));
  float grain = mix(0.5, valueNoise(p * 6.0) * 0.5 + valueNoise(p * 23.0) * 0.5, detail);
  float stain = smoothstep(0.6, 0.8, fbm(p * 0.35, 3));
  float3 slab = mix(rgb8(214, 206, 188), rgb8(196, 187, 171), h) * mix(1.0, 0.93, h2) * tone;
  slab *= (0.9 + 0.14 * grain) * (1.0 - 0.16 * stain);
  Surface sf = makeSurface(mix(slab, rgb8(118, 108, 94), joint * 0.8), normalize(float3((h - 0.5) * 0.014, 1.0, (h2 - 0.5) * 0.014)));
  sf.specular = 0.02;
  sf.roughness = 0.62;
  float wet = u.wetness;
  if (wet > 0.0) {
    float puddle = smoothstep(0.58, 0.66, fbm(p * 0.22, 3) + (h - 0.5) * 0.1) * (1.0 - joint);
    sf.albedo *= mix(1.0, 0.55, wet) * (1.0 - 0.35 * puddle * wet);
    sf.roughness = mix(sf.roughness, mix(0.16, 0.02, puddle), wet);
    sf.specular = 0.022;
    sf.normal = normalize(mix(sf.normal, float3(0, 1, 0), puddle));
  }
  return sf;
}

/// The sea wall: ashlar courses, dark and weedy where the waves reach, salt-whitened above.
/// uv = (z in the tile, y).
static float3 wallAlbedo(float2 uv, float3 world, constant FrameUniforms &u) {
  float zAbs = world.z + u.originZ;
  float course = floor(uv.y / 0.45);
  float shift = fmod(abs(course), 2.0) * 0.45;
  float2 fw = max(fwidth(float2(zAbs, uv.y)), 1e-4);
  float dz = abs(fract((zAbs + shift) / 0.9 + 0.5) - 0.5) * 0.9, dy = abs(fract(uv.y / 0.45 + 0.5) - 0.5) * 0.45;
  float mortar = max(1.0 - smoothstep(0.006, 0.006 + fw.x * 1.5, dz), 1.0 - smoothstep(0.006, 0.006 + fw.y * 1.5, dy));
  float h = hash21(float2(floor((zAbs + shift) / 0.9), course) * float2(0.37, 1.91));
  float n = valueNoise(float2(zAbs * 4.0, uv.y * 4.0));
  float3 col = rgb8(160, 150, 132) * (0.82 + 0.26 * h) * (0.9 + 0.15 * n);
  col = mix(col, rgb8(92, 86, 74), mortar * 0.7);
  float line = kBeachTop + 0.45 + 0.25 * valueNoise(float2(zAbs * 0.3, 1.7));
  float weed = 1.0 - smoothstep(line - 0.25, line + 0.05, world.y);
  col = mix(col, rgb8(46, 52, 40), weed * 0.85);
  float salt = smoothstep(line, line + 0.2, world.y) * (1.0 - smoothstep(line + 0.3, line + 0.9, world.y)) * valueNoise(float2(zAbs * 2.0, uv.y * 9.0));
  return mix(col, rgb8(210, 206, 196), salt * 0.35) * (1.0 - 0.3 * u.wetness);
}

/// The surf at s (seaward of the wall), absolute z, time t: x how far the swash lifts the water
/// over the beach (m), y foam (0 … 1). A breaker forms at the breaker line every surfPeriod and
/// runs in as a bore, leaving foam that fades (a rough sea has several lines of it at once); at the
/// shore it runs up the beach and drains back. The timing drifts along the beach.
static float2 surfAt(float s, float zAbs, float t, constant SeasideUniforms &c) {
  float x = s - kShoreS;
  float zone = 5.0 + c.surf * 16.0;
  if (x > zone + 8.0) return 0.0;
  float T = c.surfPeriod, speed = 2.5 + c.surf * 1.2, runup = 1.2 + c.surf * 3.0;
  float along = (valueNoise(float2(zAbs * 0.013, 0.5)) * 1.4 + valueNoise(float2(zAbs * 0.05, 3.5)) * 0.35) * T;
  // Seconds since the last bore passed x (in the surf zone), and since one reached the shore.
  float age = T * fract((t + along - (zone - clamp(x, 0.0, zone)) / speed) / T);
  float ageShore = T * fract((t + along - zone / speed) / T);
  float foam = exp(-age / (0.7 + 1.5 * c.surf)) * (1.0 - smoothstep(zone - 1.0, zone + 4.0, x)) * step(0.0, x);
  foam = max(foam, 0.3 * (1.0 - smoothstep(0.0, zone, x)) * step(0.0, x));  // older foam drifting in
  // The swash: up the beach and back within most of a period; a sheet of foam on it.
  float g = saturate(ageShore / (0.75 * T));
  float swash = sin(3.14159 * g);
  float level = runup * kBeachSlope * swash;
  if (x < 0.0) foam = (1.0 - g) * 0.8 * step(-runup * swash, x);
  return float2(level, foam);
}

/// Foam's bubbly lace at q (metres), fading to its mean where a pixel covers `foot` metres.
static float foamLace(float2 q, float foot) {
  float lace = valueNoise(q * 1.7) * 0.55 + valueNoise(q * 6.0) * 0.45;
  return mix(0.55, lace, saturate(1.0 - foot * 1.2));
}

/// The beach: dry sand with wind ripples, darker and glossy where the swash reaches, damp below
/// it, a line of seaweed and pebbles at the high-water mark, foam on the wet sand.
static Surface sandSurface(float s, float3 world, float3 n, constant FrameUniforms &u, constant SeasideUniforms &c) {
  float zAbs = world.z + u.originZ;
  float2 p = float2(world.x, zAbs);
  float dist = length(world - u.camPos);
  float detail = 1.0 - smoothstep(25.0, 80.0, dist);
  float ripples = mix(0.5, valueNoise(float2(p.x * 0.6 + p.y * 1.9, p.y * 0.6 - p.x * 1.9)), detail);
  float n1 = valueNoise(p * 0.3), n2 = mix(0.5, valueNoise(p * 3.0), detail);
  float3 dry = rgb8(206, 188, 156) * (0.88 + 0.16 * n1) * (0.94 + 0.1 * ripples) * (0.95 + 0.08 * n2);
  float3 wet = rgb8(128, 110, 84) * (0.92 + 0.1 * n1);
  float x = s - kShoreS, runup = 1.2 + c.surf * 3.0;
  float swashed = smoothstep(-runup - 2.0 - n1 * 1.5, -runup + 0.5, x);
  float damp = smoothstep(-runup - 9.0, -runup - 2.0, x) * 0.35;
  float wetness = max(max(swashed, damp), u.wetness * 0.6);
  float3 albedo = mix(dry, wet, wetness);
  float mark = exp(-pow((x + runup + 5.0 + (n1 - 0.5) * 3.0) / 0.5, 2.0)) * smoothstep(0.5, 0.65, valueNoise(p * 1.3));
  albedo = mix(albedo, rgb8(80, 70, 52), mark * 0.5);
  float2 surf = surfAt(s, zAbs, u.time, c);
  float foam = smoothstep(0.25, 0.7, surf.y * foamLace(p, dist / (u.projScale * max(abs(normalize(world - u.camPos).y), 0.02)))) * smoothstep(-runup - 0.5, 0.5, x);
  albedo = mix(albedo, float3(0.8), foam);
  Surface sf = makeSurface(albedo, n);
  sf.specular = 0.02 * swashed;
  sf.roughness = mix(0.6, 0.1, swashed);
  return sf;
}

/// The distant balusters' silhouette on the strip's screen at uv = (z in the tile, height over
/// the plinth): their coverage, filtered by the pixel's footprint.
static float balusterCoverage(float2 uv) {
  float fw = max(fwidth(uv.x), 1e-4);
  float bay = floor(uv.x / kBayLength);
  float within = uv.x - bay * kBayLength;
  float startHalf = bay < 0.5 ? kLampPierHalf : kPierHalf;
  float endHalf = bay > float(kBaysPerLamp) - 1.5 ? kLampPierHalf : kPierHalf;
  float span = kBayLength - startHalf - endHalf, spacing = span / float(kBalustersPerBay);
  float q = within - startHalf;
  if (q < 0.0 || q > span) return 1.0;  // the piers (drawn as geometry)
  float local = (fract(q / spacing) - 0.5) * spacing;
  float v = uv.y * 0.66 / (kCopingBottom - kPlinthTop);  // BalusterMesh's profile is drawn 0.66 m tall
  float r = v < 0.07 || v > 0.59 ? 0.072 : 0.045 + 0.034 * exp(-pow((v - 0.29) / 0.1, 2.0)) - 0.008 * exp(-pow((v - 0.5) / 0.03, 2.0));
  float sharp = saturate((r - abs(local)) / fw + 0.5);
  return mix(sharp, 2.0 * r / spacing, smoothstep(0.25, 0.6, fw / spacing));
}

// ---- strip tiles ----

struct StripOut {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float3 color;
  float2 uv;
  float material;
};

vertex StripOut strip_vs(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(kBufferVertices)]],
                         constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float3 &offset [[buffer(kBufferInstances)]]) {
  MeshVertex v = verts[vid];
  StripOut o;
  o.world = float3(v.p[0], v.p[1], v.p[2]) + offset;
  o.position = u.viewProj * float4(o.world, 1.0);
  o.normal = float3(v.n[0], v.n[1], v.n[2]);
  o.color = float3(v.c[0], v.c[1], v.c[2]);
  o.uv = float2(v.uv[0], v.uv[1]);
  o.material = v.material;
  return o;
}

fragment SceneColor strip_fs(StripOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                             constant SeasideUniforms &c [[buffer(kBufferSeaside)]], depth2d_array<float> shadowMap [[texture(kTextureShadow)]],
                             texture2d<float> clouds [[texture(kTextureClouds)]]) {
  int m = int(in.material + 0.5);
  float3 n = normalize(in.normal);
  float alpha = 1.0;
  Surface s;
  if (m == kStripPaving) {
    s = pavingSurface(in.uv, in.color.x, in.world, u);
  } else if (m == kStripSand) {
    s = sandSurface(in.uv.x, in.world, n, u, c);
  } else if (m == kStripWall) {
    s = makeSurface(wallAlbedo(in.uv, in.world, u), n);
  } else if (m == kStripCurb) {
    float3 p = in.world + float3(0, 0, u.originZ);
    s = makeSurface(rgb8(132, 130, 126) * (0.85 + 0.25 * valueNoise(p.xz * 9.0 + p.y * 5.0)) * (1.0 - 0.3 * u.wetness), n);
  } else {  // the balustrade's stone; far off, its balusters' pattern
    if (m == kStripScreen) {
      alpha = balusterCoverage(in.uv);
      if (in.world.z + u.originZ >= c.balusterFarZ || alpha <= 0.0) discard_fragment();
    }
    s = makeSurface(stoneAlbedo(in.world, u), n);
  }
  if (u.wetness > 0.0 && m != kStripPaving && m != kStripSand) {
    s.specular = 0.02 * u.wetness;
    s.roughness = 0.35;
  }
  float shadow = shadowSoftAt(in.world, n, u, shadowMap);
  float3 ambientPart;
  float3 col = seasideLight(s, in.world, shadow, in.position.xy, u, c, clouds, ambientPart);
  return sceneColor(col, ambientPart, in.world, alpha, u);
}

// ---- the pine park's ground ----

struct ParkOut {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float inland;
};

vertex ParkOut park_vs(uint vid [[vertex_id]], const device float2 *grid [[buffer(kBufferVertices)]],
                       constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float2 &offset [[buffer(kBufferInstances)]],
                       constant SeasideUniforms &c [[buffer(kBufferSeaside)]]) {
  float2 xz = grid[vid] + offset;
  float zAbs = xz.y + u.originZ;
  float inland = -(xz.x - SeasidePathX(zAbs)) * c.seaSign - c.promenadeWidth;
  float y = SeasideParkY(inland, xz.x, zAbs);
  float e = 0.5;
  float dx = SeasideParkY(inland, xz.x + e, zAbs) - SeasideParkY(inland, xz.x - e, zAbs);
  float dz = SeasideParkY(inland, xz.x, zAbs + e) - SeasideParkY(inland, xz.x, zAbs - e);
  if (inland < -4.0) y = -40.0;  // under the promenade and beyond the wall: out of sight
  ParkOut o;
  o.world = float3(xz.x, y, xz.y);
  o.position = u.viewProj * float4(o.world, 1.0);
  o.normal = normalize(float3(-dx, 2.0 * e, -dz));
  o.inland = inland;
  return o;
}

fragment SceneColor park_fs(ParkOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                            constant SeasideUniforms &c [[buffer(kBufferSeaside)]], depth2d_array<float> shadowMap [[texture(kTextureShadow)]],
                            texture2d<float> clouds [[texture(kTextureClouds)]]) {
  if (in.inland < -3.0) discard_fragment();
  float2 p = float2(in.world.x, in.world.z + u.originZ);
  float detail = 1.0 - smoothstep(20.0, 70.0, length(in.world - u.camPos));
  float n1 = fbm(p * 0.06, 3), n2 = valueNoise(p * 0.8), n3 = mix(0.5, valueNoise(p * 5.0), detail);
  // Sandy soil under a litter of needles, tufts of dry grass, a little green in the hollows.
  float3 soil = rgb8(150, 136, 112), needles = rgb8(104, 82, 60), dry = rgb8(146, 138, 98), green = rgb8(84, 96, 58);
  float litter = smoothstep(0.4, 0.62, n1 + (n2 - 0.5) * 0.3);
  float3 albedo = mix(soil, needles, litter);
  albedo = mix(albedo, dry, smoothstep(0.55, 0.75, n2) * (1.0 - litter) * 0.8);
  albedo = mix(albedo, green, smoothstep(0.62, 0.8, valueNoise(p * 0.15 + 3.0)) * 0.5);
  albedo *= (0.85 + 0.3 * n3) * (1.0 - 0.35 * u.wetness);
  Surface s = makeSurface(albedo, normalize(in.normal));
  float shadow = shadowAt(in.world, s.normal, u, shadowMap);
  float3 ambientPart;
  float3 col = seasideLight(s, in.world, shadow, in.position.xy, u, c, clouds, ambientPart);
  return sceneColor(col, ambientPart, in.world, 1.0, u);
}

// ---- the far shore ----

/// The far shore's skyline as elevation angles (radians) at azimuth `phi` (0: back along the
/// coast; positive: inland): x nearer hills and headlands along the coast, y higher, hazier
/// mountains behind them.
static float2 farSkyline(float phi) {
  float coast = smoothstep(-0.09, 0.05, phi) * (1.0 - smoothstep(2.7, 3.1, phi));
  float near = (0.003 + 0.011 * valueNoise(float2(phi * 9.0, 1.3)) + 0.005 * valueNoise(float2(phi * 33.0, 2.9))) * coast;
  float inland = smoothstep(0.0, 0.45, phi) * (1.0 - smoothstep(2.4, 3.0, phi));
  float far = (0.01 + 0.028 * valueNoise(float2(phi * 3.7, 7.1)) + 0.012 * valueNoise(float2(phi * 14.0, 8.3)) +
               0.004 * valueNoise(float2(phi * 55.0, 9.9))) * inland;
  return float2(near, far);
}

/// The far land toward `dir`, hazed, if the skyline is there.
static bool farLand(float3 dir, constant FrameUniforms &u, constant SeasideUniforms &c, thread float3 &col) {
  float phi = atan2(-c.seaSign * dir.x, -dir.z);
  float el = asin(clamp(dir.y, -1.0, 1.0));
  float2 skyline = farSkyline(phi);
  if (el > max(skyline.x, skyline.y)) return false;
  bool near = el < skyline.x;
  float3 lit = rgb8(64, 74, 56) * (u.skyAmbient * 0.6 + u.groundAmbient * 0.3 + u.skySun * max(u.sunDir.y, 0.0) * 0.35);
  float haze = 1.0 - exp(-u.fogDensity * (near ? 6500.0 : 20000.0));
  haze = max(haze, near ? 0.35 : 0.6);
  col = mix(lit * (near ? 1.0 : 0.85), coastHazeColor(dir, u), haze);
  return true;
}

// ---- the sea ----

/// Whitecaps: where crests steepen (crest → 1) the wind breaks them into patches and streaks of
/// foam. `q`: absolute xz (m); `foot`: metres a pixel covers.
static float whitecapFoam(float2 q, float crest, float foot, constant FrameUniforms &u, constant SeasideUniforms &c) {
  if (c.whitecaps <= 0.0) return 0.0;
  float2 w = u.windDir, a = float2(-w.y, w.x);
  float2 r = float2(dot(q, w), dot(q, a));
  float patches = valueNoise(r * float2(0.06, 0.15) - float2(u.time * 0.15, 0.0));
  float streaks = valueNoise(r * float2(0.025, 0.7));
  float f = smoothstep(0.0, 0.3, crest * 0.8 + patches * 0.6 + streaks * 0.3 - 1.25 + c.whitecaps * 0.55);
  return saturate(f * (0.5 + 0.8 * foamLace(r, foot))) * c.whitecaps;
}

/// The sea at `world`: the sky and the far shore mirrored, the sun's glitter, light from inside
/// the water (turquoise in crests the low sun shines through), whitecaps and surf, fogged. `p` is
/// where its waves are evaluated (xz relative to the eye, before the waves moved it), `s`
/// seaward, `level` the swash's lift. rgb is premultiplied: a < 1 where shallow water shows the
/// sand under it.
static float4 seaShade(float3 world, float2 p, float s, float level, float2 pixel, constant FrameUniforms &u,
                       constant SeasideUniforms &c, constant SeaWaves &W, texture2d<float> clouds) {
  float3 v = normalize(world - u.camPos);
  // The pixel's footprint on the water (worked out from the view ray, so smooth from triangle to
  // triangle): across the view, and along it, stretched at a glance.
  float pix = length(world - u.camPos) / u.projScale;
  float2 vh = normalize(v.xz + 1e-6);
  float2 dpx = vh * pix / max(abs(v.y), 0.015), dpy = float2(-vh.y, vh.x) * pix;
  float zAbs = world.z + u.originZ;
  float x = s - kShoreS;
  float open = smoothstep(-1.0, 25.0 + c.surf * 15.0, x);  // nearer the shore the swell has broken
  // Every wave where the pixel resolves it; the slopes of the rest as roughness.
  float3 g = float3(0, 1, 0);
  float var = 0.0012, height = 0.0, crest = 0.0;
  for (int i = 0; i < kSeaWaves; i++) {
    float4 w = W.wave[i];
    float k = length(w.xy);
    float per = max(abs(dot(w.xy, dpx)), abs(dot(w.xy, dpy)));  // phase change from pixel to pixel
    float keep = 1.0 - smoothstep(0.3, 0.8, per);  // waves under ~8 px alias into dots of glitter
    float ka = k * w.z * (i < kSeaBigWaves ? open : 1.0);
    var += ka * ka * 0.5 * (1.0 - keep * keep);
    if (keep <= 0.0) continue;
    float cs;
    float sn = sincos(dot(w.xy, p) + w.w, cs);
    float wa = ka * keep;
    g.xz -= w.xy / k * (wa * cs);
    g.y -= W.steep[i] * wa * sn;
    height += w.z * sn * keep * (i < kSeaBigWaves ? open : 1.0);
    crest += W.steep[i] * wa * sn;
  }
  float3 n = normalize(g);
  float sigma = sqrt(var);
  // What it mirrors: the facets the eye sees tilt toward it, so rough water mirrors higher sky.
  // At a glance it is the facets turned toward the eye that it sees: they mirror sky well above
  // the horizon, at a steeper angle (less Fresnel) than the mean surface would.
  float cosI = saturate(dot(-v, n));
  float glance = (1.0 - cosI) * (1.0 - cosI);
  float F = 0.02 + 0.98 * pow(1.0 - max(cosI, sigma * 1.3), 5.0);
  float3 r = reflect(v, n);
  r = normalize(float3(r.x, abs(r.y) + sigma * (0.4 + 1.2 * glance), r.z));
  float3 mirrored;
  if (!farLand(r, u, c, mirrored)) mirrored = coastSky(r, u, clouds, 6, 0.5 + sigma * 8.0, coastIGN(pixel));
  // The sun's glitter: Beckmann over the unresolved slopes.
  float sunlit = coastSunlight(world, u, clouds) * step(0.0, u.sunDir.y);
  float3 hv = normalize(u.sunDir - v);
  float nh = max(dot(n, hv), 0.05), nh2 = nh * nh;
  float D = exp(-(1.0 - nh2) / (nh2 * var)) / (3.14159 * var * nh2 * nh2);
  float Fs = 0.02 + 0.98 * pow(1.0 - saturate(dot(hv, -v)), 5.0);
  float glint = min(Fs * D / (4.0 * max(cosI, 0.05)) * saturate(dot(n, u.sunDir) * 4.0), 40.0);
  float3 sun = u.skySun * glint * sunlit;
  // Light from inside the water; turquoise in the crests the low sun shines through.
  float3 body = c.deepColor * (u.skyAmbient * 0.8 + u.skySun * max(u.sunDir.y, 0.0) * sunlit);
  float2 sh = normalize(u.sunDir.xz + 1e-5);
  float through = pow(saturate(dot(vh, sh)), 3.0) * saturate(height * 1.2 + crest * 0.8 + 0.15);
  body += rgb8(40, 150, 130) * 0.06 * u.skySun * sunlit * through;
  // Foam: whitecaps out at sea, the surf near the beach.
  float foot = length(dpx);
  float2 q = float2(world.x, zAbs);
  float2 surf = surfAt(s, zAbs, u.time, c);
  float foam = whitecapFoam(q, crest, foot, u, c) * open;
  foam = max(foam, smoothstep(0.2, 0.65, surf.y * foamLace(q, foot) * 1.3));
  float3 foamLit = 0.85 * (u.skyAmbient * 1.2 + u.skyHorizon * 0.25 + u.skySun * max(u.sunDir.y, 0.0) * sunlit * 0.8);
  // Shallow water shows the sand under it.
  float depth = max(level + height - SeasideSandY(s), 0.0);
  float T = exp(-depth * 1.1) * (1.0 - F) * (1.0 - foam);
  float3 col = F * mirrored + sun + foam * foamLit + (1.0 - F) * (1.0 - foam) * (1.0 - exp(-depth * 1.1)) * body;
  float alpha = 1.0 - T;
  float fog = 1.0 - exp(-fogDepth(u.camPos, world - u.camPos, u));
  return float4(mix(col, coastHazeColor(v, u) * alpha, fog), alpha);
}

struct SeaOut {
  float4 position [[position]];
  float3 world;
  float2 p;      // xz relative to the eye, before the waves moved it
  float s;       // seaward
  float level;   // the swash's lift
};

vertex SeaOut sea_vs(uint vid [[vertex_id]], const device float2 *grid [[buffer(kBufferVertices)]],
                     constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float2 &center [[buffer(kBufferInstances)]],
                     constant SeasideUniforms &c [[buffer(kBufferSeaside)]], constant SeaWaves &W [[buffer(kBufferWaves)]]) {
  float2 off = grid[vid];
  off.x *= c.seaSign;
  float2 xz = center + off;
  float spacing = length(off) * 0.021 + 0.02;  // the grid's cell here (SeasideScene.m: buildSeaGrid)
  float2 p = xz - c.eye;
  float zAbs = xz.y + u.originZ;
  float s = (xz.x - SeasidePathX(zAbs)) * c.seaSign;
  float open = smoothstep(-1.0, 25.0 + c.surf * 15.0, s - kShoreS);
  float3 pos = float3(xz.x, 0.0, xz.y);
  // The longest waves move the vertices (those the grid is fine enough for).
  for (int i = 0; i < kSeaBigWaves; i++) {
    float4 w = W.wave[i];
    float k = length(w.xy);
    float keep = (1.0 - smoothstep(0.1, 0.22, spacing * k / 6.2832)) * open;
    if (keep <= 0.0) continue;
    float cs;
    float sn = sincos(dot(w.xy, p) + w.w, cs);
    pos.y += w.z * sn * keep;
    pos.xz += W.steep[i] * w.z * (w.xy / k) * cs * keep;
  }
  float2 surf = surfAt(s, zAbs, u.time, c);
  float lift = surf.x * (1.0 - smoothstep(2.0, 10.0, s - kShoreS));
  pos.y += lift;
  SeaOut o;
  o.world = pos;
  o.p = p;
  o.s = s;
  o.level = lift;
  o.position = u.viewProj * float4(pos, 1.0);
  return o;
}

fragment float4 sea_fs(SeaOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]], constant SeasideUniforms &c [[buffer(kBufferSeaside)]],
                       constant SeaWaves &W [[buffer(kBufferWaves)]], texture2d<float> clouds [[texture(kTextureClouds)]]) {
  if (in.s < kShoreS - 8.0) discard_fragment();  // the grid reaches past the coast (it bends)
  return seaShade(in.world, in.p, in.s, in.level, in.position.xy, u, c, W, clouds);
}

// ---- beyond the far plane ----

struct FarOut {
  float4 position [[position]];
  float2 ndc;
};

// Just in front of the far plane: the sky (CoastEnvironment) then draws only where this discards.
vertex FarOut far_vs(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
  FarOut o;
  o.position = float4(p, 0.9999998, 1.0);
  o.ndc = p;
  return o;
}

fragment float4 far_fs(FarOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]], constant SeasideUniforms &c [[buffer(kBufferSeaside)]],
                       constant SeaWaves &W [[buffer(kBufferWaves)]], texture2d<float> clouds [[texture(kTextureClouds)]]) {
  float4 farPoint = u.invViewProj * float4(in.ndc, 1.0, 1.0);
  float3 dir = normalize(farPoint.xyz / farPoint.w - u.camPos);
  // Where the ray meets the curved sea (the stable form of the nearer root); beyond the horizon, sky.
  float h = max(u.camPos.y, 0.3);
  float disc = dir.y * dir.y - 2.0 * h / kEarthRadius;
  bool sea = dir.y < 0.0 && disc > 0.0;
  float t = sea ? 2.0 * h / (-dir.y + sqrt(max(disc, 0.0))) : 0.0;
  float3 hit = float3(u.camPos.x + dir.x * t, 0.0, u.camPos.z + dir.z * t);
  float2 p = hit.xz - c.eye;
  if (sea) {
    float s = seawardOf(hit, u, c);
    if (s > kShoreS) return float4(seaShade(hit, p, s, 0.0, in.position.xy, u, c, W, clouds).rgb, 1.0);
    float3 land = rgb8(60, 66, 48) * (u.skyAmbient * 0.6 + u.skySun * max(u.sunDir.y, 0.0) * 0.4);
    return float4(mix(land, coastHazeColor(dir, u), 1.0 - exp(-fogDepth(u.camPos, dir * t, u))), 1.0);
  }
  float3 col;
  if (farLand(dir, u, c, col)) return float4(col, 1.0);
  discard_fragment();
  return 0.0;
}

// ---- props, pines, balusters ----

fragment SceneColor seaside_prop_fs(PlantOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                                    constant PlantUniforms &f [[buffer(kBufferScene)]], constant SeasideUniforms &c [[buffer(kBufferSeaside)]],
                                    depth2d_array<float> shadowMap [[texture(kTextureShadow)]], texture2d<float> atlas [[texture(kTextureScene)]],
                                    texture2d<float> clouds [[texture(kTextureClouds)]]) {
  float alpha;
  Surface s = plantSurface(in, u, f, atlas, alpha);
  int m = int(in.material + 0.5);
  bool leaf = in.material >= kMaterialCard - 0.5;
  if (m == kMaterialStone) {
    s.albedo = stoneAlbedo(in.world, u) * in.bright;
    s.specular = 0.0;
    s.roughness = 1.0;
  } else if (m == kMaterialBark) {  // pine bark: grey-brown plates, red-brown in the fissures
    float2 b = float2(in.uv.x * 7.0, in.uv.y * 1.4);
    float plates = valueNoise(b) * 0.6 + valueNoise(b * 2.7) * 0.4;
    float3 bark = mix(rgb8(52, 42, 36), rgb8(112, 72, 52), smoothstep(0.42, 0.62, plates));
    s.albedo = bark * in.bright * (1.0 - 0.3 * u.wetness);
  }
  if (u.wetness > 0.0 && !leaf && s.specular <= 0.0) {
    s.specular = 0.02 * u.wetness;
    s.roughness = 0.4;
  }
  // Needles take the plain shadow filter: inside a crown the soft one costs much and shows little.
  float shadow = leaf ? shadowAt(in.world, normalize(in.normal), u, shadowMap) : shadowSoftAt(in.world, normalize(in.normal), u, shadowMap);
  float3 ambientPart;
  float3 col = seasideLight(s, in.world, shadow, in.position.xy, u, c, clouds, ambientPart);
  return sceneColor(col, ambientPart, in.world, alpha, u);
}
