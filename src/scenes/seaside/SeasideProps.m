#import "SeasideProps.h"

#import "Plants.h"
#import "SeasideScene.h"
#import "SceneUtil.h"

/// A surface of revolution about the vertical through `at`: `profile` (radius, y) from bottom to
/// top, smooth normals; uv = (around 0 … 1, y).
static void Lathe(MeshBuilder *m, const simd_float2 *profile, int count, int segments, simd_float3 color, simd_float3 at) {
  simd_float2 normals[48];
  count = MIN(count, 48);
  for (int i = 0; i < count; i++) {
    simd_float2 n = 0;
    for (int j = i - 1; j <= i; j++) {
      if (j < 0 || j + 1 >= count) continue;
      simd_float2 d = profile[j + 1] - profile[j];
      if (simd_length(d) < 1e-6f) continue;
      n += simd_normalize((simd_float2){d.y, -d.x});  // outward for a profile going up
    }
    normals[i] = simd_length(n) > 1e-6f ? simd_normalize(n) : (simd_float2){1, 0};
  }
  for (int i = 0; i + 1 < count; i++) {
    for (int k = 0; k < segments; k++) {
      int ring[4] = {i, i, i + 1, i + 1}, step[4] = {k, k + 1, k + 1, k};
      simd_float3 p[4], n[4];
      simd_float2 uv[4];
      for (int v = 0; v < 4; v++) {
        float a = 2 * (float)M_PI * step[v] / segments, c = cosf(a), s = sinf(a);
        simd_float2 q = profile[ring[v]], nq = normals[ring[v]];
        p[v] = at + (simd_float3){q.x * c, q.y, q.x * s};
        n[v] = (simd_float3){nq.x * c, nq.y, nq.x * s};
        uv[v] = (simd_float2){(float)step[v] / segments, q.y};
      }
      int tri[6] = {0, 1, 2, 0, 2, 3};
      for (int t = 0; t < 6; t++) [m vertex:p[tri[t]] normal:n[tri[t]] color:color uv:uv[tri[t]]];
    }
  }
}

/// A four-sided frustum around the vertical through `c`: half-size b at y0, t at y1, sides only.
static void Frustum4(MeshBuilder *m, simd_float3 c, float b, float t, float y0, float y1, simd_float3 color) {
  simd_float3 lo[4] = {{-b, y0, -b}, {b, y0, -b}, {b, y0, b}, {-b, y0, b}};
  simd_float3 hi[4] = {{-t, y1, -t}, {t, y1, -t}, {t, y1, t}, {-t, y1, t}};
  for (int i = 0; i < 4; i++) {
    int j = (i + 1) % 4;
    simd_float3 n = simd_normalize(simd_cross(lo[j] - lo[i], hi[i] - lo[i]));
    simd_float3 mid = (lo[i] + lo[j] + hi[i] + hi[j]) / 4;
    if (simd_dot(n, (simd_float3){mid.x, 0, mid.z}) < 0) n = -n;
    [m quadA:c + lo[i] b:c + lo[j] c:c + hi[j] d:c + hi[i] normal:n color:color];
  }
}

#pragma mark - Balustrade

