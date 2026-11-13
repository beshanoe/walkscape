#import "ParisProps.h"

#import "Furniture.h"
#import "ParisScene.h"
#import "Plants.h"
#import "SceneUtil.h"

static const simd_float3 kUp = {0, 1, 0};

/// A vertical tube (y0 → y1) with flat caps on top, around (x, z).
static void Post(MeshBuilder *m, float x, float z, float y0, float y1, float r0, float r1, simd_float3 color, int segments) {
  [m tubeFrom:(simd_float3){x, y0, z} to:(simd_float3){x, y1, z} r0:r0 r1:r1 segments:segments color:color toColor:color vScale:1];
  for (int i = 0; i < segments; i++) {
    float a0 = 6.283f * i / segments, a1 = 6.283f * (i + 1) / segments;
    [m vertex:(simd_float3){x, y1, z} normal:kUp color:color uv:(simd_float2){0, 0}];
    [m vertex:(simd_float3){x + r1 * cosf(a1), y1, z + r1 * sinf(a1)} normal:kUp color:color uv:(simd_float2){0, 0}];
    [m vertex:(simd_float3){x + r1 * cosf(a0), y1, z + r1 * sinf(a0)} normal:kUp color:color uv:(simd_float2){0, 0}];
  }
}

/// A tube between two points with flat ends (for frames, hoops, poles).
static void Rod(MeshBuilder *m, simd_float3 a, simd_float3 b, float r, simd_float3 color) {
  [m tubeFrom:a to:b r0:r r1:r segments:6 color:color toColor:color vScale:1];
}

/// A disc facing `n` (both sides drawn by the pipeline: no culling).
static void Disc(MeshBuilder *m, simd_float3 c, simd_float3 n, float r, simd_float3 color, int segments) {
  simd_float3 a = Perpendicular(n), b = simd_cross(n, a);
  for (int i = 0; i < segments; i++) {
    float a0 = 6.283f * i / segments, a1 = 6.283f * (i + 1) / segments;
    [m vertex:c normal:n color:color uv:(simd_float2){0, 0}];
    [m vertex:c + (a * cosf(a0) + b * sinf(a0)) * r normal:n color:color uv:(simd_float2){0, 0}];
    [m vertex:c + (a * cosf(a1) + b * sinf(a1)) * r normal:n color:color uv:(simd_float2){0, 0}];
  }
}

/// A ring (a torus of `segments` short tubes) in the plane through `c` normal to `n`.
static void Hoop(MeshBuilder *m, simd_float3 c, simd_float3 n, float r, float thick, simd_float3 color, int segments, float from, float to) {
  simd_float3 a = Perpendicular(n), b = simd_cross(n, a);
  for (int i = 0; i < segments; i++) {
    float a0 = from + (to - from) * i / segments, a1 = from + (to - from) * (i + 1) / segments;
    [m tubeFrom:c + (a * cosf(a0) + b * sinf(a0)) * r to:c + (a * cosf(a1) + b * sinf(a1)) * r r0:thick r1:thick segments:5 color:color toColor:color
        vScale:1];
  }
}

/// A frustum of a square pyramid: bottom half-size b at y0, top half-size t at y1, sides only.
static void Frustum(MeshBuilder *m, float b, float t, float y0, float y1, simd_float3 color) {
  simd_float3 lo[4] = {{-b, y0, -b}, {b, y0, -b}, {b, y0, b}, {-b, y0, b}};
  simd_float3 hi[4] = {{-t, y1, -t}, {t, y1, -t}, {t, y1, t}, {-t, y1, t}};
  for (int i = 0; i < 4; i++) {
    int j = (i + 1) % 4;
    simd_float3 n = simd_normalize(simd_cross(lo[j] - lo[i], hi[i] - lo[i]));
    [m quadA:lo[i] b:lo[j] c:hi[j] d:hi[i] normal:-n color:color];
  }
}

static void Box(MeshBuilder *m, simd_float3 lo, simd_float3 hi, simd_float3 color) {
  [m boxFrom:lo to:hi color:color];
}

