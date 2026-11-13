// The sky over the sea (CoastEnvironment; constants in CoastSky.h). Part of the host's library,
// where coast_sky_fs draws it behind the scene, and of the scenes that mirror it (the sea), which
// call coastSky. Compiled after SceneShared.h, Common.metal and CoastSky.h.
//
//   - The atmosphere: horizon to zenith, warmer and brighter toward a low sun, the sun's glow and
//     disk. u.skySun is the sun as the sky sees it; u.sunColor is what reaches the scene (none
//     under a storm's deck while the sky toward the horizon is still sunlit).
//   - Clouds: a slab from cloudBase to cloudBase + cloudDepth, raymarched. Density comes from a
//     tileable noise texture (coast_bake_noise: R large fbm, G billows from inverted Worley noise,
//     B detail, A slow fbm: where clouds gather, where it rains), stretched along the wind: large
//     shapes cut at a threshold (coverage), their edges carved by billows and fine noise; flat
//     bases, rounded tops; a deck (overcast, storm) thick and thin in cells, its base ragged in a
//     storm. Each sample is lit by the sun through the cloud toward it (three samples out to
//     1.5 km: a low sun reaches few clouds; Beer's law plus a little light scattered many times;
//     a forward-scattering phase: rims glow near the sun; thin edges dark away from it), by the
//     sky through the cloud above it (from below, thick parts are darker) and by the sea. The
//     noise's mip level follows the pixel's footprint on the layer (stretched at a glance).
//     Toward the horizon, sooner toward the sun, the layer gives way to clear sky: light under
//     the clouds at sunset, a bright band under a storm.
//   - Cirrus: thin streaks high up, stretched along the wind.
//   - Night (u.stars): stars and the Milky Way's band. Contrails (u.contrails): aircraft trails
//     10 km up, a bright head drawing a line that widens and breaks up behind it.
//   - Rain: grey curtains under storm clouds, slanted by the wind.
//   - Haze: the clear sky behind the whole path's haze, clouds and rain behind the haze up to
//     their distance; its colour glows toward the sun as the sky sees it (coastHazeColor).

constexpr sampler kCloudSampler(coord::normalized, filter::linear, mip_filter::linear, address::repeat);

// ---- the cloud noise, baked once (CoastCloudNoise) ----

static float2 coastGradient(int2 c, int period, uint seed) {
  uint2 w = uint2(((c % period) + period) % period);
  float a = hashU(uint3(w, seed)) * 6.2831853;
  return float2(cos(a), sin(a));
}

/// Gradient noise repeating every `period` cells (about −0.7 … 0.7).
static float coastPerlin(float2 p, int period, uint seed) {
  float2 i = floor(p), f = p - i;
  int2 c = int2(i);
  float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  float n00 = dot(coastGradient(c, period, seed), f);
  float n10 = dot(coastGradient(c + int2(1, 0), period, seed), f - float2(1, 0));
  float n01 = dot(coastGradient(c + int2(0, 1), period, seed), f - float2(0, 1));
  float n11 = dot(coastGradient(c + int2(1, 1), period, seed), f - float2(1, 1));
  return mix(mix(n00, n10, w.x), mix(n01, n11, w.x), w.y);
}

/// Tileable fbm over uv ∈ [0, 1)²: 0 … 1 around 0.5.
static float coastFbm(float2 uv, int period, uint seed, int octaves) {
  float sum = 0, amp = 0.5, norm = 0;
  for (int o = 0; o < octaves; o++) {
    int per = period << o;
    sum += amp * coastPerlin(uv * float(per), per, seed + uint(o) * 101u);
    norm += amp;
    amp *= 0.5;
  }
  return saturate(sum / norm * 1.15 + 0.5);
}

/// Tileable Worley noise: the distance to the nearest feature point, in cells (0 … ~1).
static float coastWorley(float2 uv, int period, uint seed) {
  float2 p = uv * float(period), i = floor(p), f = p - i;
  float d = 2.0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      int2 c = int2(i) + int2(x, y);
      uint2 w = uint2(((c % period) + period) % period);
      float2 pt = float2(hashU(uint3(w, seed)), hashU(uint3(w, seed + 7u)));
      d = min(d, length(float2(x, y) + pt - f));
    }
  }
  return saturate(d);
}