NSData *BalusterMesh(BOOL lite) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:11];
  m.material = kMaterialStone;
  simd_float3 stone = {1, 1, 1}, at = {0, 0, 0};  // the shader colours the stone
  float H = kCopingBottom - kPlinthTop;
  [m boxFrom:(simd_float3){-0.075f, 0, -0.075f} to:(simd_float3){0.075f, 0.07f * H / 0.66f, 0.075f} color:stone];
  [m boxFrom:(simd_float3){-0.07f, H - 0.07f * H / 0.66f, -0.07f} to:(simd_float3){0.07f, H, 0.07f} color:stone];
  // A vase: a ring over the base block, a neck, a full belly, a slender upper neck, a collar.
  static const simd_float2 full[] = {
    {0.064f, 0.07f}, {0.068f, 0.082f}, {0.066f, 0.094f}, {0.056f, 0.104f}, {0.046f, 0.124f}, {0.047f, 0.15f}, {0.058f, 0.185f},
    {0.072f, 0.23f}, {0.080f, 0.28f}, {0.079f, 0.32f}, {0.071f, 0.37f}, {0.056f, 0.425f}, {0.042f, 0.47f}, {0.036f, 0.505f},
    {0.040f, 0.52f}, {0.052f, 0.535f}, {0.054f, 0.55f}, {0.045f, 0.562f}, {0.050f, 0.574f}, {0.060f, 0.59f}};
  static const simd_float2 simple[] = {{0.064f, 0.07f}, {0.046f, 0.124f}, {0.072f, 0.23f}, {0.079f, 0.30f},
                                       {0.056f, 0.425f}, {0.036f, 0.505f}, {0.054f, 0.55f}, {0.060f, 0.59f}};
  // The profile is drawn 0.66 m tall: fit it between the plinth and the coping.
  const simd_float2 *profile = lite ? simple : full;
  int count = lite ? sizeof simple / sizeof simple[0] : sizeof full / sizeof full[0];
  simd_float2 fitted[32];
  for (int i = 0; i < count; i++) fitted[i] = (simd_float2){profile[i].x, profile[i].y * H / 0.66f};
  Lathe(m, fitted, count, lite ? 6 : 12, stone, at);
  return m.data;
}

#pragma mark - Lamp post

NSData *LampPostMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:12];
  m.material = kMaterialPaint;
  simd_float3 paint = {1, 1, 1}, at = {0, 0, 0};
  static const simd_float2 base[] = {{0.16f, 0}, {0.16f, 0.05f}, {0.14f, 0.07f}, {0.125f, 0.12f}, {0.11f, 0.30f},
                                     {0.095f, 0.36f}, {0.09f, 0.48f}, {0.105f, 0.5f}, {0.105f, 0.55f}, {0.075f, 0.6f}};
  Lathe(m, base, sizeof base / sizeof base[0], 12, paint, at);
  static const simd_float2 shaft[] = {{0.068f, 0.6f}, {0.058f, 1.6f}, {0.05f, 2.5f}, {0.062f, 2.52f}, {0.062f, 2.58f},
                                      {0.046f, 2.62f}, {0.042f, 3.5f}, {0.056f, 3.52f}, {0.056f, 3.57f}, {0.03f, 3.6f}};
  Lathe(m, shaft, sizeof shaft / sizeof shaft[0], 10, paint, at);
  static const simd_float2 finial[] = {{0.03f, 3.6f}, {0.045f, 3.64f}, {0.03f, 3.7f}, {0.004f, 3.8f}};
  Lathe(m, finial, sizeof finial / sizeof finial[0], 8, paint, at);
  // The crook: up and over toward +x, ending above the lantern; a brace under it.
  const float cx = 0.3f, cy = 3.25f, r = 0.3f;
  const int n = 16;
  simd_float3 prev = {0, cy, 0};
  for (int i = 1; i <= n; i++) {
    float a = (float)M_PI - ((float)M_PI + 0.3f) * i / n;
    simd_float3 p = {cx + r * cosf(a), cy + r * sinf(a), 0};
    [m tubeFrom:prev to:p r0:0.022f r1:0.022f segments:6 color:paint toColor:paint vScale:1];
    prev = p;
  }
  [m tubeFrom:(simd_float3){0.03f, 2.95f, 0} to:(simd_float3){0.24f, 3.26f, 0} r0:0.011f r1:0.011f segments:5 color:paint toColor:paint vScale:1];
  // The lantern hanging from the crook's end (x = kBalustradeS − kLanternS).
  simd_float3 lc = {prev.x, 0, 0};
  [m tubeFrom:prev to:(simd_float3){lc.x, 3.1f, 0} r0:0.012f r1:0.012f segments:5 color:paint toColor:paint vScale:1];
  Frustum4(m, lc, 0.17f, 0.03f, 2.98f, 3.1f, paint);  // cap
  Frustum4(m, lc, 0.15f, 0.17f, 2.96f, 2.98f, paint);
  m.material = kMaterialLamp;
  Frustum4(m, lc, 0.09f, 0.135f, 2.62f, 2.96f, Hex(0xd8d0b8));
  m.material = kMaterialPaint;
  Frustum4(m, lc, 0.03f, 0.095f, 2.55f, 2.62f, paint);
  for (int i = 0; i < 4; i++) {  // the frame's corner bars
    float sx = (i & 1) ? 1 : -1, sz = (i & 2) ? 1 : -1;
    [m tubeFrom:lc + (simd_float3){sx * 0.09f, 2.62f, sz * 0.09f} to:lc + (simd_float3){sx * 0.135f, 2.96f, sz * 0.135f} r0:0.008f r1:0.008f
        segments:4 color:paint toColor:paint vScale:1];
  }
  return m.data;
}

