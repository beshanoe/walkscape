// Shared shader code: noise, sky gradient (reflections), fog, the key light's shadows, surface
// shading, and the post
// passes (bloom, light shafts, depth-aware blur mix, tone mapping, grade, grain, and the
// conversion to BT.709 video-range '420v'). The host compiles SceneShared.h + this file + a
// scene's files as one Metal source (newLibraryWithSource:), see SceneRenderer.m.

constexpr sampler kLinearClamp(coord::normalized, filter::linear, address::clamp_to_edge);
constexpr sampler kShadowSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
constexpr sampler kPointClamp(coord::normalized, filter::nearest, address::clamp_to_edge);

// ---- noise ----

static float hash21(float2 p) {
  p = fract(p * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
  float2 i = floor(p), f = fract(p);
  float2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

/// Fractal value noise, 0…1.
static float fbm(float2 p, int octaves) {
  float sum = 0, amp = 0.5, norm = 0;
  for (int i = 0; i < octaves; i++) {
    sum += amp * valueNoise(p);
    norm += amp;
    p = float2(p.x * 1.6 - p.y * 1.2, p.x * 1.2 + p.y * 1.6) + 17.0;  // rotate, scale ×2
    amp *= 0.5;
  }
  return sum / norm;
}

static float hashU(uint3 v) {
  uint h = v.x * 1597334677u ^ v.y * 3812015801u ^ v.z * 2798796415u;
  h ^= h >> 16;
  h *= 0x7feb352du;
  h ^= h >> 15;
  h *= 0x846ca68bu;
  h ^= h >> 16;
  return float(h) * (1.0 / 4294967296.0);
}

// ---- shapes and relief ----

/// The distance from `p` to the segment a–b; `t` gets where along it (0 at a … 1 at b).
static float segDist(float2 p, float2 a, float2 b, thread float &t) {
  float2 pa = p - a, ba = b - a;
  t = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
  return length(pa - ba * t);
}

/// `n` tilted by the slope of `height` across the screen (bump mapping without tangents).
static float3 bump(float3 n, float3 world, float height) {
  float3 dpdx = dfdx(world), dpdy = dfdy(world);
  float hx = dfdx(height), hy = dfdy(height);
  float3 r1 = cross(dpdy, n), r2 = cross(n, dpdx);
  float det = dot(dpdx, r1);
  if (abs(det) < 1e-8) return n;
  return normalize(n - (r1 * hx + r2 * hy) / det);
}

// ---- sky and fog ----

/// The sky's gradient and the sun's glow, no clouds (cheap; for reflections).
static float3 skyGradient(float3 dir, constant FrameUniforms &u) {
  float h = saturate(dir.y);
  float3 c = mix(u.skyHorizon, u.skyZenith, sqrt(h));
  float cosT = dot(dir, u.sunDir);
  float glow = 0.5 * pow(saturate(cosT), 6.0) + 1.5 * pow(saturate(cosT), 64.0);
  return c + u.sunColor * glow * 0.12 * u.sunDisk * (1.0 - 0.7 * u.cloudCover);
}

/// Optical depth of exponential height fog along `ray` from `from` (heights absolute).
static float fogDepth(float3 from, float3 ray, constant FrameUniforms &u) {
  float k = max(u.fogFalloff, 1e-4);
  float dy = ray.y;
  float a = exp(-k * max(from.y, -50.0));
  float integral = abs(dy) > 1e-3 ? a * (1.0 - exp(-k * dy)) / (k * dy) : a;
  return u.fogDensity * length(ray) * integral;
}

/// The colour fog takes toward `dir`: brighter toward the sun.
static float3 fogColorToward(float3 dir, constant FrameUniforms &u) {
  return u.fogColor + u.sunColor * u.inscatter * 0.25 * pow(saturate(dot(dir, u.sunDir)), 8.0);
}

static float3 applyFog(float3 color, float3 world, constant FrameUniforms &u) {
  float3 ray = world - u.camPos;
  float fog = 1.0 - exp(-fogDepth(u.camPos, ray, u));
  return mix(color, fogColorToward(normalize(ray), u), fog);
}

// ---- shadows ----

/// How much sun reaches `world` (0…1): the cascaded shadow map, faded out at its far end.
static float shadowAt(float3 world, float3 n, constant FrameUniforms &u, depth2d_array<float> map) {
  if (u.shadowStrength <= 0) return 1.0;
  float d = dot(world - u.camPos, u.camForward);
  if (d > u.shadowSplits.y) return 1.0;
  int c = d < u.shadowSplits.x ? 0 : 1;
  float texel = c == 0 ? u.shadowSplits.z : u.shadowSplits.w;
  float3 p = world + n * texel * 1.5 + u.sunDir * texel;  // normal and light offsets against acne
  float4 lp = u.shadowViewProj[c] * float4(p, 1.0);
  float2 uv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
  if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
  float2 o = 0.75 / float2(map.get_width(), map.get_height());
  float s = 0.25 * (map.sample_compare(kShadowSampler, uv + float2(-o.x, -o.y), c, lp.z) +
                    map.sample_compare(kShadowSampler, uv + float2(o.x, -o.y), c, lp.z) +
                    map.sample_compare(kShadowSampler, uv + float2(-o.x, o.y), c, lp.z) +
                    map.sample_compare(kShadowSampler, uv + float2(o.x, o.y), c, lp.z));
  float fade = smoothstep(u.shadowSplits.y * 0.75, u.shadowSplits.y, d);
  return mix(mix(1.0, s, u.shadowStrength), 1.0, fade);
}

/// Like shadowAt, with penumbrae that widen with the distance between receiver and caster
/// (percentage-closer soft shadows): a blocker search, then a filter of that width. The width is
/// u.shadowSoftness (the sun's angular size, radians) × that distance.
static float shadowSoftAt(float3 world, float3 n, constant FrameUniforms &u, depth2d_array<float> map) {
  if (u.shadowStrength <= 0) return 1.0;
  float d = dot(world - u.camPos, u.camForward);
  if (d > u.shadowSplits.y) return 1.0;
  int c = d < u.shadowSplits.x ? 0 : 1;
  if (c == 1) return shadowAt(world, n, u, map);  // far away the plain filter does
  float texel = u.shadowSplits.z;
  float3 p = world + n * texel * 1.5 + u.sunDir * texel;
  float4 lp = u.shadowViewProj[c] * float4(p, 1.0);
  float2 uv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
  if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
  float size = map.get_width();
  float depthRange = texel * size + 260.0;  // CascadeMatrix: 2r + 260 m, texel = 2r / size
  const float2 disk[12] = {float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
                           float2(0.962, -0.195), float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893),
                           float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933), float2(-0.792, -0.598)};
  float rot = hashU(uint3(uint2(world.xz * 731.0 + world.y * 97.0), 3)) * 6.2832;
  float2x2 R = float2x2(float2(cos(rot), sin(rot)), float2(-sin(rot), cos(rot)));
  // Blockers within the widest penumbra this cascade allows (≈ 30 m of caster above).
  float searchTexels = min(30.0 * u.shadowSoftness / texel, 24.0);
  float blockers = 0, count = 0;
  for (int i = 0; i < 8; i++) {
    float2 o = R * disk[i] * searchTexels / size;
    float z = map.sample(kPointClamp, uv + o, c);
    if (z < lp.z) {
      blockers += z;
      count += 1;
    }
  }
  float fade = smoothstep(u.shadowSplits.y * 0.75, u.shadowSplits.y, d);
  if (count == 0) return 1.0;
  float gap = (lp.z - blockers / count) * depthRange;  // metres from the caster
  float radius = clamp(gap * u.shadowSoftness / texel, 0.75, searchTexels);
  float lit = 0;
  for (int i = 0; i < 12; i++) {
    float2 o = R * disk[i] * radius / size;
    lit += map.sample_compare(kShadowSampler, uv + o, c, lp.z);
  }
  return mix(mix(1.0, lit / 12.0, u.shadowStrength), 1.0, fade);
}