static void Lamp(MeshBuilder *m) {
  simd_float3 iron = Hex(0x1c2620);
  m.material = 0;
  Post(m, 0, 0, 0, 0.35f, 0.17f, 0.15f, iron, 10);
  Post(m, 0, 0, 0.35f, 0.95f, 0.13f, 0.09f, iron, 10);
  Post(m, 0, 0, 0.95f, 4.0f, 0.07f, 0.05f, iron, 8);
  Post(m, 0, 0, 3.95f, 4.08f, 0.12f, 0.12f, iron, 8);
  m.material = kMaterialLamp;  // the lantern: glass that glows at night
  Frustum(m, 0.17f, 0.27f, 4.08f, kLampHeight, Hex(0xd8d0b8));
  m.material = 0;
  Frustum(m, 0.3f, 0.04f, kLampHeight, kLampHeight + 0.28f, iron);
  Post(m, 0, 0, kLampHeight + 0.28f, kLampHeight + 0.42f, 0.025f, 0.01f, iron, 6);
}

#pragma mark - Cars

/// A car's shape (metres; z along it, +z the front; the origin under its middle).
typedef struct {
  float length, width, height;
  float wheelbase, overhangF, wheelR, clearance;
  float belt, hoodFront, tailTop;
  float wsBase, wsTop, roofEnd, rearBase;  // z: windshield at the hood / at the roof; roof's end; rear glass at the tail
  float corner;                            // corner radius seen from above
} CarShape;

static const CarShape kCars[] = {
  {4.05f, 1.76f, 1.46f, 2.60f, 0.85f, 0.31f, 0.16f, 0.95f, 0.78f, 0.95f, 0.70f, -0.05f, -1.30f, -1.92f, 0.45f},  // hatchback
  {4.70f, 1.80f, 1.45f, 2.80f, 0.95f, 0.32f, 0.15f, 0.97f, 0.80f, 0.96f, 0.95f, 0.18f, -0.95f, -1.60f, 0.45f},  // saloon
  {4.40f, 1.82f, 1.62f, 2.65f, 0.90f, 0.35f, 0.20f, 1.07f, 0.92f, 1.05f, 0.85f, 0.10f, -1.45f, -2.05f, 0.45f},  // small SUV
  {4.30f, 1.82f, 1.80f, 2.70f, 0.85f, 0.31f, 0.17f, 1.05f, 0.92f, 1.00f, 1.20f, 0.55f, -2.05f, -2.10f, 0.40f},  // small van
  {2.70f, 1.66f, 1.55f, 1.87f, 0.45f, 0.29f, 0.16f, 0.92f, 0.85f, 0.92f, 0.95f, 0.30f, -0.85f, -1.25f, 0.40f},  // two-seater
};

static float CarTop(const CarShape *c, float z) {
  float half = c->length / 2, belt = c->belt + 0.03f;
  if (z >= c->wsBase) {
    float t = (z - c->wsBase) / (half - c->wsBase);
    return belt + (c->hoodFront - belt) * powf(t, 1.4f) - 0.06f * powf(fmaxf(t - 0.85f, 0) / 0.15f, 2);
  }
  if (z >= c->wsTop) return c->height + (belt - c->height) * (z - c->wsTop) / (c->wsBase - c->wsTop);
  if (z >= c->roofEnd) {
    float mid = (c->wsTop + c->roofEnd) / 2, span = (c->wsTop - c->roofEnd) / 2;
    return c->height - 0.025f * powf((z - mid) / span, 2);
  }
  if (z >= c->rearBase) return c->height + (belt - c->height) * (c->roofEnd - z) / (c->roofEnd - c->rearBase);
  float t = (c->rearBase - z) / fmaxf(c->rearBase + half, 1e-3f);
  return belt + (c->tailTop - belt) * t - 0.05f * powf(fmaxf(t - 0.8f, 0) / 0.2f, 2);
}

static float CarHalfWidth(const CarShape *c, float z) {
  float e = fabsf(z) - (c->length / 2 - c->corner);
  return e <= 0 ? c->width / 2 : c->width / 2 - c->corner + sqrtf(fmaxf(c->corner * c->corner - e * e, 0));
}

/// The bottom of the body at z (rising at the bumpers); `side`: also round the wheel arches.
static float CarBottom(const CarShape *c, float z, BOOL side) {
  float half = c->length / 2, end = half - fabsf(z);
  float y = end < 0.3f ? 0.3f + (c->clearance - 0.3f) * end / 0.3f : c->clearance;
  if (side) {
    float zf = half - c->overhangF, axles[2] = {zf, zf - c->wheelbase}, R = c->wheelR + 0.07f;
    for (int i = 0; i < 2; i++) {
      float d = fabsf(z - axles[i]);
      if (d < R) y = fmaxf(y, c->wheelR + sqrtf(R * R - d * d));
    }
  }
  return y;
}

