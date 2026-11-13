// Corridor: the corridor mesh (walls, floor, ceiling, doors, windows, pictures). Compiled after
// SceneShared.h, Common.metal, Plants.h, Plants.metal (plant shaders for plants and light
// fittings) and CorridorScene.h. Lit by the ceiling fixtures (the nearest few, every
// lightSpacing metres), the environment's bounce light, and the sun through windows.

struct HallOut {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float3 color;
  float2 uv;
  float material;
};

vertex HallOut hall_vs(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(kBufferVertices)]],
                       constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float3 &offset [[buffer(kBufferInstances)]]) {
  MeshVertex v = verts[vid];
  HallOut o;
  o.world = float3(v.p[0], v.p[1], v.p[2]) + offset;
  o.position = u.viewProj * float4(o.world, 1.0);
  o.normal = float3(v.n[0], v.n[1], v.n[2]);
  o.color = float3(v.c[0], v.c[1], v.c[2]);
  o.uv = float2(v.uv[0], v.uv[1]);
  o.material = v.material;
  return o;
}

static float hallRect(float2 p, float2 lo, float2 hi) {
  float2 fw = max(fwidth(p), 1e-4);
  float2 a = smoothstep(lo - fw, lo + fw, p) * (1.0 - smoothstep(hi - fw, hi + fw, p));
  return a.x * a.y;
}

static float hallLines(float x, float period, float halfWidth) {
  float d = abs(fract(x / period + 0.5) - 0.5) * period;
  float fw = max(fwidth(x), 1e-4);
  return 1.0 - smoothstep(halfWidth - fw, halfWidth + fw, d);
}

static float3 rgb8(float r, float g, float b) {
  return pow(float3(r, g, b) / 255.0, 2.2);
}

/// Light from the nearest ceiling fixtures: diffuse, and in `spec` their highlights on a surface
/// with `gloss` (0 matte … 1 polished).
static float3 fixtures(float3 p, float3 n, float gloss, constant FrameUniforms &u, constant CorridorUniforms &c, thread float3 &spec) {
  spec = 0;
  if (u.night <= 0) return 0;
  float3 v = normalize(p - u.camPos);
  float3 r = reflect(v, n);
  float shininess = mix(8.0, 900.0, gloss * gloss);
  float fresnel = 0.04 + 0.96 * pow(1.0 - saturate(dot(-v, n)), 5.0);
  float zAbs = p.z + u.originZ;
  float s = c.lightSpacing;
  float k0 = floor(zAbs / s - 0.5);
  float3 sum = 0;
  for (int j = -1; j <= 2; j++) {
    float3 lp = float3(0, c.lightY, (k0 + j + 0.5) * s - u.originZ);
    float3 d = lp - p;
    float d2 = dot(d, d);
    float3 l = d * rsqrt(d2);
    float3 power = u.lampColor * u.night * 10.0 * (0.3 + 0.7 * saturate(l.y)) / (d2 + 0.25);
    sum += power * saturate(dot(n, l));
    if (gloss > 0) spec += power * pow(saturate(dot(r, l)), shininess) * (shininess + 2.0) / 8.0 * fresnel;
  }
  return sum;
}

/// How dark the corridor's corners are (floor/ceiling against the walls).
static float corners(float3 p, constant CorridorUniforms &c) {
  float toWall = c.halfWidth - abs(p.x), toFloor = p.y, toCeiling = c.height - p.y;
  float ao = 1.0 - 0.28 * exp(-max(toWall, 0.0) / 0.25) * exp(-min(toFloor, toCeiling) / 0.6);
  return ao * (1.0 - 0.18 * exp(-max(toWall, 0.0) / 0.4)) * (1.0 - 0.15 * exp(-min(toFloor, toCeiling) / 0.3));
}

// ---- surfaces ----

