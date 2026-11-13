// The plant pipeline (Plants.h): the foliage atlas (baked at launch) and instanced plants and
// props, for every scene that lists Plants.h and Plants.metal in its shader sources. A scene can
// draw with plant_vs / plant_fs as they are, or write its own fragment function around
// plantSurface (Paris, the seaside). Compiled after SceneShared.h, Common.metal and Plants.h.

constexpr sampler kAtlasSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));

// ---- foliage atlas ----
// Each cell: R brightness, G a random value per leaf (colour variation), B twig/stem (drawn
// brown), A coverage. Texture v = 0 is the card's base (where it attaches).

static float h1(float n) {
  return fract(sin(n * 127.1 + 0.37) * 43758.5453);
}

static float2 rot2(float2 v, float a) {
  float c = cos(a), s = sin(a);
  return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

/// Coverage of one leaf from `base` pointing at `angle` (0 = +v); `shade` gets its brightness.
static float leafShape(float2 p, float2 base, float angle, float len, float widthRatio, float px, thread float &shade) {
  float2 q = rot2(p - base, -angle);
  float t = q.y / len;
  if (t < 0.0 || t > 1.0) return 0.0;
  float halfW = len * widthRatio * 0.5 * pow(sin(3.14159 * t), 0.75) * (1.0 - 0.25 * t);
  float cov = saturate(0.5 - (abs(q.x) - halfW) / px);
  shade = 0.86 + 0.14 * t - 0.2 * saturate(1.0 - abs(q.x) / (px * 1.5));  // midrib
  return cov;
}

/// Leaves on a few twigs fanning out from the base.
static float4 leafCluster(float2 uv, float seed, int leaves, float lenLo, float lenHi, float widthRatio, float spread, float px) {
  float alpha = 0, bright = 0.8, rnd = 0.5, twig = 0;
  const int twigs = 4;
  float2 base = float2(0.5, 0.04);
  float2 ends[twigs];
  for (int i = 0; i < twigs; i++) {
    float a = (i - 1.5) * spread + (h1(seed + i) - 0.5) * 0.25;
    ends[i] = base + float2(sin(a), cos(a)) * (0.5 + 0.18 * h1(seed + i + 9.0));
    float t;
    float d = segDist(uv, base, ends[i], t);
    float c = saturate(0.5 - (d - mix(0.011, 0.003, t)) / px);
    if (c > 0) {
      alpha = max(alpha, c);
      twig = max(twig, c);
      bright = 0.6;
    }
  }
  for (int i = 0; i < leaves; i++) {
    float s = seed * 13.1 + i * 7.31;
    int ti = i % twigs;
    float k = 0.12 + 0.88 * h1(s);
    float2 dir = normalize(ends[ti] - base);
    float2 at = base + (ends[ti] - base) * k;
    float side = (i & 1) ? 1.0 : -1.0;
    float angle = atan2(dir.x, dir.y) + side * (0.45 + 0.55 * h1(s + 1.0));
    float len = mix(lenLo, lenHi, h1(s + 2.0)) * (1.0 - 0.25 * k);
    float shade;
    float c = leafShape(uv, at, angle, len, widthRatio, px, shade);
    if (c > 0.001) {
      alpha = max(alpha, c);
      bright = mix(bright, shade * (0.82 + 0.3 * h1(s + 3.0)), c);
      rnd = mix(rnd, h1(s + 4.0), c);
      twig = mix(twig, 0.0, c);
    }
  }
  return float4(bright, rnd, twig, alpha);
}

/// Coverage of one palmate leaf (plane tree: five pointed lobes) on a stalk from `base` toward
/// `angle`; `shade` gets its brightness (veins lighter).
static float palmateLeaf(float2 p, float2 base, float angle, float size, float px, thread float &shade) {
  float2 q = rot2(p - base, -angle);
  float2 d = q - float2(0, size * 0.5);
  float r = length(d);
  float th = atan2(d.x, d.y);  // 0 = away from the stalk
  if (abs(th) > 2.5) return 0.0;  // the notch where the stalk joins
  float lobes = pow(abs(cos(th * 2.5)), 0.7);
  float edge = size * 0.5 * (0.5 + 0.5 * lobes) * (1.0 - 0.18 * abs(th) / 2.5);
  float cov = saturate(0.5 - (r - edge) / px);
  float vein = 1.0 - smoothstep(0.0, px * 1.6, abs(r * sin(th * 2.5 - round(th * 2.5 / 3.14159) * 3.14159) / 2.5));
  shade = 0.84 + 0.16 * saturate(r / (size * 0.5)) + 0.1 * vein * step(r, edge * 0.85);
  // The stalk.
  float t;
  float stalk = saturate(0.5 - (segDist(p, base, base + rot2(float2(0, size * 0.1), angle), t) - 0.004) / px);
  return max(cov, stalk);
}

/// Plane-tree leaves: fewer, big palmate leaves on a few twigs.
static float4 planeCluster(float2 uv, float px) {
  float alpha = 0, bright = 0.8, rnd = 0.5, twig = 0;
  const int twigs = 3;
  float2 base = float2(0.5, 0.04);
  float2 ends[twigs];
  for (int i = 0; i < twigs; i++) {
    float a = (i - 1.0) * 0.5 + (h1(31.0 + i) - 0.5) * 0.25;
    ends[i] = base + float2(sin(a), cos(a)) * (0.5 + 0.15 * h1(40.0 + i));
    float t;
    float c = saturate(0.5 - (segDist(uv, base, ends[i], t) - mix(0.012, 0.004, t)) / px);
    if (c > 0) {
      alpha = max(alpha, c);
      twig = max(twig, c);
      bright = 0.6;
    }
  }
  for (int i = 0; i < 14; i++) {
    float s = 71.3 + i * 7.31;
    int ti = i % twigs;
    float k = 0.2 + 0.8 * h1(s);
    float2 dir = normalize(ends[ti] - base);
    float2 at = base + (ends[ti] - base) * k;
    float side = (i & 1) ? 1.0 : -1.0;
    float angle = atan2(dir.x, dir.y) + side * (0.35 + 0.6 * h1(s + 1.0));
    float shade;
    float c = palmateLeaf(uv, at, angle, mix(0.2, 0.3, h1(s + 2.0)) * (1.0 - 0.2 * k), px, shade);
    if (c > 0.001) {
      alpha = max(alpha, c);
      bright = mix(bright, shade * (0.82 + 0.3 * h1(s + 3.0)), c);
      rnd = mix(rnd, h1(s + 4.0), c);
      twig = mix(twig, 0.0, c);
    }
  }
  return float4(bright, rnd, twig, alpha);
}

/// A twig with needles along it (spruce): a band of diagonal strokes either side.
static void needleTwig(float2 uv, float2 a, float2 b, float width, float seed, float px, thread float4 &acc) {
  float t;
  float d = segDist(uv, a, b, t);
  float w = width * (1.0 - 0.55 * t);
  if (d > w + px) return;
  float len = length(b - a);
  float stroke = fract((t * len + d * 0.75) * 130.0 + seed);
  float needle = smoothstep(0.75, 0.45, stroke) * (1.0 - pow(saturate(d / w), 3.0) * 0.5);
  float c = needle * saturate((w - d) / px + 0.5);
  float core = saturate(0.5 - (d - 0.004) / px);
  float cov = max(c, core);
  if (cov <= 0) return;
  acc.a = max(acc.a, cov);
  acc.r = mix(acc.r, core > c ? 0.55 : 0.7 + 0.3 * h1(floor((t * len + d * 0.75) * 130.0 + seed)), cov);
  acc.b = mix(acc.b, core > c ? 1.0 : 0.0, cov);
  acc.g = mix(acc.g, h1(seed), cov);
}

static float4 spruceSpray(float2 uv, float px) {
  float4 acc = float4(0.8, 0.5, 0, 0);
  float2 a = float2(0.5, 0.02), b = float2(0.53, 0.97);
  needleTwig(uv, a, b, 0.07, 0.0, px, acc);
  for (int k = 0; k < 9; k++) {
    float t = 0.08 + k * 0.1;
    float2 p0 = mix(a, b, t);
    for (int side = -1; side <= 1; side += 2) {
      float2 dir = rot2(float2(0, 1), side * (0.9 + 0.15 * h1(k * 3.0 + side)));
      float len = 0.34 * (1.0 - t) + 0.07;
      needleTwig(uv, p0, p0 + dir * len, 0.05 * (1.0 - 0.4 * t), k * 7.0 + side * 3.0, px, acc);
    }
  }
  return acc;
}

static float4 pineTuft(float2 uv, float px) {
  float4 acc = float4(0.8, 0.5, 0, 0);
  float2 base = float2(0.5, 0.06);
  for (int i = 0; i < 80; i++) {
    float s = i * 3.17;
    float a = (h1(s) - 0.5) * 2.6;
    float len = (0.32 + 0.3 * h1(s + 1.0)) * (1.0 - 0.3 * abs(a) / 1.3);
    float2 from = base + float2((h1(s + 2.0) - 0.5) * 0.06, h1(s + 5.0) * 0.08);
    float2 to = from + float2(sin(a), cos(a)) * len;
    float t;
    float d = segDist(uv, from, to, t);
    float c = saturate(0.5 - (d - 0.0045 * (1.0 - 0.5 * t)) / px);
    if (c > 0) {
      acc.a = max(acc.a, c);
      acc.r = mix(acc.r, 0.7 + 0.3 * h1(s + 3.0) + 0.1 * t, c);
      acc.g = mix(acc.g, h1(s + 4.0), c);
    }
  }
  float d0 = length(uv - base);
  float core = saturate(0.5 - (d0 - 0.025) / px);
  acc.a = max(acc.a, core);
  acc.b = max(acc.b, core);
  return acc;
}

static float4 fernFrond(float2 uv, float px) {
  float4 acc = float4(0.8, 0.5, 0, 0);
  float t;
  float2 a = float2(0.5, 0.02), b = float2(0.54, 0.97);
  float d = segDist(uv, a, b, t);
  float rachis = saturate(0.5 - (d - mix(0.008, 0.002, t)) / px);
  if (rachis > 0) {
    acc = float4(0.6, 0.5, 0.6, rachis);
  }
  for (int k = 0; k < 18; k++) {
    float tk = 0.05 + k * 0.053;
    float2 at = mix(a, b, tk);
    float len = 0.42 * pow(1.0 - tk, 0.7) * (0.35 + 0.65 * smoothstep(0.0, 0.2, tk));
    for (int side = -1; side <= 1; side += 2) {
      float shade;
      float2 q = rot2(uv - at, -(side * (1.2 - 0.35 * tk)));
      float tt = q.y / len;
      if (tt < 0 || tt > 1) continue;
      // Pinnae with lobed edges.
      float halfW = len * 0.16 * pow(sin(3.14159 * tt), 0.6) * (0.75 + 0.25 * abs(sin(tt * 38.0)));
      float c = saturate(0.5 - (abs(q.x) - halfW) / px);
      shade = 0.85 + 0.15 * tt;
      if (c > 0) {
        acc.a = max(acc.a, c);
        acc.r = mix(acc.r, shade * (0.9 + 0.15 * h1(k * 2.0 + side)), c);
        acc.g = mix(acc.g, h1(k + side * 0.5), c);
        acc.b = mix(acc.b, 0.0, c);
      }
    }
  }
  return acc;
}

static float4 grassTuft(float2 uv, float px) {
  float4 acc = float4(0.8, 0.5, 0, 0);
  for (int i = 0; i < 30; i++) {
    float s = i * 5.13;
    float x0 = 0.25 + 0.5 * h1(s);
    float lean = (h1(s + 1.0) - 0.5) * 0.5;
    float h = 0.5 + 0.47 * h1(s + 2.0);
    float t = uv.y / h;
    if (t < 0 || t > 1) continue;
    float cx = x0 + lean * t * t;
    float w = 0.014 * (1.0 - t) + 0.001;
    float c = saturate(0.5 - (abs(uv.x - cx) - w) / px);
    if (c > 0) {
      acc.a = max(acc.a, c);
      acc.r = mix(acc.r, (0.55 + 0.45 * t) * (0.85 + 0.25 * h1(s + 3.0)), c);
      acc.g = mix(acc.g, h1(s + 4.0), c);
    }
  }
  return acc;
}

kernel void bake_foliage(texture2d<float, access::write> atlas [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= atlas.get_width() || gid.y >= atlas.get_height()) return;
  uint cell = gid.x / kAtlasCell + kAtlasColumns * (gid.y / kAtlasCell);
  float2 uv = (float2(gid % kAtlasCell) + 0.5) / kAtlasCell;
  float px = 1.0 / kAtlasCell;
  float4 c = float4(0.8, 0.5, 0, 0);
  switch (cell) {
    case kCellLeaves: c = leafCluster(uv, 1.0, 46, 0.11, 0.19, 0.5, 0.38, px); break;
    case kCellBirchLeaves: c = leafCluster(uv, 5.0, 46, 0.07, 0.11, 0.62, 0.42, px); break;
    case kCellSpruce: c = spruceSpray(uv, px); break;
    case kCellPine: c = pineTuft(uv, px); break;
    case kCellFern: c = fernFrond(uv, px); break;
    case kCellGrass: c = grassTuft(uv, px); break;
    case kCellPlaneLeaves: c = planeCluster(uv, px); break;
    default: break;
  }
  // Keep away from the cell's edges (mipmaps), and give empty texels neutral colour so the
  // mipmaps don't darken toward the edges of leaves.
  float edge = smoothstep(0.0, 0.02, uv.x) * smoothstep(1.0, 0.98, uv.x) * smoothstep(0.0, 0.01, uv.y) * smoothstep(1.0, 0.98, uv.y);
  c.a *= edge;
  if (c.a <= 0.0) c.rgb = float3(0.8, 0.5, 0.0);
  atlas.write(c, gid);
}

// ---- plants (instanced) ----

struct PlantOut {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float3 color;
  float3 tint;
  float2 uv;
  float material;
  float snow;
  float bright;
};

vertex PlantOut plant_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device MeshVertex *verts [[buffer(kBufferVertices)]],
                         const device PlantInstance *inst [[buffer(kBufferInstances)]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                         constant PlantUniforms &f [[buffer(kBufferScene)]]) {
  MeshVertex v = verts[vid];
  PlantInstance t = inst[iid];
  float3 vp = float3(v.p[0], v.p[1], v.p[2]);
  float height = t.shape.y;
  float3 scale = float3(t.shape.x * height, height, t.shape.x * height);
  float3 local = vp * scale;
  float s = sin(t.posYaw.w), c = cos(t.posYaw.w);
  float3 p = float3(c * local.x - s * local.z, local.y, s * local.x + c * local.z);
  float3 n = float3(v.n[0], v.n[1], v.n[2]) / scale;
  n = normalize(float3(c * n.x - s * n.z, n.y, s * n.x + c * n.z));
  // Wind: tall plants sway from the crown, small ones bend from the base; leaves flutter.
  float phase = t.shape.w;
  float sway = height > 3.0 ? pow(max(vp.y - 0.2, 0.0), 2.0) * height * 0.035 : vp.y * vp.y * height * 0.12;
  sway *= f.wind;
  p.x += sway * (sin(u.time * 0.8 + phase) + 0.4 * sin(u.time * 1.9 + phase * 2.3));
  p.z += sway * 0.6 * sin(u.time * 0.6 + phase * 1.7);
  if (v.material >= kMaterialCard - 0.5) {
    p += n * sin(u.time * 5.0 + dot(vp, float3(37.0, 23.0, 41.0)) + phase) * 0.04 * f.wind * min(height * 0.05, 1.0);
  }
  PlantOut o;
  o.world = p + t.posYaw.xyz;
  o.position = u.viewProj * float4(o.world, 1.0);
  o.normal = n;
  o.color = float3(v.c[0], v.c[1], v.c[2]);
  o.tint = t.tint.rgb;
  o.snow = t.tint.w;
  o.uv = float2(v.uv[0], v.uv[1]);
  o.material = v.material;
  o.bright = t.shape.z;
  return o;
}

/// Atlas coordinates of a card's uv in `cell`.
static float2 atlasUV(float2 uv, int cell) {
  float2 origin = float2(cell % kAtlasColumns, cell / kAtlasColumns);
  return (origin + clamp(uv, 0.002, 0.998)) / float2(kAtlasColumns, kAtlasRows);
}

/// A plant's or prop's surface (albedo, normal, translucency, gloss …) and its coverage (`alpha`).
static Surface plantSurface(PlantOut in, constant FrameUniforms &u, constant PlantUniforms &f, texture2d<float> atlas, thread float &alpha) {
  float3 n = normalize(in.normal);
  float translucency = 0.0, occlusion = 1.0, specular = 0.0, roughness = 1.0;
  alpha = 1.0;
  float3 albedo, emission = 0.0;
  float m = in.material;
  if (m >= kMaterialCard - 0.5) {
    float2 auv = atlasUV(in.uv, int(m - kMaterialCard + 0.5));
    float4 t = atlas.sample(kAtlasSampler, auv);
    // Alpha to coverage, sharpened, and kept from thinning out in the smaller mipmaps.
    float lod = atlas.calculate_unclamped_lod(kAtlasSampler, auv);
    float a = t.a * (1.0 + max(lod, 0.0) * 0.22);
    alpha = saturate((a - 0.5) / max(fwidth(a), 1e-4) + 0.5);
    occlusion = in.color.x;
    albedo = in.tint * t.r * in.bright * mix(float3(0.9, 0.95, 1.06), float3(1.12, 1.05, 0.84), t.g);
    albedo = mix(albedo, float3(0.06, 0.045, 0.03), t.b);  // twigs and stems
    int cell = int(m - kMaterialCard + 0.5);
    translucency = (cell == kCellSpruce || cell == kCellPine ? 0.25 : cell == kCellGrass ? 0.35 : 0.65) * (1.0 - t.b);
    if (in.snow > 0) {  // snow lying on the upper side of conifer branches
      float cover = smoothstep(0.25, 0.75, n.y) * in.snow * smoothstep(0.35, 0.6, valueNoise(in.uv * 7.0 + in.world.xz));
      albedo = mix(albedo, float3(0.82, 0.85, 0.9), cover);
      translucency *= 1.0 - cover;
    }
  } else if (m < 0.5) {
    albedo = in.color * in.bright;
  } else if (m < 1.5) {  // bark: vertical fissures, moss low on one side
    float ridges = valueNoise(float2(in.uv.x * 14.0, in.uv.y * 1.2)) * 0.6 + valueNoise(float2(in.uv.x * 40.0, in.uv.y * 3.0)) * 0.4;
    albedo = in.color * (0.65 + 0.6 * ridges) * in.bright;
    float moss = (1.0 - smoothstep(0.0, 2.5, in.uv.y)) * saturate(n.z * 0.6 + 0.5) * (1.0 - f.snow) * f.moss;
    albedo = mix(albedo, float3(0.06, 0.1, 0.025), moss * 0.7);
  } else if (m > 3.5) {  // props: lamp glass, paint, glass
    if (m < 4.5) {
      albedo = in.color;
      emission = u.lampColor * 9.0 * u.night;
    } else if (m < 5.5) {
      albedo = in.tint;
      specular = 0.05;
      roughness = 0.25;
    } else {
      albedo = float3(0.015, 0.017, 0.02);
      specular = 0.045;
      roughness = 0.03;
    }
  } else if (m < 2.5) {  // birch: white with dark lenticels, darker toward the base
    float marks = step(0.72, valueNoise(float2(in.uv.x * 7.0, in.uv.y * 18.0))) * step(0.4, valueNoise(float2(in.uv.x * 3.0, in.uv.y * 5.0)));
    float base = 1.0 - smoothstep(0.0, 3.0, in.uv.y);
    albedo = mix(in.color, float3(0.03, 0.03, 0.03), max(marks, base * 0.75 * step(0.45, valueNoise(in.uv * float2(9, 6)))));
  } else {  // rock: mottled, mossy on top
    float3 w = in.world + float3(0, 0, u.originZ);
    albedo = in.color * (0.7 + 0.5 * valueNoise(w.xz * 3.0 + w.y * 2.0)) * in.bright;
    float top = smoothstep(0.35, 0.85, n.y) * (0.6 + 0.4 * valueNoise(w.xz * 2.0));
    albedo = mix(albedo, f.snow > 0.5 ? float3(0.82, 0.85, 0.9) : float3(0.07, 0.11, 0.03), top * 0.85 * max(f.moss, f.snow));
  }
  if (f.snow > 0.5 && m < 2.5) {  // snow on top of logs and stumps
    albedo = mix(albedo, float3(0.82, 0.85, 0.9), smoothstep(0.55, 0.85, n.y));
  }
  albedo *= 1.0 - 0.25 * u.wetness * step(m, 3.5);  // wet bark and stone are darker
  Surface s = makeSurface(albedo, n);
  s.occlusion = occlusion;
  s.translucency = translucency;
  s.specular = specular;
  s.roughness = roughness;
  s.emission = emission;
  return s;
}

fragment float4 plant_fs(PlantOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                         constant PlantUniforms &f [[buffer(kBufferScene)]], depth2d_array<float> shadowMap [[texture(kTextureShadow)]],
                         texture2d<float> atlas [[texture(kTextureScene)]]) {
  float alpha;
  Surface s = plantSurface(in, u, f, atlas, alpha);
  float shadow = shadowAt(in.world, normalize(in.normal), u, shadowMap);
  return float4(shadeSurface(u, in.world, s, shadow), alpha);
}

fragment void plant_shadow_fs(PlantOut in [[stage_in]], texture2d<float> atlas [[texture(kTextureScene)]]) {
  if (in.material >= kMaterialCard - 0.5) {
    float a = atlas.sample(kAtlasSampler, atlasUV(in.uv, int(in.material - kMaterialCard + 0.5)), bias(1.0)).a;
    if (a < 0.45) discard_fragment();
  }
}