enum { kRing = 9 };  // points on half a cross-section, bottom centre to roof centre

/// Half a cross-section at z (x ≥ 0).
static void CarRing(const CarShape *c, float z, simd_float2 *p) {
  float w = CarHalfWidth(c, z), top = CarTop(c, z), b = CarBottom(c, z, NO), sb = CarBottom(c, z, YES);
  float beltY = fminf(c->belt, top - 0.04f);
  BOOL cabin = top > c->belt + 0.06f;
  float lean = cabin ? 0.05f + 0.22f * fminf((top - beltY) / 0.5f, 1) : 0.12f;
  float y4 = beltY - 0.12f, y3 = fminf(fmaxf(sb + 0.18f, b + 0.1f), y4 - 0.01f);
  p[0] = (simd_float2){0, b};
  p[1] = (simd_float2){w - 0.15f, b};
  p[2] = (simd_float2){w - 0.03f, fminf(sb + 0.04f, y3 - 0.01f)};
  p[3] = (simd_float2){w, y3};
  p[4] = (simd_float2){w, y4};
  p[5] = (simd_float2){w - 0.03f, beltY};
  p[6] = (simd_float2){w - lean, top - 0.06f};
  p[7] = (simd_float2){w - lean - 0.08f, top - 0.005f};
  p[8] = (simd_float2){0, top + 0.015f};
}

static void AddSorted(float *zs, int *n, float z) {
  zs[(*n)++] = z;
}

static int CompareFloat(const void *a, const void *b) {
  float x = *(const float *)a, y = *(const float *)b;
  return x < y ? -1 : x > y;
}