static float3 floorAlbedo(float3 p, constant CorridorUniforms &c, thread float &gloss, thread float &relief) {
  float2 w = float2(p.x, p.z);
  int type = int(c.floorType + 0.5);
  float n = valueNoise(w * 7.0);
  relief = 0;
  if (type == kFloorWood) {  // planks along the corridor, staggered
    float lane = floor((w.x + 10.0) / 0.14);
    float along = w.y / (1.2 + 0.9 * hash21(float2(lane, 3.0))) + hash21(float2(lane, 7.0));
    float plank = hash21(float2(lane, floor(along)));
    float seam = max(hallLines(w.x + 10.0, 0.14, 0.004), hallLines(along, 1.0, 0.004 / 1.2));
    float grain = valueNoise(float2(w.x * 40.0, w.y * 1.5)) * 0.5 + valueNoise(float2(w.x * 90.0, w.y * 3.0)) * 0.5;
    gloss = 0.45;
    relief = -seam * 0.004;
    return mix(rgb8(120, 82, 52), rgb8(160, 115, 75), plank) * (0.85 + 0.25 * grain) * (1.0 - 0.6 * seam);
  }
  if (type == kFloorStone) {  // terrazzo in big tiles
    float seam = max(hallLines(w.x + 10.0, 0.8, 0.003), hallLines(w.y, 0.8, 0.003));
    float chips = step(0.72, valueNoise(w * 38.0)) * (0.5 + 0.5 * valueNoise(w * 17.0));
    float3 base = mix(rgb8(196, 190, 178), rgb8(176, 170, 160), valueNoise(w * 0.7));
    gloss = 0.9;
    relief = -seam * 0.002;
    return mix(base, rgb8(110, 100, 92), chips * 0.6) * (1.0 - 0.4 * seam);
  }
  // Carpet: a pattern per style, a border along the walls.
  gloss = 0;
  float3 a, b, border;
  float pattern;
  int style = int(c.style + 0.5);
  float edge = step(c.halfWidth - 0.28, abs(w.x));
  if (style == kStyleOffice) {  // carpet tiles, alternating pile
    float2 tile = floor(w / 0.5);
    float2 f = fract(w / 0.5);
    float pile = fmod(tile.x + tile.y, 2.0) < 0.5 ? valueNoise(float2(f.x * 30.0, f.y * 3.0)) : valueNoise(float2(f.x * 3.0, f.y * 30.0));
    return rgb8(78, 84, 92) * (0.85 + 0.25 * pile) * (0.95 + 0.1 * n);
  }
  if (style == kStyleHotel) {
    a = rgb8(110, 30, 38);
    b = rgb8(182, 140, 72);
    border = rgb8(40, 34, 52);
    float2 q = float2(w.x, w.y) / 0.6;
    float2 cell = fract(q) - 0.5;
    float diamond = abs(cell.x) + abs(cell.y);
    pattern = hallLines(diamond, 0.25, 0.02) + (1.0 - smoothstep(0.08, 0.1, length(cell)));
  } else {  // old building: a runner with a key pattern on wood
    a = rgb8(32, 48, 72);
    b = rgb8(160, 130, 80);
    border = rgb8(110, 30, 30);
    pattern = hallLines(w.x * 2.0 + floor(w.y * 2.0) * 0.5, 0.5, 0.05) * hallLines(w.y, 0.5, 0.2);
  }
  float3 col = mix(a, b, saturate(pattern) * 0.85) * (0.85 + 0.2 * valueNoise(w * 30.0));
  return mix(col, border, edge);
}