kernel void coast_bake_noise(texture2d<float, access::write> dst [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
  float large = coastFbm(uv, 4, 11u, 6);
  float billows = 1.0 - (0.55 * coastWorley(uv, 6, 21u) + 0.3 * coastWorley(uv, 12, 23u) + 0.15 * coastWorley(uv, 24, 25u));
  float detail = coastFbm(uv, 24, 31u, 4);
  float slow = coastFbm(uv, 2, 41u, 4);
  dst.write(float4(large, billows, detail, slow), gid);
}

// ---- the atmosphere ----

/// Interleaved gradient noise: a different offset per pixel for the clouds' march (no banding).
static float coastIGN(float2 pixel) {
  return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

/// The clear sky toward `dir`, without the sun's disk: a band at the horizon, a paler band above
/// it, the zenith's colour higher up. Toward a low sun the horizon glows warm and the band above it
/// is golden; away from it the horizon is pink and the band pale blue. Then the sun's glow.
static float3 coastAtmosphere(float3 dir, constant FrameUniforms &u) {
  float y = max(dir.y, 0.0);
  float2 hd = dir.xz * rsqrt(max(dot(dir.xz, dir.xz), 1e-8));
  float2 hs = u.sunDir.xz * rsqrt(max(dot(u.sunDir.xz, u.sunDir.xz), 1e-8));
  float w = (0.5 + 0.5 * dot(hd, hs));
  w *= w;
  float low = 1.0 - smoothstep(0.05, 0.5, u.sunDir.y);
  float3 horizon = mix(u.skyHorizon, mix(u.skyHorizon * float3(0.36, 0.67, 2.35), u.skyHorizon * 1.3, w), low);
  float3 mid = mix((u.skyHorizon + u.skyZenith) * 0.5, mix(u.skyZenith * 2.4 + 0.04, u.skyHorizon * 0.55 + 0.18, w), low);
  float h1 = exp(-y * 14.0), h2 = exp(-y * 3.5);
  float3 c = u.skyZenith * (1.0 - h2) + mid * (h2 - h1) + horizon * h1;
  float g = saturate(dot(dir, u.sunDir));
  return c + u.skySun * (0.045 * pow(g, 3.0) + 0.14 * pow(g, 18.0) + 0.7 * pow(g, 250.0)) * u.sunDisk;
}

static float3 coastSunDisk(float3 dir, constant FrameUniforms &u) {
  return u.skySun * 24.0 * smoothstep(0.999955, 0.999975, dot(dir, u.sunDir)) * u.sunDisk;
}

/// How hazy the sky is toward `dir` (0 … 1): the haze layer is crossed on a longer path toward
/// the horizon.
static float coastSkyHaze(float3 dir, constant FrameUniforms &u) {
  float y = max(dir.y, 0.0) + 0.012;
  float od = u.fogDensity * 0.3 / (max(u.fogFalloff, 2e-4) * y) * exp(-u.fogFalloff * max(u.camPos.y, 0.0));
  return 1.0 - exp(-od);
}

/// The haze's colour toward `dir`: lit by the sun as the sky sees it (u.skySun), so that it glows
/// toward the sun even when the scene is in a storm's shade.
static float3 coastHazeColor(float3 dir, constant FrameUniforms &u) {
  return u.fogColor + u.skySun * u.inscatter * 0.25 * pow(saturate(dot(dir, u.sunDir)), 6.0);
}

// ---- clouds ----

struct CoastLayer {
  float base, top, cover, storm, clear, clearFrom, cumulus;
  float2 origin;  // the eye in noise coordinates, drifting with the wind
  float2 sunXZ;   // the sun's horizontal direction
  float2 along;   // the wind's direction: clouds are drawn out along it (streets)
};

/// Metres (horizontal) → noise coordinates: stretched along the wind.
static float2 coastNoiseOffset(float2 v, CoastLayer c) {
  float2 across = float2(-c.along.y, c.along.x);
  return (c.along * (dot(v, c.along) * 0.62) + across * (dot(v, across) * 1.2)) * (1.0 / kCloudTile);
}

static CoastLayer coastLayer(constant FrameUniforms &u) {
  CoastLayer c;
  c.base = u.cloudBase;
  c.top = u.cloudBase + max(u.cloudDepth, 10.0);
  c.cover = u.cloudCover;
  c.storm = u.storm;
  c.cumulus = u.cumulus;
  c.clear = u.clearHorizon;
  c.clearFrom = max(u.clearDistance, 1000.0);
  float drift = u.time * (3.0 + 0.8 * u.wind);
  c.along = dot(u.windDir, u.windDir) > 0.0 ? normalize(u.windDir) : float2(1, 0);
  c.origin = coastNoiseOffset(float2(u.camPos.x, u.camPos.z + u.originZ) - c.along * drift, c);
  c.sunXZ = u.sunDir.xz * rsqrt(max(dot(u.sunDir.xz, u.sunDir.xz), 1e-8));
  return c;
}

/// The cloud at height y, `off` metres (horizontally) from the eye: x its density (0 … 1), y the
/// top of its column (a fraction of the layer). `quality` 2: the full shape and its edges eroded
/// by fine noise; 1: the full shape; 0: only the large shapes (light from far away). `lod`: the
/// mip level for the largest octave (log2 of the footprint in its texels; may be negative).
static float2 coastDensity(float2 off, float y, CoastLayer c, texture2d<float> noise, float lod, int quality) {
  float h = (y - c.base) / (c.top - c.base);
  if (h <= 0.0 || h >= 1.0) return 0.0;
  float2 q = c.origin + coastNoiseOffset(off, c);
  // Heaped clouds: the outline shifts with height, so their sides billow instead of standing
  // like walls.
  if (c.cumulus > 0.0) q += (h - 0.25) * c.cumulus * float2(0.011, -0.007) * (c.top - c.base) * (1.0 / 900.0);
  float4 n = noise.sample(kCloudSampler, q, level(max(lod, 0.0)));
  float slow = noise.sample(kCloudSampler, q * 0.29 + float2(0.37, 0.71), level(max(lod - 1.8, 0.0))).a;
  float billows = quality > 0 ? noise.sample(kCloudSampler, q * 2.7 + float2(0.71, 0.13), level(max(lod + 1.4, 0.0))).g : 0.62;
  // Clear sky toward the horizon, sooner toward the sun.
  float dist = length(off);
  float toSun = 0.5 + 0.5 * dot(off, c.sunXZ) / max(dist, 1.0);
  float from = c.clearFrom * mix(2.2, 1.0, toSun);
  float cover = c.cover * (1.0 - c.clear * smoothstep(from, from * 1.8, dist));
  // Inside a cloud where the large shapes clear the threshold; the billows only carve their
  // edges (they never make clouds of their own). Thicker further in.
  float edge = n.r * 0.5 + n.g * 0.5 + (slow - 0.5) * 0.6 - (1.0 - cover);
  // … and they narrow upward into domes and turrets.
  if (c.cumulus > 0.0) edge -= c.cumulus * h * sqrt(h) * (0.1 + 0.3 * billows);
  edge -= (1.0 - billows) * 0.16 * (1.0 - smoothstep(0.0, 0.18, edge));
  if (edge <= 0.0) return 0.0;
  float thick = saturate(edge / (0.12 + 0.55 * cover));
  // A flat base (ragged under a storm), a rounded top, higher where the cloud is thicker.
  float bottom = c.storm * 0.14 * noise.sample(kCloudSampler, q * 0.6 + float2(0.4, 0.8), level(max(lod - 0.7, 0.0))).b;
  float top = mix(0.12, 1.0, sqrt(thick)) * (0.7 + 0.3 * billows);
  // A deck (overcast, a storm) is thick and thin in cells: brighter from below where it is thin.
  float cells = saturate((billows - 0.45) * 2.6 + (n.r - 0.5) * 1.2);
  top = mix(top, mix(0.18, 1.0, cells), smoothstep(0.75, 0.95, cover));
  // (No wisps of cloud at the very threshold: they read as cotton balls.)
  float d = smoothstep(0.03, 0.055, edge) * smoothstep(bottom, bottom + 0.05, h) * (1.0 - smoothstep(top * 0.6, top, h));
  // (Heaped clouds seen from near: soft, ragged edges and bases instead of cut ones.)
  if (c.cumulus > 0.0) d = mix(d, smoothstep(0.0, 0.3, edge) * smoothstep(bottom, bottom + 0.3, h) * (1.0 - smoothstep(top * 0.35, top, h)), c.cumulus);
  if (quality > 1 && d > 0.0) {  // cauliflower billows and wisps on the edges, texture inside
    float e = noise.sample(kCloudSampler, q * 7.3 + float2(0.13, 0.29), level(max(lod + 2.9, 0.0))).b;
    float b = noise.sample(kCloudSampler, q * 11.0 + float2(0.53, 0.17), level(max(lod + 3.5, 0.0))).g;
    d -= (1.0 - e) * 0.5 * (1.0 - thick * 0.5) + (1.0 - b) * 0.45 * (1.0 - thick * 0.7);
  }
  return float2(saturate(d * 1.4), top);
}

/// Henyey–Greenstein, normalised so that scattering evenly in all directions is 1.
static float coastHG(float c, float g) {
  float g2 = g * g;
  return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5);
}

/// The clouds toward `dir`: rgb the light they scatter toward the eye, a their opacity. `dist`
/// gets how far they are (weighted by what each step adds). `steps` along the ray through the
/// layer; `lodBias` blurs them (rough water); `jitter` (0 … 1) offsets the steps.
static float4 coastClouds(float3 dir, constant FrameUniforms &u, texture2d<float> noise, int steps, float lodBias, float jitter, thread float &dist) {
  dist = 0.0;
  if (u.cloudCover <= 0.0 || dir.y < 0.003) return 0.0;
  CoastLayer c = coastLayer(u);
  float y0 = u.camPos.y;
  float t0 = (c.base - y0) / dir.y;
  if (t0 > 50000.0) return 0.0;
  float t1 = min((c.top - y0) / dir.y, t0 + 6000.0);
  float dt = (t1 - t0) / float(steps);
  float cosT = dot(dir, u.sunDir);
  float phase = mix(coastHG(cosT, 0.5), coastHG(cosT, -0.2), 0.3);
  const float sigma = 0.02;  // extinction per metre at density 1
  float3 L = u.sunDir;
  float H = c.top - c.base;
  float3 sum = 0.0;
  float T = 1.0, tw = 0.0, ws = 0.0;
  for (int i = 0; i < steps; i++) {
    float t = t0 + (float(i) + jitter) * dt;
    float2 off = dir.xz * t;
    float y = y0 + dir.y * t;
    // The pixel's footprint on the layer, stretched along the view at a glance.
    float lod = lodBias + clamp(log2(t / (u.projScale * max(dir.y, 0.03)) * (kCloudNoiseSize / kCloudTile)), -6.0, 5.0);
    float2 dc = coastDensity(off, y, c, noise, lod, 2);
    if (dc.x <= 0.003) continue;
    float h = (y - c.base) / H;
    // Sunlight through this cloud toward the sun, and past the clouds further that way (a low sun
    // reaches few of them).
    float l1 = coastDensity(off + L.xz * 100.0, y + L.y * 100.0, c, noise, lod + 0.5, 2).x;
    float l2 = coastDensity(off + L.xz * 400.0, y + L.y * 400.0, c, noise, lod + 1.0, 0).x;
    float l3 = coastDensity(off + L.xz * 1500.0, y + L.y * 1500.0, c, noise, lod + 1.5, 0).x;
    float od = (l1 * 100.0 + l2 * 300.0 + l3 * 700.0 + dc.x * 40.0) * sigma;
    float sun = exp(-od) + 0.08 * exp(-od * 0.1);
    // Thin edges facing away from the sun scatter little toward the eye ("powder").
    sun *= mix(1.0 - exp(-dc.x * 5.0), 1.0, saturate(cosT * 0.5 + 0.5));
    // Skylight through the cloud above this point (from below, thick parts are darker; seen from
    // the side, far off, the sky lights the cloud's side); less of it under a storm's deck.
    float above = mix(1.0, exp(-max(dc.y - h, 0.0) * H * dc.x * sigma * 0.15), smoothstep(0.03, 0.25, dir.y));
    float3 amb = u.cloudColor * (0.25 + 0.75 * above) * (1.0 - 0.6 * c.storm * (1.0 - h));
    float3 S = u.skySun * phase * sun * 0.75 + amb;
    float a = 1.0 - exp(-dc.x * sigma * dt);
    sum += T * a * S;
    tw += T * a * t;
    ws += T * a;
    T *= 1.0 - a;
    if (T < 0.02) break;
  }
  dist = ws > 0.0 ? tw / ws : t0;
  return float4(sum, 1.0 - T);
}

/// Cirrus: thin streaks 8.5 km up, stretched along the wind (rgb premultiplied, a opacity).
static float4 coastCirrus(float3 dir, constant FrameUniforms &u, texture2d<float> noise, float lodBias) {
  if (u.cirrus <= 0.0 || dir.y < 0.01) return 0.0;
  float t = (8500.0 - u.camPos.y) / dir.y;
  float2 off = dir.xz * t + float2(u.camPos.x, u.camPos.z + u.originZ) * 0.3;
  float2 w = u.windDir, across = float2(-w.y, w.x);
  float2 q = float2(dot(off, w), dot(off, across) * 2.2) * (1.0 / (kCloudTile * 2.5)) + float2(0.19, 0.53) + u.time * 0.00002;
  float lod = lodBias + max(log2(t / 30000.0), 0.0) + 0.5;
  float s = noise.sample(kCloudSampler, q, level(lod)).b;
  float m = noise.sample(kCloudSampler, q * 0.23 + float2(0.6, 0.1), level(lod)).r;
  float a = smoothstep(0.5, 0.85, s * 0.45 + m * 0.75 - 0.1) * u.cirrus * smoothstep(0.01, 0.1, dir.y) * 0.7;
  float cosT = dot(dir, u.sunDir);
  float3 col = u.skySun * (0.12 + 0.18 * coastHG(cosT, 0.6)) + u.cloudColor * 0.55;
  return float4(col * a, a);
}

/// Stars (a few bright, many faint, slightly coloured) and the Milky Way, behind everything.
static float3 coastStars(float3 dir, constant FrameUniforms &u) {
  if (u.stars <= 0.0 || dir.y <= 0.0) return 0.0;
  float3 sum = 0.0;
  for (int layer = 0; layer < 2; layer++) {
    float2 q = dir.xz / (dir.y + 0.4) * (layer == 0 ? 70.0 : 170.0);
    float2 cell = floor(q);
    uint3 k = uint3(uint(int(cell.x) + 8192), uint(int(cell.y) + 8192), uint(31 + layer * 7));
    float2 at = float2(hashU(k), hashU(k + uint3(0, 0, 1))) * 0.7 + 0.15;
    float d = length(q - cell - at);
    float mag = pow(hashU(k + uint3(0, 0, 2)), layer == 0 ? 6.0 : 8.0);
    float tint = hashU(k + uint3(0, 0, 3));
    float3 col = mix(float3(1.0, 0.86, 0.7), float3(0.75, 0.85, 1.0), tint);
    sum += col * mag * (1.0 - smoothstep(0.0, layer == 0 ? 0.09 : 0.14, d)) * (layer == 0 ? 1.6 : 0.6);
  }
  // The Milky Way: a band across the sky, mottled.
  float b = dot(dir, normalize(float3(0.55, 0.35, -0.76)));
  float2 mq = float2(atan2(dir.x, -dir.z), b) * 3.0;
  float band = exp(-b * b * 22.0) * (0.35 + 0.65 * fbm(mq * 2.3, 4)) * smoothstep(0.25, 0.8, fbm(mq * 0.9 + 4.0, 3) + 0.25);
  sum += float3(0.75, 0.82, 1.0) * band * 0.05;
  return sum * u.stars * 0.5 * smoothstep(0.02, 0.25, dir.y);
}

/// Contrails 10.5 km above the eye: in each 45 km cell of the sky one aircraft may fly a straight
/// line; its trail starts thin and bright behind it, widens, breaks into puffs and fades over
/// tens of kilometres (rgb premultiplied, a opacity).
static float4 coastContrails(float3 dir, constant FrameUniforms &u, texture2d<float> noise) {
  if (u.contrails <= 0.0 || dir.y < 0.02) return 0.0;
  float t = 10500.0 / dir.y;
  float2 p = dir.xz * t + float2(u.camPos.x, u.camPos.z + u.originZ);
  float foot = t / u.projScale;  // a pixel, in metres up there
  const float size = 45000.0;
  float2 cell = floor(p / size);
  float alpha = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      float2 c = cell + float2(i, j);
      uint3 k = uint3(uint(int(c.x) + 4096), uint(int(c.y) + 4096), 91u);
      if (hashU(k) > 0.62) continue;
      float angle = hashU(k + uint3(0, 0, 1)) * 6.2831853;
      float2 along = float2(cos(angle), sin(angle)), across = float2(-along.y, along.x);
      float2 rel = p - (c + 0.5 + (float2(hashU(k + uint3(0, 0, 2)), hashU(k + uint3(0, 0, 3))) - 0.5) * 0.6) * size;
      // The aircraft crosses the cell's line in about five minutes, again and again.
      const float span = 70000.0;
      float head = (fract(u.time * (230.0 / span) + hashU(k + uint3(0, 0, 4))) - 0.5) * span;
      float behind = head - dot(rel, along);  // metres behind the aircraft
      if (behind < 0.0) continue;
      float age = behind / 38000.0;
      if (age >= 1.0) continue;
      float width = 25.0 + 420.0 * age;
      float side = dot(rel, across) + 260.0 * age * (noise.sample(kCloudSampler, float2(dot(rel, along) * (1.0 / 23000.0), hashU(k)), level(0.0)).r - 0.5);
      float line = 1.0 - smoothstep(width * 0.35, width + foot, abs(side));
      float puffs = noise.sample(kCloudSampler, float2(dot(rel, along) * (1.0 / 3200.0), side * (1.0 / 1500.0)) + hashU(k), level(1.0)).g;
      float a = line * mix(1.0, smoothstep(0.25, 0.7, puffs), smoothstep(0.08, 0.5, age)) * (1.0 - smoothstep(0.35, 1.0, age));
      a *= min(1.0, width / max(foot, 1.0) * 1.2) * smoothstep(0.0, 300.0, behind);
      alpha = max(alpha, a * 0.7);
    }
  }
  alpha *= u.contrails * smoothstep(0.02, 0.1, dir.y);
  float3 col = u.skySun * (0.2 + 0.1 * coastHG(dot(dir, u.sunDir), 0.5)) + u.cloudColor * 0.5;
  return float4(col * alpha, alpha);
}