/// A car: a body lofted through cross-sections (paint, glass, black plastic underneath), end
/// caps with lamps and number plates, mirrors, wheels.
static void Car(MeshBuilder *m, const CarShape *c) {
  float half = c->length / 2;
  // Stations along the car: even steps plus every place a material changes.
  float zs[96];
  int n = 0;
  for (int i = 0; i <= 48; i++) AddSorted(zs, &n, -half + c->length * i / 48);
  float zB = (c->wsTop + c->roofEnd) / 2 + 0.1f;
  float zf = half - c->overhangF, zr = zf - c->wheelbase, R = c->wheelR + 0.07f;
  float marks[] = {c->wsBase, c->wsTop, c->roofEnd, c->rearBase, zB - 0.06f, zB + 0.06f, c->wsTop + 0.05f, c->roofEnd + 0.12f,
                   zf - R, zf + R, zr - R, zr + R, zf, zr};
  for (size_t i = 0; i < sizeof marks / sizeof marks[0]; i++) {
    if (marks[i] > -half + 0.01f && marks[i] < half - 0.01f) AddSorted(zs, &n, marks[i]);
  }
  qsort(zs, n, sizeof(float), CompareFloat);
  int k = 0;
  for (int i = 0; i < n; i++) {
    if (k == 0 || zs[i] - zs[k - 1] > 0.008f) zs[k++] = zs[i];
  }
  n = k;

  // The grid of points: n stations × (2 kRing − 1) round the section (right side up, left side down).
  enum { kAround = 2 * kRing - 1 };
  simd_float3 *P = malloc(sizeof(simd_float3) * n * kAround), *N = malloc(sizeof(simd_float3) * n * kAround);
  for (int i = 0; i < n; i++) {
    simd_float2 ring[kRing];
    CarRing(c, zs[i], ring);
    for (int j = 0; j < kAround; j++) {
      simd_float2 q = j < kRing ? ring[j] : ring[kAround - 1 - j];
      P[i * kAround + j] = (simd_float3){j < kRing ? q.x : -q.x, q.y, zs[i]};
    }
  }
  for (int i = 0; i < n; i++) {
    for (int j = 0; j < kAround; j++) {
      simd_float3 tz = P[MIN(i + 1, n - 1) * kAround + j] - P[MAX(i - 1, 0) * kAround + j];
      simd_float3 ts = P[i * kAround + MIN(j + 1, kAround - 1)] - P[i * kAround + MAX(j - 1, 0)];
      simd_float3 nn = simd_cross(tz, ts);
      float len = simd_length(nn);
      nn = len > 1e-6f ? nn / len : (simd_float3){0, -1, 0};
      simd_float3 out = P[i * kAround + j] - (simd_float3){0, 0.7f, zs[i]};
      N[i * kAround + j] = simd_dot(nn, out) < 0 ? -nn : nn;
    }
  }
  simd_float3 white = {1, 1, 1}, plastic = Hex(0x1c1c1e), under = Hex(0x101010);
  for (int i = 0; i + 1 < n; i++) {
    float zm = (zs[i] + zs[i + 1]) / 2;
    BOOL sideGlass = zm > c->roofEnd + 0.12f && zm < c->wsTop + 0.05f && fabsf(zm - zB) > 0.06f && CarTop(c, zm) > c->belt + 0.15f;
    BOOL topGlass = (zm > c->wsTop && zm < c->wsBase) || (zm > c->rearBase && zm < c->roofEnd);
    for (int j = 0; j + 1 < kAround; j++) {
      int seg = j < kRing - 1 ? j : kAround - 2 - j;  // 0 underside … 7 roof, mirrored
      simd_float3 color = white;
      if (seg == 0) {
        m.material = 0;
        color = under;
      } else if (seg == 1) {
        m.material = 0;
        color = plastic;
      } else if ((seg == 5 && sideGlass) || (seg == 7 && topGlass)) {
        m.material = kMaterialGlass;
      } else {
        m.material = kMaterialPaint;
      }
      int a = i * kAround + j, b = (i + 1) * kAround + j;
      simd_float3 p[4] = {P[a], P[b], P[b + 1], P[a + 1]}, nn[4] = {N[a], N[b], N[b + 1], N[a + 1]};
      int order[6] = {0, 1, 2, 0, 2, 3};
      for (int v = 0; v < 6; v++) [m vertex:p[order[v]] normal:nn[order[v]] color:color uv:(simd_float2){p[order[v]].z, p[order[v]].y}];
    }
  }
  // End caps: a fan across the last sections; a dark grille at the front.
  for (int e = 0; e < 2; e++) {
    int i = e ? n - 1 : 0;
    float dir = e ? 1 : -1;
    simd_float3 centre = 0;
    for (int j = 0; j < kAround; j++) centre += P[i * kAround + j] / kAround;
    centre.z += dir * 0.02f;
    simd_float3 nrm = {0, 0, dir};
    for (int j = 0; j + 1 < kAround; j++) {
      simd_float3 a = P[i * kAround + j], b = P[i * kAround + j + 1];
      float y = (a.y + b.y + centre.y) / 3;
      BOOL grille = e && y > 0.42f && y < c->hoodFront - 0.08f;
      m.material = grille ? 0 : kMaterialPaint;
      simd_float3 color = grille ? Hex(0x202224) : white;
      [m vertex:centre normal:nrm color:color uv:(simd_float2){centre.z, centre.y}];
      [m vertex:a normal:nrm color:color uv:(simd_float2){a.z, a.y}];
      [m vertex:b normal:nrm color:color uv:(simd_float2){b.z, b.y}];
    }
  }
  free(P);
  free(N);
  // Lamps and number plates (white with a blue band), mirrors, door handles.
  m.material = 0;
  float fw = c->width / 2 - c->corner, ft = half + 0.012f;
  for (int s = -1; s <= 1; s += 2) {
    Box(m, (simd_float3){s > 0 ? 0.18f : -fw, c->hoodFront - 0.17f, ft - 0.01f}, (simd_float3){s > 0 ? fw : -0.18f, c->hoodFront - 0.05f, ft},
        Hex(0xdfe3e6));
    Box(m, (simd_float3){s > 0 ? 0.2f : -fw, c->tailTop - 0.2f, -ft}, (simd_float3){s > 0 ? fw : -0.2f, c->tailTop - 0.07f, -ft + 0.01f},
        Hex(0x8a1010));
  }
  for (int e = 0; e < 2; e++) {
    float z = e ? ft + 0.002f : -ft - 0.002f, y = e ? 0.32f : 0.52f;
    Box(m, (simd_float3){-0.26f, y, z - 0.004f}, (simd_float3){0.26f, y + 0.11f, z + 0.004f}, Hex(0xeeeeea));
    Box(m, (simd_float3){-0.265f, y, z - 0.005f}, (simd_float3){-0.225f, y + 0.11f, z + 0.005f}, Hex(0x1f3b9a));
  }
  float mw = CarHalfWidth(c, c->wsBase - 0.2f);
  for (int s = -1; s <= 1; s += 2) {
    m.material = kMaterialPaint;
    Box(m, (simd_float3){s > 0 ? mw : -mw - 0.16f, c->belt + 0.02f, c->wsBase - 0.3f}, (simd_float3){s > 0 ? mw + 0.16f : -mw, c->belt + 0.14f, c->wsBase - 0.18f},
        white);
    m.material = 0;
    for (int d = 0; d < 2; d++) {
      float z = d ? zB - 0.75f : zB + 0.25f;
      if (z < c->roofEnd + 0.1f) continue;
      float x = CarHalfWidth(c, z);
      Box(m, (simd_float3){s > 0 ? x - 0.005f : -x - 0.012f, c->belt - 0.14f, z - 0.12f}, (simd_float3){s > 0 ? x + 0.012f : -x + 0.005f, c->belt - 0.11f, z},
          plastic);
    }
  }
  // Wheels: tyre, sidewall, a dished alloy rim.
  simd_float3 tyre = Hex(0x161616), rim = Hex(0x8c8f93);
  for (int i = 0; i < 4; i++) {
    float s = i & 1 ? 1 : -1, z = i & 2 ? zf : zr, xo = s * (c->width / 2 - 0.05f), xi = s * (c->width / 2 - 0.26f);
    m.material = 0;
    [m tubeFrom:(simd_float3){xi, c->wheelR, z} to:(simd_float3){xo, c->wheelR, z} r0:c->wheelR r1:c->wheelR segments:16 color:tyre toColor:tyre vScale:1];
    Disc(m, (simd_float3){xo, c->wheelR, z}, (simd_float3){s, 0, 0}, c->wheelR, tyre, 16);
    Disc(m, (simd_float3){xo + s * 0.002f, c->wheelR, z}, (simd_float3){s, 0, 0}, c->wheelR * 0.68f, rim, 16);
    Disc(m, (simd_float3){xo + s * 0.004f, c->wheelR, z}, (simd_float3){s, 0, 0}, c->wheelR * 0.18f, rim * 0.6f, 8);
    for (int k = 0; k < 5; k++) {  // spokes, darker gaps between them
      float a = k * 6.283f / 5;
      simd_float3 dir = {0, cosf(a), sinf(a)};
      simd_float3 at = (simd_float3){xo + s * 0.005f, c->wheelR, z} + dir * c->wheelR * 0.42f;
      Box(m, at - (simd_float3){0.002f, 0.03f, 0.03f}, at + (simd_float3){0.002f, 0.03f, 0.03f}, Hex(0x2a2b2d));
    }
  }
}