static float3 ceilingAlbedo(float3 p, constant FrameUniforms &u, constant CorridorUniforms &c, thread float3 &emission) {
  float zAbs = p.z + u.originZ;
  float s = c.lightSpacing;
  float lz = (floor(zAbs / s) + 0.5) * s;  // the nearest fixture
  int style = int(c.style + 0.5);
  emission = 0;
  if (style == kStyleOffice) {  // suspended tiles, a light panel per fixture
    float grid = max(hallLines(p.x + 10.0, 0.6, 0.008), hallLines(zAbs, 0.6, 0.008));
    float panel = hallRect(float2(p.x, zAbs - lz), float2(-0.3, -0.6), float2(0.3, 0.6));
    emission = u.lampColor * u.night * 2.2 * panel;
    return mix(rgb8(222, 222, 216) * (0.92 + 0.12 * valueNoise(float2(p.x, zAbs) * 40.0)), rgb8(150, 150, 150), grid) * (1.0 - panel);
  }
  if (style == kStyleHotel) {  // smooth, round downlights
    float r = length(float2(p.x, zAbs - lz));
    float light = 1.0 - smoothstep(0.075, 0.085, r);
    float rim = (1.0 - smoothstep(0.1, 0.11, r)) - light;
    emission = u.lampColor * u.night * 6.0 * light;
    return mix(rgb8(232, 228, 220), rgb8(170, 160, 140), rim);
  }
  return rgb8(230, 226, 216) * (0.95 + 0.06 * valueNoise(float2(p.x, zAbs) * 3.0));  // plaster (globes hang from it)
}

static float3 wallAlbedo(HallOut in, constant CorridorUniforms &c, thread float &relief) {
  float3 paint = c.wall.rgb;
  int style = int(c.style + 0.5);
  float y = in.uv.y;
  relief = 0;
  if (style == kStyleHotel && y > 0.94) {  // wallpaper: fine stripes above the rail
    paint *= 1.0 - 0.06 * hallLines(in.uv.x, 0.16, 0.035);
  }
  if (style == kStyleOld && y < 0.94) {  // wainscot: raised panels below the rail
    float2 q = float2(fract(in.uv.x / 0.9) * 0.9, y);
    float panel = hallRect(q, float2(0.08, 0.16), float2(0.82, 0.8));
    float frame = hallRect(q, float2(0.06, 0.14), float2(0.84, 0.82)) - panel;
    paint = mix(paint * 0.92, paint * 1.04, panel);
    relief = frame * 0.01 - panel * 0.004;
  }
  return paint * (0.96 + 0.06 * valueNoise(in.uv * 4.0));
}

static float3 doorAlbedo(HallOut in, constant CorridorUniforms &c, thread float &gloss, thread float &relief) {
  uint seed = uint(in.color.x + 0.5);
  float2 q = in.uv;
  int style = int(c.style + 0.5);
  relief = 0;
  gloss = 0.15;
  if (style == kStyleHotel) {  // walnut veneer, flush
    float grain = valueNoise(float2(q.x * 30.0, q.y * 2.0)) * 0.6 + valueNoise(float2(q.x * 80.0, q.y * 5.0)) * 0.4;
    gloss = 0.3;
    return rgb8(88, 56, 36) * (0.8 + 0.35 * grain);
  }
  if (style == kStyleOffice) {  // light oak, a narrow glass strip
    float glass = hallRect(q, float2(0.72, 0.45), float2(0.86, 0.88));
    float grain = valueNoise(float2(q.x * 40.0, q.y * 3.0));
    return mix(rgb8(186, 150, 106) * (0.88 + 0.2 * grain), rgb8(30, 34, 38), glass);
  }
  // Old building: painted, four raised panels.
  float3 paints[3] = {rgb8(226, 222, 210), rgb8(38, 64, 52), rgb8(70, 40, 36)};
  float3 paint = paints[SceneHash(seed, 2u) % 3u];
  float panels = hallRect(float2(fract(q.x * 2.0), fract(q.y * 2.0)), float2(0.16, 0.12), float2(0.84, 0.88));
  relief = panels * 0.01;
  return paint * (0.92 + 0.1 * panels);
}