// ---- surfaces ----

struct Surface {
  float3 albedo;
  float3 normal;        // unit, world
  float occlusion;      // ambient occlusion
  float translucency;   // sunlight through leaves
  float specular;       // reflectance facing the surface (wet road, glass); 0 = none
  float roughness;      // 0 mirror … 1 matte
  float3 emission;      // lamps, lit windows
};

static Surface makeSurface(float3 albedo, float3 normal) {
  Surface s;
  s.albedo = albedo;
  s.normal = normal;
  s.occlusion = 1.0;
  s.translucency = 0.0;
  s.specular = 0.0;
  s.roughness = 1.0;
  s.emission = 0.0;
  return s;
}

/// Lit colour of a surface (before fog): hemisphere ambient, sun (with `shadow`), light through
/// leaves, sky reflection and a sun highlight on shiny surfaces, emission.
static float3 lightSurface(constant FrameUniforms &u, float3 world, Surface s, float shadow) {
  float3 v = normalize(world - u.camPos);  // camera → point
  float3 n = s.normal;
  float ndl = dot(n, u.sunDir);
  float3 ambient = mix(u.groundAmbient, u.skyAmbient, n.y * 0.5 + 0.5) * s.occlusion;
  float3 direct = u.sunColor * saturate(ndl) * shadow;
  float3 col = s.albedo * (ambient + direct);
  if (s.translucency > 0) {
    float back = pow(saturate(dot(v, u.sunDir)), 3.0);
    col += s.albedo * float3(1.2, 1.35, 0.7) * u.sunColor * shadow * s.translucency * (0.3 * saturate(-ndl) + 0.7 * back);
  }
  if (s.specular > 0) {
    float3 r = reflect(v, n);
    float facing = saturate(dot(-v, n));
    float fresnel = s.specular + (1.0 - s.specular) * pow(1.0 - facing, 5.0);
    float gloss = 1.0 - s.roughness;
    col = mix(col, skyGradient(r, u) * s.occlusion, fresnel * gloss);
    float shine = mix(8.0, 400.0, gloss * gloss);
    col += u.sunColor * shadow * fresnel * pow(saturate(dot(r, u.sunDir)), shine) * gloss * 4.0;
  }
  return col + s.emission;
}