#pragma mark - Two wheels

static void Scooter(MeshBuilder *m) {
  simd_float3 black = Hex(0x18181a), grey = Hex(0x55585c), white = {1, 1, 1};
  for (int w = 0; w < 2; w++) {
    float z = w ? 0.62f : -0.62f;
    m.material = 0;
    [m tubeFrom:(simd_float3){-0.05f, 0.22f, z} to:(simd_float3){0.05f, 0.22f, z} r0:0.22f r1:0.22f segments:12 color:black toColor:black vScale:1];
    Disc(m, (simd_float3){0.05f, 0.22f, z}, (simd_float3){1, 0, 0}, 0.14f, grey, 10);
    Disc(m, (simd_float3){-0.05f, 0.22f, z}, (simd_float3){-1, 0, 0}, 0.14f, grey, 10);
  }
  m.material = kMaterialPaint;
  Box(m, (simd_float3){-0.17f, 0.3f, -0.75f}, (simd_float3){0.17f, 0.62f, -0.1f}, white);   // rear body
  Box(m, (simd_float3){-0.14f, 0.28f, -0.1f}, (simd_float3){0.14f, 0.36f, 0.32f}, white);   // floorboard
  Box(m, (simd_float3){-0.2f, 0.32f, 0.32f}, (simd_float3){0.2f, 1.0f, 0.46f}, white);      // leg shield
  Box(m, (simd_float3){-0.1f, 0.42f, 0.48f}, (simd_float3){0.1f, 0.7f, 0.66f}, white);      // front mudguard
  m.material = 0;
  Box(m, (simd_float3){-0.16f, 0.62f, -0.68f}, (simd_float3){0.16f, 0.74f, -0.12f}, black);  // seat
  Rod(m, (simd_float3){0, 0.95f, 0.42f}, (simd_float3){0, 1.12f, 0.36f}, 0.03f, grey);
  Rod(m, (simd_float3){-0.33f, 1.12f, 0.36f}, (simd_float3){0.33f, 1.12f, 0.36f}, 0.018f, black);
  Box(m, (simd_float3){-0.08f, 1.0f, 0.46f}, (simd_float3){0.08f, 1.1f, 0.5f}, Hex(0xdfe3e6));  // headlamp
}