/// Abstract paintings: soft fields of three colours.
static float3 painting(HallOut in) {
  uint seed = uint(in.color.x + 0.5);
  float3 palette[6] = {rgb8(200, 80, 55), rgb8(70, 110, 160), rgb8(228, 190, 95), rgb8(90, 140, 100), rgb8(236, 228, 210), rgb8(170, 120, 150)};
  float3 a = palette[SceneHash(seed, 3u) % 6u], b = palette[SceneHash(seed, 4u) % 6u], cc = palette[SceneHash(seed, 5u) % 6u];
  float2 q = in.uv + float2(SceneHashF(seed, 6u), SceneHashF(seed, 7u)) * 10.0;
  float n1 = valueNoise(q * 2.5), n2 = valueNoise(q * 1.3 + 5.0);
  return mix(mix(a, b, smoothstep(0.35, 0.65, n1)), cc, smoothstep(0.55, 0.75, n2));
}

fragment float4 hall_fs(HallOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                        constant CorridorUniforms &c [[buffer(kBufferScene)]], depth2d_array<float> shadowMap [[texture(kTextureShadow)]]) {
  float3 n = normalize(in.normal);
  int material = int(in.material + 0.5);
  if (material == kHallShadowOnly) discard_fragment();
  float gloss = 0, relief = 0;
  float3 albedo, emission = 0;
  if (material == kHallWindow) {  // daylight outside, the frame in front
    float2 q = in.uv;
    float frame = 1.0 - hallRect(q, float2(0.05, 0.05), float2(0.95, 0.95));
    float bars = max(1.0 - smoothstep(0.015, 0.025, abs(q.x - 0.5)), 1.0 - smoothstep(0.012, 0.022, abs(q.y - 0.62)));
    float3 outside = u.skyAmbient * 4.0 * float3(0.88, 0.96, 1.1) * mix(0.8, 1.15, q.y) + u.sunColor * 0.25;
    float3 wood = rgb8(232, 230, 224) * (u.skyAmbient * 1.5 + u.groundAmbient);
    float3 col = mix(outside, wood, saturate(frame + bars));
    return float4(applyFog(col, in.world, u), 1.0);
  }
  if (material == kHallSign) {  // a lit exit sign
    float3 col = float3(0.08, 1.2, 0.35) * (0.6 + 0.4 * u.night) + 0.05;
    return float4(applyFog(col, in.world, u), 1.0);
  }
  if (material == kHallFloor) {
    albedo = floorAlbedo(in.world + float3(0, 0, u.originZ), c, gloss, relief);
  } else if (material == kHallCeiling) {
    albedo = ceilingAlbedo(in.world, u, c, emission);
  } else if (material == kHallWall) {
    albedo = wallAlbedo(in, c, relief);
  } else if (material == kHallDoor) {
    albedo = doorAlbedo(in, c, gloss, relief);
  } else if (material == kHallPainting) {
    albedo = painting(in);
    gloss = 0.1;
  } else {
    albedo = in.color * (0.94 + 0.08 * valueNoise(in.world.xy * 6.0 + in.world.z));
    gloss = 0.2;
  }
  float3 nb = bump(n, in.world, relief);
  Surface s = makeSurface(albedo, nb);
  s.occlusion = corners(in.world, c);
  s.specular = gloss > 0 ? 0.04 : 0.0;
  s.roughness = 1.0 - gloss;
  s.emission = emission;
  float shadow = shadowAt(in.world, nb, u, shadowMap);
  float3 spec;
  float3 lit = fixtures(in.world, nb, gloss, u, c, spec);
  if (material == kHallCeiling) lit += u.lampColor * u.night * 0.35;  // light bounced up from the floor and walls
  float3 col = lightSurface(u, in.world, s, shadow) + albedo * lit * s.occlusion + spec;
  return float4(applyFog(col, in.world, u), 1.0);
}

fragment void hall_shadow_fs(HallOut in [[stage_in]]) {
  // Windows let the sun in, except through their frames.
  if (int(in.material + 0.5) == kHallWindow) {
    float2 q = in.uv;
    float frame = 1.0 - hallRect(q, float2(0.05, 0.05), float2(0.95, 0.95));
    float bars = max(1.0 - smoothstep(0.015, 0.025, abs(q.x - 0.5)), 1.0 - smoothstep(0.012, 0.022, abs(q.y - 0.62)));
    if (frame + bars < 0.5) discard_fragment();
  }
}