/// Lit and fogged colour of a surface.
static float3 shadeSurface(constant FrameUniforms &u, float3 world, Surface s, float shadow) {
  return applyFog(lightSurface(u, world, s, shadow), world, u);
}

/// lightSurface for scenes that know their surroundings: `ambient` is the light arriving from
/// around (the hemisphere terms' units: what a white surface reflects) and `env` what a mirror
/// would show along the reflected view ray. `ambientPart` gets the part of the result that ambient
/// occlusion should darken.
static float3 lightSurfaceIn(constant FrameUniforms &u, float3 world, Surface s, float shadow, float3 ambient, float3 env,
                             thread float3 &ambientPart) {
  float3 v = normalize(world - u.camPos);
  float3 n = s.normal;
  float ndl = dot(n, u.sunDir);
  float3 amb = ambient * s.occlusion;
  float3 col = s.albedo * (amb + u.sunColor * saturate(ndl) * shadow);
  ambientPart = s.albedo * amb;
  if (s.translucency > 0) {
    float back = pow(saturate(dot(v, u.sunDir)), 3.0);
    col += s.albedo * float3(1.2, 1.35, 0.7) * u.sunColor * shadow * s.translucency * (0.3 * saturate(-ndl) + 0.7 * back);
  }
  if (s.specular > 0) {
    float3 r = reflect(v, n);
    float facing = saturate(dot(-v, n));
    float fresnel = s.specular + (1.0 - s.specular) * pow(1.0 - facing, 5.0);
    float gloss = 1.0 - s.roughness;
    float k = fresnel * gloss;
    col = mix(col, env * s.occlusion, k);
    ambientPart = mix(ambientPart, env * s.occlusion * 0.5, k);  // recesses hide part of the reflection too
    float shine = mix(8.0, 400.0, gloss * gloss);
    col += u.sunColor * shadow * fresnel * pow(saturate(dot(r, u.sunDir)), shine) * gloss * 4.0;
  }
  return col + s.emission;
}