static void Bicycle(MeshBuilder *m) {
  simd_float3 black = Hex(0x141414), frame = {1, 1, 1}, steel = Hex(0x9a9ca0);
  float r = 0.34f;
  simd_float3 back = {0, r, -0.52f}, front = {0, r, 0.52f};
  m.material = 0;
  Hoop(m, back, (simd_float3){1, 0, 0}, r, 0.018f, black, 18, 0, 6.2832f);
  Hoop(m, front, (simd_float3){1, 0, 0}, r, 0.018f, black, 18, 0, 6.2832f);
  Disc(m, back, (simd_float3){1, 0, 0}, 0.04f, steel, 8);
  Disc(m, front, (simd_float3){1, 0, 0}, 0.04f, steel, 8);
  m.material = kMaterialPaint;
  simd_float3 crank = {0, 0.3f, -0.05f}, seat = {0, 0.85f, -0.2f}, head = {0, 0.88f, 0.38f};
  Rod(m, crank, seat, 0.018f, frame);
  Rod(m, seat, head, 0.018f, frame);
  Rod(m, crank, head - (simd_float3){0, 0.08f, 0}, 0.02f, frame);
  Rod(m, crank, back, 0.012f, frame);
  Rod(m, seat - (simd_float3){0, 0.05f, 0}, back, 0.012f, frame);
  Rod(m, head, front, 0.015f, frame);
  m.material = 0;
  Rod(m, head, head + (simd_float3){0, 0.14f, 0.02f}, 0.014f, steel);
  Rod(m, head + (simd_float3){-0.27f, 0.14f, 0.0f}, head + (simd_float3){0.27f, 0.14f, 0.0f}, 0.012f, black);
  Box(m, seat + (simd_float3){-0.07f, 0.04f, -0.12f}, seat + (simd_float3){0.07f, 0.09f, 0.1f}, black);
}

#pragma mark - Café and street furniture

static void Table(MeshBuilder *m) {
  m.material = 0;
  Post(m, 0, 0, 0, 0.03f, 0.22f, 0.2f, Hex(0x2a2a2a), 10);
  Post(m, 0, 0, 0.03f, 0.7f, 0.025f, 0.025f, Hex(0x2a2a2a), 6);
  Post(m, 0, 0, 0.7f, 0.74f, 0.3f, 0.3f, Hex(0xd8d4cc), 14);  // marble top
}

static void Chair(MeshBuilder *m) {
  m.material = 0;
  simd_float3 rattan = Hex(0x7a6448), frame = Hex(0x2e2620);
  for (int i = 0; i < 4; i++) {
    float x = i & 1 ? 0.18f : -0.18f, z = i & 2 ? 0.18f : -0.18f;
    Post(m, x, z, 0, 0.45f, 0.012f, 0.012f, frame, 5);
  }
  Box(m, (simd_float3){-0.21f, 0.43f, -0.21f}, (simd_float3){0.21f, 0.48f, 0.21f}, rattan);
  Box(m, (simd_float3){-0.21f, 0.48f, -0.24f}, (simd_float3){0.21f, 0.92f, -0.2f}, rattan);  // back (−z)
}

static void Column(MeshBuilder *m) {
  m.material = 0;
  simd_float3 green = Hex(0x23402c);
  Post(m, 0, 0, 0, 0.45f, 0.72f, 0.68f, green, 18);
  static const uint32_t posters[] = {0xc8402a, 0xe0c24a, 0x2a5a9a, 0xe8e2d4, 0x8a2a5a};
  for (int i = 0; i < 4; i++) {
    float y0 = 0.45f + i * 0.68f;
    simd_float3 c = Hex(posters[(i * 3 + 1) % 5]);
    [m tubeFrom:(simd_float3){0, y0, 0} to:(simd_float3){0, y0 + 0.68f, 0} r0:0.62f r1:0.62f segments:18 color:c toColor:c * 0.9f vScale:1];
  }
  Post(m, 0, 0, 3.17f, 3.35f, 0.72f, 0.72f, green, 18);
  [m tubeFrom:(simd_float3){0, 3.35f, 0} to:(simd_float3){0, 4.05f, 0} r0:0.66f r1:0.05f segments:18 color:green toColor:green vScale:1];
  Post(m, 0, 0, 4.05f, 4.3f, 0.05f, 0.02f, green, 6);
}