#pragma mark - Pines

/// A tube along `points` with radii `radii`, its rings shared from one point to the next (no gaps
/// where it bends), bark; uv = (around 0 … 1, metres along × vScale).
static void Sweep(MeshBuilder *m, const simd_float3 *points, const float *radii, int count, int sides, simd_float3 color, float vScale) {
  m.material = kMaterialBark;
  simd_float3 normal = Perpendicular(simd_normalize(points[1] - points[0]));
  simd_float3 prevP[17], prevN[17], ringP[17], ringN[17];
  sides = MIN(sides, 16);
  float v = 0, prevV = 0;
  for (int i = 0; i < count; i++) {
    simd_float3 t = simd_normalize(i == 0 ? points[1] - points[0] : i == count - 1 ? points[i] - points[i - 1] : points[i + 1] - points[i - 1]);
    normal = simd_normalize(normal - t * simd_dot(normal, t));  // carried along the curve without twisting
    simd_float3 binormal = simd_cross(t, normal);
    for (int k = 0; k <= sides; k++) {
      float a = 2 * (float)M_PI * k / sides;
      ringN[k] = normal * cosf(a) + binormal * sinf(a);
      ringP[k] = points[i] + ringN[k] * radii[i];
    }
    if (i > 0) {
      v += simd_distance(points[i], points[i - 1]) * vScale;
      for (int k = 0; k < sides; k++) {
        float u0 = (float)k / sides, u1 = (float)(k + 1) / sides;
        [m vertex:prevP[k] normal:prevN[k] color:color uv:(simd_float2){u0, prevV}];
        [m vertex:ringP[k] normal:ringN[k] color:color uv:(simd_float2){u0, v}];
        [m vertex:prevP[k + 1] normal:prevN[k + 1] color:color uv:(simd_float2){u1, prevV}];
        [m vertex:prevP[k + 1] normal:prevN[k + 1] color:color uv:(simd_float2){u1, prevV}];
        [m vertex:ringP[k] normal:ringN[k] color:color uv:(simd_float2){u0, v}];
        [m vertex:ringP[k + 1] normal:ringN[k + 1] color:color uv:(simd_float2){u1, v}];
      }
    }
    memcpy(prevP, ringP, sizeof ringP);
    memcpy(prevN, ringN, sizeof ringN);
    prevV = v;
  }
}

typedef struct {
  simd_float3 center, radii;
} Clump;