/// Rain curtains under the clouds of a storm, nearest first, each behind the haze in front of it
/// (rgb premultiplied, a opacity).
static float4 coastRain(float3 dir, constant FrameUniforms &u, texture2d<float> noise) {
  if (u.storm <= 0.0 || dir.y > 0.2) return 0.0;
  CoastLayer c = coastLayer(u);
  float2 across = float2(-dir.z, dir.x) * rsqrt(max(dot(dir.xz, dir.xz), 1e-8));
  float3 col = 0.0, rc = u.cloudColor * 0.3, haze = coastHazeColor(dir, u);
  float T = 1.0;
  const float dists[6] = {1500.0, 2700.0, 4300.0, 6500.0, 9500.0, 14000.0};
  for (int k = 0; k < 6; k++) {
    float t = dists[k];
    float y = u.camPos.y + dir.y * t;
    if (y > c.base) break;
    float2 off = dir.xz * t + u.windDir * (c.base - y) * 0.4;  // slanted by the wind
    float2 q = c.origin + coastNoiseOffset(off, c);
    float r = noise.sample(kCloudSampler, q * 1.9 + float2(0.21, 0.43), level(0.0)).a;
    float rain = smoothstep(0.5, 0.6, r) * u.storm;
    if (rain <= 0.0) continue;
    float streak = noise.sample(kCloudSampler, float2(dot(off, across) * (1.0 / 500.0), y * (1.0 / 9000.0) - u.time * 0.01), level(0.0)).b;
    float a = rain * (0.25 + 0.3 * streak);
    float hz = 1.0 - exp(-fogDepth(u.camPos, dir * t, u));
    col += T * a * mix(rc, haze, hz);
    T *= 1.0 - a;
  }
  return float4(col, 1.0 - T);
}