static void Grate(MeshBuilder *m) {
  m.material = 0;
  simd_float3 iron = Hex(0x1e1e1c);
  [m quadA:(simd_float3){-0.8f, 0.004f, -0.8f} b:(simd_float3){0.8f, 0.004f, -0.8f} c:(simd_float3){0.8f, 0.004f, 0.8f}
         d:(simd_float3){-0.8f, 0.004f, 0.8f} normal:kUp color:iron];
}

static void Bollard(MeshBuilder *m) {
  m.material = 0;
  simd_float3 green = Hex(0x23402c);
  Post(m, 0, 0, 0, 0.85f, 0.065f, 0.055f, green, 8);
  Post(m, 0, 0, 0.85f, 0.92f, 0.075f, 0.03f, green, 8);
}

/// A road sign on a pole, its face toward +z: no parking (blue disc, red ring and cross) or one
/// way (white arrow on blue).
static void Sign(MeshBuilder *m, BOOL noParking) {
  m.material = 0;
  simd_float3 grey = Hex(0x6a6d70), red = Hex(0xb81c1c), blue = Hex(0x1f4aa0), white = Hex(0xeeeeee);
  Post(m, 0, 0, 0, 2.6f, 0.03f, 0.03f, grey, 8);
  if (noParking) {
    Disc(m, (simd_float3){0, 2.3f, 0.035f}, (simd_float3){0, 0, 1}, 0.3f, red, 20);
    Disc(m, (simd_float3){0, 2.3f, 0.037f}, (simd_float3){0, 0, 1}, 0.24f, blue, 20);
    for (int s = -1; s <= 1; s += 2) {
      simd_float3 d = simd_normalize((simd_float3){(float)s, 1, 0}) * 0.24f, w = simd_normalize((simd_float3){-1, (float)s, 0}) * 0.03f;
      simd_float3 c = {0, 2.3f, 0.039f};
      [m quadA:c - d - w b:c + d - w c:c + d + w d:c - d + w normal:(simd_float3){0, 0, 1} color:red];
    }
    Disc(m, (simd_float3){0, 2.3f, 0.033f}, (simd_float3){0, 0, -1}, 0.3f, grey, 20);
  } else {
    Box(m, (simd_float3){-0.35f, 2.15f, 0.03f}, (simd_float3){0.35f, 2.5f, 0.05f}, blue);
    Box(m, (simd_float3){-0.26f, 2.3f, 0.05f}, (simd_float3){0.12f, 2.35f, 0.055f}, white);
    [m quadA:(simd_float3){0.12f, 2.24f, 0.056f} b:(simd_float3){0.28f, 2.325f, 0.056f} c:(simd_float3){0.28f, 2.325f, 0.056f}
           d:(simd_float3){0.12f, 2.41f, 0.056f} normal:(simd_float3){0, 0, 1} color:white];
  }
}

/// A pedestrian signal on its pole, facing +z: the red figure lit.
static void CrossingLight(MeshBuilder *m) {
  m.material = 0;
  simd_float3 green = Hex(0x2c3a30), black = Hex(0x141414);
  Post(m, 0, 0, 0, 2.9f, 0.05f, 0.045f, green, 8);
  Box(m, (simd_float3){-0.13f, 2.2f, -0.1f}, (simd_float3){0.13f, 2.85f, 0.12f}, black);
  Disc(m, (simd_float3){0, 2.66f, 0.125f}, (simd_float3){0, 0, 1}, 0.09f, Hex(0xd8261c), 12);
  Disc(m, (simd_float3){0, 2.4f, 0.125f}, (simd_float3){0, 0, 1}, 0.09f, Hex(0x1c2a20), 12);
}

/// An inverted U of steel tube (arceau) across x.
static void BikeRack(MeshBuilder *m) {
  m.material = 0;
  simd_float3 steel = Hex(0x3c4a3e);
  Rod(m, (simd_float3){-0.35f, 0, 0}, (simd_float3){-0.35f, 0.6f, 0}, 0.03f, steel);
  Rod(m, (simd_float3){0.35f, 0, 0}, (simd_float3){0.35f, 0.6f, 0}, 0.03f, steel);
  Hoop(m, (simd_float3){0, 0.6f, 0}, (simd_float3){0, 0, 1}, 0.35f, 0.03f, steel, 8, 0, 3.1416f);
}