NSData *WindPineMesh(int variant, BOOL lite) {
  // The skeleton from the variant's own random sequence (the lite mesh has the same one).
  Rng r = RngFor(301, variant, 0, 81);
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:(uint32_t)(301 + variant * 17 + (lite ? 5 : 0))];
  simd_float3 bark = Hex(0x5a4a40);
  // How far the trunk's top leans downwind (a fraction of the height), where it forks, its radius.
  float lean = variant == 0 ? 0.2f : variant == 1 ? 0.32f : 0.26f;
  float forkY = variant == 0 ? 0.6f : variant == 1 ? 0.74f : 0.55f;
  float r0 = variant == 1 ? 0.018f : 0.022f;
  // The trunk leans from the ground up and bows further, twisting a little sideways; a flared foot.
  enum { nt = 9 };
  simd_float3 trunk[nt];
  float radius[nt];
  for (int i = 0; i < nt; i++) {
    float t = (float)i / (nt - 1);
    trunk[i] = (simd_float3){lean * (0.55f * t + 0.45f * t * t), t * forkY, 0.025f * sinf(t * 4.0f + variant * 2.0f) * t};
    radius[i] = r0 * (1.0f - 0.45f * t) * (i == 0 ? 1.35f : 1.0f);
  }
  trunk[0].y = -0.03f;
  Sweep(m, trunk, radius, nt, 8, bark, 30);
  simd_float3 fork = trunk[nt - 1];

  // The crown, swept downwind (+x): a wide flat dome with lobes round its rim (umbrella pine), a
  // smaller one high up (maritime pine), or open lobes on the limbs' ends (Aleppo pine).
  Clump clumps[16];
  int nc = 0;
  if (variant == 0) {
    simd_float3 c = fork + (simd_float3){0.08f, 0.27f, 0};
    clumps[nc++] = (Clump){c, (simd_float3){0.40f, 0.10f, 0.33f}};
    for (int i = 0; i < 6; i++) {
      float a = i * 1.047f + (float)Range(&r, -0.3, 0.3);
      simd_float3 at = c + (simd_float3){cosf(a) * 0.32f + 0.05f, (float)Range(&r, -0.035, 0.02), sinf(a) * 0.27f};
      clumps[nc++] = (Clump){at, (simd_float3){(float)Range(&r, 0.12, 0.17), (float)Range(&r, 0.06, 0.08), (float)Range(&r, 0.1, 0.14)}};
    }
  } else if (variant == 1) {
    simd_float3 c = fork + (simd_float3){0.08f, 0.16f, 0};
    clumps[nc++] = (Clump){c, (simd_float3){0.2f, 0.1f, 0.16f}};
    for (int i = 0; i < 4; i++) {
      float a = i * 1.571f + (float)Range(&r, -0.4, 0.4);
      simd_float3 at = c + (simd_float3){cosf(a) * 0.15f + 0.04f, (float)Range(&r, -0.06, 0.03), sinf(a) * 0.12f};
      clumps[nc++] = (Clump){at, (simd_float3){0.1f, 0.07f, 0.09f}};
    }
  } else {
    for (int i = 0; i < 6; i++) {
      float a = (i / 5.0f - 0.5f) * 3.4f + (float)Range(&r, -0.25, 0.25);
      float reach = (float)Range(&r, 0.14, 0.3) * (cosf(a) < 0 ? 0.55f : 1.0f);
      simd_float3 at = fork + (simd_float3){cosf(a) * reach + 0.06f, (float)Range(&r, 0.16, 0.36), sinf(a) * reach};
      clumps[nc++] = (Clump){at, (simd_float3){(float)Range(&r, 0.11, 0.15), (float)Range(&r, 0.07, 0.1), (float)Range(&r, 0.09, 0.13)}};
    }
  }
  // Limbs from the fork up into each clump's underside.
  for (int i = 0; i < nc; i++) {
    simd_float3 end = clumps[i].center - (simd_float3){0, clumps[i].radii.y * 0.5f, 0};
    simd_float3 mid = fork + (end - fork) * 0.55f + (simd_float3){0.02f, 0.04f, 0};
    simd_float3 limb[3] = {fork, mid, end};
    float lr[3] = {r0 * 0.5f, r0 * 0.33f, r0 * 0.14f};
    Sweep(m, limb, lr, 3, 6, bark, 30);
  }
  m.material = kMaterialCard + kCellPine;
  for (int i = 0; i < nc; i++) {
    int count = (int)(clumps[i].radii.x * clumps[i].radii.z * 5400.0f * (lite ? 0.38f : 1.0f));
    count = MIN(MAX(count, 12), lite ? 150 : 360);
    PlantCrown(m, clumps[i].center, clumps[i].radii, count, lite ? 0.095f : 0.07f, 0.05f);
  }
  return m.data;
}