/// The sky toward `dir` (its upper half: dir.y is clamped to ≥ 0): atmosphere, sun, cirrus,
/// clouds, rain, haze. `steps`: the cloud march (fewer for reflections; 0: no clouds, for rough
/// surfaces that would blur them away); `lodBias` blurs the clouds (rough water); `jitter`
/// (0 … 1, per pixel) against banding.
static float3 coastSky(float3 dir, constant FrameUniforms &u, texture2d<float> noise, int steps, float lodBias, float jitter) {
  dir.y = max(dir.y, 0.0);
  // The clear sky behind the haze of the whole path, then what is in front of it, each behind
  // the haze up to its own distance: cirrus, clouds, rain.
  float3 haze = coastHazeColor(dir, u);
  float3 c = mix(coastAtmosphere(dir, u) + coastSunDisk(dir, u) + coastStars(dir, u), haze, coastSkyHaze(dir, u));
  float4 ci = coastCirrus(dir, u, noise, lodBias);
  c = c * (1.0 - ci.a) + ci.rgb;
  float4 ct = coastContrails(dir, u, noise);
  c = c * (1.0 - ct.a) + ct.rgb;
  float dist = 0.0;
  float4 cl = steps > 0 ? coastClouds(dir, u, noise, steps, lodBias, jitter, dist) : float4(0.0);
  if (cl.a > 0.0) {
    float hz = 1.0 - exp(-fogDepth(u.camPos, dir * dist, u) * 0.35);
    c = c * (1.0 - cl.a) + mix(cl.rgb, haze * cl.a, hz);
  }
  float4 rain = coastRain(dir, u, noise);
  return c * (1.0 - rain.a) + rain.rgb;
}