// ---- the main pass's outputs ----

/// A fragment's colour and the share of it that is ambient light (Scene.h: kSceneAmbientFormat),
/// which the host's ambient occlusion darkens.
struct SceneColor {
  float4 color [[color(0)]];
  float ambient [[color(1)]];
};

/// Fogs `lit` and works out the ambient share of the result.
static SceneColor sceneColor(float3 lit, float3 ambientPart, float3 world, float alpha, constant FrameUniforms &u) {
  float3 ray = world - u.camPos;
  float fog = 1.0 - exp(-fogDepth(u.camPos, ray, u));
  float3 c = mix(lit, fogColorToward(normalize(ray), u), fog);
  const float3 lum = float3(0.2126, 0.7152, 0.0722);
  SceneColor o;
  o.color = float4(c, alpha);
  o.ambient = saturate(dot(ambientPart, lum) * (1.0 - fog) / max(dot(c, lum), 1e-5));
  return o;
}

/// A flat-shaded normal from screen derivatives, facing the camera's side (foliage is two-sided).
static float3 derivativeNormal(float3 world, float3 camPos) {
  float3 n = normalize(cross(dfdx(world), dfdy(world)));
  return dot(n, camPos - world) < 0 ? -n : n;
}

// ---- post ----

/// Camera-relative position of the surface at `uv` (0…1, y down) with depth `d`.
static float3 viewPosition(float2 uv, float d, constant FrameUniforms &u) {
  float4 w = u.invViewProj * float4(uv.x * 2 - 1, 1 - uv.y * 2, d, 1);
  return w.xyz / w.w - u.camPos;
}

/// Ambient occlusion at half size (x: 1 open … 0 occluded, y: view depth for the blur and the
/// upsampling): samples on a disk around each pixel, occluded by what rises above its tangent
/// plane within u.aoRadius metres.
kernel void ssao(depth2d<float, access::sample> depth [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                 constant FrameUniforms &u [[buffer(kBufferFrame)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 full = float2(depth.get_width(), depth.get_height());
  float2 uv = (float2(gid) * 2.0 + 1.0) / full;
  float d = depth.sample(kPointClamp, uv);
  if (d >= 1.0) {
    dst.write(float4(1.0, 1e5, 0, 0), gid);
    return;
  }
  float3 P = viewPosition(uv, d, u);
  float dist = dot(P, u.camForward);
  float2 tx = 1.0 / full;
  float3 px0 = viewPosition(uv - float2(tx.x, 0), depth.sample(kPointClamp, uv - float2(tx.x, 0)), u);
  float3 px1 = viewPosition(uv + float2(tx.x, 0), depth.sample(kPointClamp, uv + float2(tx.x, 0)), u);
  float3 py0 = viewPosition(uv - float2(0, tx.y), depth.sample(kPointClamp, uv - float2(0, tx.y)), u);
  float3 py1 = viewPosition(uv + float2(0, tx.y), depth.sample(kPointClamp, uv + float2(0, tx.y)), u);
  float3 dx = length_squared(px1 - P) < length_squared(P - px0) ? px1 - P : P - px0;
  float3 dy = length_squared(py1 - P) < length_squared(P - py0) ? py1 - P : P - py0;
  float3 N = normalize(cross(dx, dy));
  if (dot(N, P) > 0) N = -N;
  float radiusPx = min(u.aoRadius * u.projScale / max(dist, 0.1), 90.0);
  if (radiusPx < 1.5) {
    dst.write(float4(1.0, dist, 0, 0), gid);
    return;
  }
  // Interleaved gradient noise: a different rotation per pixel, the same every frame.
  float rot = fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715)))) * 6.2832;
  float r2 = u.aoRadius * u.aoRadius;
  float occ = 0;
  const int kSamples = 12;
  for (int i = 0; i < kSamples; i++) {
    float t = (float(i) + 0.5) / kSamples;
    float a = float(i) * 2.39996 + rot;
    float2 suv = uv + float2(cos(a), sin(a)) * (radiusPx * t) * tx;
    float3 Q = viewPosition(suv, depth.sample(kPointClamp, suv), u);
    float3 v = Q - P;
    float vv = dot(v, v);
    occ += max(dot(v, N) * rsqrt(vv + 1e-4) - 0.08, 0.0) * saturate(1.0 - vv / r2);
  }
  float ao = saturate(1.0 - 1.8 * occ / kSamples);
  dst.write(float4(ao, dist, 0, 0), gid);
}