/// A litter bin: a hoop on a post holding a translucent green bag.
static void Bin(MeshBuilder *m) {
  m.material = 0;
  simd_float3 green = Hex(0x2c4a34), bag = Hex(0x7d9a7a);
  Post(m, 0, -0.22f, 0, 1.0f, 0.03f, 0.03f, green, 8);
  Hoop(m, (simd_float3){0, 0.92f, 0}, kUp, 0.22f, 0.012f, green, 14, 0, 6.2832f);
  [m tubeFrom:(simd_float3){0, 0.35f, 0} to:(simd_float3){0, 0.92f, 0} r0:0.17f r1:0.22f segments:12 color:bag toColor:bag * 1.1f vScale:1];
  Disc(m, (simd_float3){0, 0.35f, 0}, (simd_float3){0, -1, 0}, 0.17f, bag * 0.8f, 12);
}

/// A terrace heater: a pole and a reflector.
static void Heater(MeshBuilder *m) {
  m.material = 0;
  simd_float3 steel = Hex(0x9c9fa2), dark = Hex(0x2a2b2d);
  Post(m, 0, 0, 0, 0.08f, 0.25f, 0.23f, dark, 12);
  Post(m, 0, 0, 0.08f, 2.1f, 0.04f, 0.04f, steel, 8);
  [m tubeFrom:(simd_float3){0, 2.1f, 0} to:(simd_float3){0, 2.25f, 0} r0:0.08f r1:0.4f segments:14 color:steel toColor:steel vScale:1];
}

/// A café's chalk menu board (A-frame), facing ±z.
static void MenuBoard(MeshBuilder *m) {
  m.material = 0;
  simd_float3 slate = Hex(0x262826), wood = Hex(0x6a4a30), chalk = Hex(0xc8c8c0);
  for (int s = -1; s <= 1; s += 2) {
    simd_float3 bottom = {0, 0, s * 0.3f}, top = {0, 1.0f, s * 0.04f}, n = simd_normalize((simd_float3){0, 0.3f, (float)s});
    simd_float3 x = {0.3f, 0, 0};
    [m quadA:bottom - x b:bottom + x c:top + x d:top - x normal:n color:wood];
    simd_float3 inset = n * 0.006f, dz = (top - bottom);
    [m quadA:bottom - x * 0.85f + dz * 0.08f + inset b:bottom + x * 0.85f + dz * 0.08f + inset c:top + x * 0.85f - dz * 0.08f + inset
           d:top - x * 0.85f - dz * 0.08f + inset normal:n color:slate];
    for (int l = 0; l < 5; l++) {  // lines of chalk
      float t = 0.25f + l * 0.12f, w = 0.18f + 0.07f * ((l * 37) % 5) / 5.0f;
      simd_float3 c = bottom + dz * t + inset * 2;
      [m quadA:c - x * w / 0.3f b:c + x * w / 0.3f c:c + x * w / 0.3f + dz * 0.025f d:c - x * w / 0.3f + dz * 0.025f normal:n color:chalk];
    }
  }
}

float PropLength(PropKind kind) {
  switch (kind) {
    case PropCarHatch: return kCars[0].length;
    case PropCarSedan: return kCars[1].length;
    case PropCarSUV: return kCars[2].length;
    case PropCarVan: return kCars[3].length;
    case PropCarMicro: return kCars[4].length;
    case PropScooter: return 1.7f;
    case PropBicycle: return 1.75f;
    default: return 1;
  }
}

NSData *PropMesh(PropKind kind) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:(uint32_t)(301 + kind)];
  switch (kind) {
    case PropLamp: Lamp(m); break;
    case PropCarHatch: Car(m, &kCars[0]); break;
    case PropCarSedan: Car(m, &kCars[1]); break;
    case PropCarSUV: Car(m, &kCars[2]); break;
    case PropCarVan: Car(m, &kCars[3]); break;
    case PropCarMicro: Car(m, &kCars[4]); break;
    case PropScooter: Scooter(m); break;
    case PropBicycle: Bicycle(m); break;
    case PropTable: Table(m); break;
    case PropChair: Chair(m); break;
    case PropColumn: Column(m); break;
    case PropGrate: Grate(m); break;
    case PropBollard: Bollard(m); break;
    case PropSignNoParking: Sign(m, YES); break;
    case PropSignOneWay: Sign(m, NO); break;
    case PropCrossingLight: CrossingLight(m); break;
    case PropBikeRack: BikeRack(m); break;
    case PropBench: return BenchMesh();
    case PropBin: Bin(m); break;
    case PropHeater: Heater(m); break;
    case PropMenuBoard: MenuBoard(m); break;
    case PropKindCount: break;
  }
  return m.data;
}