/// How much of the sun (u.skySun) reaches the sea at `world` past the clouds (0 … 1): the cloud
/// along the sun's ray through the layer.
static float coastSunlight(float3 world, constant FrameUniforms &u, texture2d<float> noise) {
  if (u.cloudCover <= 0.0) return 1.0;
  if (u.sunDir.y <= 0.005) return 0.0;
  CoastLayer c = coastLayer(u);
  float2 rel = world.xz - u.camPos.xz;
  float t0 = (c.base - world.y) / u.sunDir.y, t1 = (c.top - world.y) / u.sunDir.y;
  t1 = min(t1, t0 + 8000.0);
  float dt = (t1 - t0) / 5.0, od = 0.0;
  for (int k = 0; k < 5; k++) {
    float t = t0 + (float(k) + 0.5) * dt;
    od += coastDensity(rel + u.sunDir.xz * t, world.y + u.sunDir.y * t, c, noise, 2.0, 0).x * dt;
  }
  return exp(-od * 0.02);
}

// ---- the backdrop: the sky where the scene drew nothing ----

struct CoastSkyOut {
  float4 position [[position]];
  float2 ndc;
};

vertex CoastSkyOut coast_sky_vs(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
  CoastSkyOut o;
  o.position = float4(p, 1.0, 1.0);
  o.ndc = p;
  return o;
}

fragment float4 coast_sky_fs(CoastSkyOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                             texture2d<float> noise [[texture(kTextureClouds)]]) {
  float4 far = u.invViewProj * float4(in.ndc, 1.0, 1.0);
  float3 dir = normalize(far.xyz / far.w - u.camPos);
  return float4(coastSky(dir, u, noise, 24, 0.0, coastIGN(in.position.xy)), 1.0);
}