/// A 5 × 5 blur of the occlusion that keeps to surfaces at the same depth.
kernel void ssao_blur(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 c = src.read(gid).xy;
  int2 size = int2(src.get_width(), src.get_height());
  float sum = 0, wsum = 0;
  for (int j = -2; j <= 2; j++) {
    for (int i = -2; i <= 2; i++) {
      int2 q = clamp(int2(gid) + int2(i, j), int2(0), size - 1);
      float2 s = src.read(uint2(q)).xy;
      float w = exp(-abs(s.y - c.y) / (0.03 * c.y + 0.02)) * (1.0 - 0.1 * float(abs(i) + abs(j)));
      sum += s.x * w;
      wsum += w;
    }
  }
  dst.write(float4(sum / max(wsum, 1e-4), c.y, 0, 0), gid);
}

/// Darkens the ambient share of each pixel by the (half-size) occlusion, in place.
kernel void apply_ao(texture2d<float, access::read_write> scene [[texture(0)]], texture2d<float, access::read> ambient [[texture(1)]],
                     depth2d<float, access::read> depth [[texture(2)]], texture2d<float, access::read> ao [[texture(3)]],
                     constant FrameUniforms &u [[buffer(kBufferFrame)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= scene.get_width() || gid.y >= scene.get_height()) return;
  float share = ambient.read(gid).r;
  if (share <= 0.001) return;
  float2 uv = (float2(gid) + 0.5) / float2(scene.get_width(), scene.get_height());
  float d = depth.read(gid);
  float dist = d >= 1.0 ? 1e5 : dot(viewPosition(uv, d, u), u.camForward);
  // The nearest half-size texels, weighted by how close their depth is to this pixel's.
  int2 halfSize = int2(ao.get_width(), ao.get_height());
  float2 hp = (float2(gid) + 0.5) * 0.5 - 0.5;
  int2 base = int2(floor(hp));
  float2 f = hp - float2(base);
  float sum = 0, wsum = 0;
  for (int j = 0; j <= 1; j++) {
    for (int i = 0; i <= 1; i++) {
      float2 s = ao.read(uint2(clamp(base + int2(i, j), int2(0), halfSize - 1))).xy;
      float w = (i ? f.x : 1.0 - f.x) * (j ? f.y : 1.0 - f.y) * exp(-abs(s.y - dist) / (0.02 * dist + 0.01)) + 1e-5;
      sum += s.x * w;
      wsum += w;
    }
  }
  float occlusion = sum / wsum;
  float4 c = scene.read(gid);
  scene.write(float4(c.rgb * (1.0 - (1.0 - occlusion) * share * u.aoStrength), c.a), gid);
}

/// Motion blur from the camera's movement: each pixel's surface, seen from last frame's camera,
/// gives its motion on screen; average along it for the shutter time.
kernel void motion_blur(texture2d<float, access::sample> src [[texture(0)]], depth2d<float, access::read> depth [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 size = float2(dst.get_width(), dst.get_height());
  float2 uv = (float2(gid) + 0.5) / size;
  float d = depth.read(gid);
  float4 c = src.sample(kLinearClamp, uv);
  if (d >= 1.0) {
    dst.write(c, gid);
    return;
  }
  float3 world = viewPosition(uv, d, u) + u.camPos;
  float4 prev = u.prevViewProj * float4(world, 1.0);
  float2 prevUV = float2(prev.x / prev.w * 0.5 + 0.5, 0.5 - prev.y / prev.w * 0.5);
  float2 motion = (uv - prevUV) * u.motionBlur;
  float len = length(motion * size);
  if (prev.w <= 0 || len < 0.5) {
    dst.write(c, gid);
    return;
  }
  motion *= min(len, 24.0) / len;
  float3 sum = 0;
  const int kTaps = 8;
  float jitter = fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
  for (int i = 0; i < kTaps; i++) sum += src.sample(kLinearClamp, uv + motion * ((float(i) + jitter) / kTaps - 0.5)).rgb;
  dst.write(float4(sum / kTaps, c.a), gid);
}

/// Half-size bright parts of the picture, for bloom.
kernel void bloom_prefilter(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
  float3 c = src.sample(kLinearClamp, uv).rgb;
  float bright = max(c.r, max(c.g, c.b));
  dst.write(float4(c * smoothstep(0.9, 2.2, bright), 1.0), gid);
}

/// Light shafts (half size): march from each pixel toward the sun through the sky mask.
kernel void light_shafts(depth2d<float, access::sample> depth [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                         constant FrameUniforms &u [[buffer(kBufferFrame)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 size = float2(dst.get_width(), dst.get_height());
  float2 uv = (float2(gid) + 0.5) / size;
  float aspect = size.x / size.y;
  const int steps = 36;
  float2 delta = (u.sunScreen - uv) * (0.85 / steps);
  float2 p = uv + delta * hashU(uint3(gid, 7));  // jitter against banding
  float acc = 0, weight = 1;
  for (int i = 0; i < steps; i++) {
    float sky = depth.sample(kLinearClamp, p) >= 0.99999 ? 1.0 : 0.0;
    float2 dv = (p - u.sunScreen) * float2(aspect, 1);
    acc += sky * exp(-dot(dv, dv) * 6.0) * weight;
    weight *= 0.965;
    p += delta;
  }
  dst.write(float4(acc / steps * u.sunOnScreen, 0, 0, 0), gid);
}

/// Khronos PBR Neutral tone mapping: keeps colours up to ~0.76, rolls off highlights. Its toe
/// (the black offset) is taken from each channel in proportion to it, so dark colours keep their
/// hue instead of saturating (a shaded street went navy).
static float3 toneMap(float3 c) {
  const float start = 0.76, desat = 0.15;
  float x = min(c.r, min(c.g, c.b)), top = max(c.r, max(c.g, c.b));
  float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
  c -= offset * (top > 1e-5 ? c / top : float3(1.0));
  float peak = max(c.r, max(c.g, c.b));
  if (peak < start) return c;
  const float d = 1.0 - start;
  float newPeak = 1.0 - d * d / (peak + d - start);
  c *= newPeak / peak;
  float g = 1.0 - 1.0 / (desat * (peak - newPeak) + 1.0);
  return mix(c, float3(newPeak), g);
}

/// Linear scene → display RGB (0…1): depth-aware blur mix, bloom, shafts, exposure, tone map,
/// grade, gamma, vignette.
static float3 composePixel(uint2 p, float2 size, texture2d<float, access::sample> scene, texture2d<float, access::sample> mid,
                           texture2d<float, access::sample> full, depth2d<float, access::read> depth,
                           texture2d<float, access::sample> bloom, texture2d<float, access::sample> shafts,
                           constant FrameUniforms &u, bool blurred) {
  float2 uv = (float2(p) + 0.5) / size;
  float3 c;
  uint2 at = p;
  if (u.lens > 0) {
    // A webcam's lens: a little barrel distortion (scaled so the corners stay in the picture) and
    // lateral colour fringes, red outward and blue inward.
    float aspect = size.x / size.y, k = 0.035 * u.lens;
    float2 cc = (uv - 0.5) * float2(aspect, 1);
    float s = (1.0 + k * dot(cc, cc)) / (1.0 + k * (aspect * aspect + 1.0) * 0.25);
    float2 d = (uv - 0.5) * s, fringe = d * 0.0016 * u.lens;
    uv = 0.5 + d;
    at = uint2(clamp(uv * size, float2(0), size - 1.0));
    c = float3(scene.sample(kLinearClamp, uv + fringe).r, scene.sample(kLinearClamp, uv).g, scene.sample(kLinearClamp, uv - fringe).b);
  } else {
    c = scene.read(p).rgb;
  }
  if (blurred) {
    // A lens focused on you: the blur grows with distance (circle of confusion ∝ 1 − focus/d).
    float d = depth.read(at);
    float4 w = u.invViewProj * float4(uv.x * 2 - 1, 1 - uv.y * 2, d, 1);
    float dist = d >= 1.0 ? 1e6 : length(w.xyz / w.w - u.camPos);
    float coc = saturate(1.0 - u.focusDistance / dist);
    float3 m = u.lens > 0 ? mid.sample(kLinearClamp, uv).rgb : mid.read(p).rgb, f = u.lens > 0 ? full.sample(kLinearClamp, uv).rgb : full.read(p).rgb;
    c = coc < 0.5 ? mix(c, m, coc * 2.0) : mix(m, f, coc * 2.0 - 1.0);
  }
  c += bloom.sample(kLinearClamp, uv).rgb * u.bloom;
  c += u.sunColor * shafts.sample(kLinearClamp, uv).r * u.shafts;
  c = toneMap(max(c * u.whiteBalance * u.exposure, 0.0));
  float l = dot(c, float3(0.2126, 0.7152, 0.0722));
  c = max(mix(float3(l), c, u.saturation), 0.0);
  c = pow(saturate(c), 1.0 / 2.2);
  c = saturate((c - 0.45) * u.contrast + 0.45);
  // The webcam's look: its colour cast, its black and white levels.
  c = u.matchLift + c * u.matchTint * (u.matchGain - u.matchLift);
  float2 r = (uv - 0.5) * float2(size.x / size.y, 1);
  return saturate(c) * (1.0 - u.vignette * dot(r, r));
}

kernel void compose_yuv420(texture2d<float, access::sample> scene [[texture(0)]], texture2d<float, access::sample> mid [[texture(1)]],
                           texture2d<float, access::sample> full [[texture(2)]], depth2d<float, access::read> depth [[texture(3)]],
                           texture2d<float, access::sample> bloom [[texture(4)]], texture2d<float, access::sample> shafts [[texture(5)]],
                           texture2d<float, access::write> lumaTex [[texture(6)]], texture2d<float, access::write> chromaTex [[texture(7)]],
                           constant FrameUniforms &u [[buffer(kBufferFrame)]], constant uint &blurred [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= chromaTex.get_width() || gid.y >= chromaTex.get_height()) return;
  float2 size = float2(lumaTex.get_width(), lumaTex.get_height());
  float3 sum = 0;
  uint frame = uint(u.frameIndex);
  for (uint i = 0; i < 4; i++) {
    uint2 p = gid * 2 + uint2(i & 1, i >> 1);
    float3 rgb = composePixel(p, size, scene, mid, full, depth, bloom, shafts, u, blurred != 0);
    // Sensor-like grain on luma: two uniforms ≈ a Gaussian, std 1 → u.grain.
    float noise = (hashU(uint3(p, frame)) + hashU(uint3(p, frame + 7919u)) - 1.0) * 2.449 * u.grain;
    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    lumaTex.write(float4(16.0 / 255.0 + saturate(y + noise) * 219.0 / 255.0), p);
    sum += rgb;
  }
  float3 rgb = sum * 0.25;
  float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
  float cb = (rgb.b - y) / 1.8556, cr = (rgb.r - y) / 1.5748;
  chromaTex.write(float4(128.0 / 255.0 + cb * 224.0 / 255.0, 128.0 / 255.0 + cr * 224.0 / 255.0, 0, 0), gid);
}
