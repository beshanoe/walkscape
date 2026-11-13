#import "MedievalTown.h"

#import "Plants.h"
#import "SceneUtil.h"

#pragma mark - The plan

enum { kMaxLots = 14, kMaxStalls = 14, kMaxLanterns = 16, kMaxLines = 4, kMaxLights = kMaxLanterns + kMaxStalls };
static const float kPier = 0.45f;        // a bridge's arch springs this far in front of the facades
static const float kReturnDepth = 8.0f;  // how deep the houses' side walls go
static const float kArmY = 3.62f;        // a wall lantern's arm
static const float kArmReach = 0.62f;

enum { kRoofEaves, kRoofGable, kRoofHip };
enum { kStallHerbs, kStallProduce, kStallBread, kStallCloth, kStallPots, kStallKinds };

typedef struct {
  float z0, z1;
  int storeys;
  float ground, upper;  // storey heights
  float offset;         // the ground storey's face, metres into the wall (negative: into the street)
  float jetty;          // each upper storey stands this much further out
  BOOL tower;
  int roof;
  uint32_t seed;
  float course, tone;   // ashlar course height, stone tone 0…1
  float winW, winH;
  BOOL arched;
  float pilaster;  // width of the piers at both ends (0: none)
  BOOL bigArch;    // a deep arch over the two lowest storeys
  int bayK0, bayK1;  // storeys of a bay window on corbels (bayK1 < bayK0: none)
  float bayZ0, bayZ1, bayDepth;
  int timberFrom;  // storeys from this one up are half-timbered
} Lot;

typedef struct {
  BOOL present;
  int type;  // 0: an arch with a parapet on top; 1: a covered passage high up
  float z0, z1, spring, top;
  uint32_t seed;
} Bridge;

typedef struct {
  int side, lot;
  float z0, z1, depth;
  int kind;
  uint32_t seed;
  BOOL lantern;
  simd_float3 lanternAt;  // street space
} Stall;

typedef struct {
  int side;
  float z;
} WallLantern;

typedef struct {
  float z0, z1;  // where it meets the left and right facades
  float y0, y1;
  uint32_t seed;
} Line;

typedef struct {
  Lot lots[2][kMaxLots];
  int lotCount[2];
  Bridge bridge;
  Stall stalls[kMaxStalls];
  int stallCount;
  WallLantern lanterns[kMaxLanterns];
  int lanternCount;
  Line lines[kMaxLines];
  int lineCount;
} Plan;

static inline float RF(Rng *r, double lo, double hi) {
  return (float)Range(r, lo, hi);
}

static float StoreyY(const Lot *lot, int k) {
  return k <= 0 ? 0 : lot->ground + (float)(k - 1) * lot->upper;
}

static float LotTop(const Lot *lot) {
  return StoreyY(lot, lot->storeys);
}

/// Storey k's face, metres into the wall from the street line.
static float FaceDepth(const Lot *lot, int k) {
  return k <= 0 ? lot->offset : fmaxf(lot->offset - lot->jetty * (float)k, -1.2f);
}

static int StoreyAt(const Lot *lot, float y) {
  for (int k = lot->storeys - 1; k > 0; k--) {
    if (y >= StoreyY(lot, k)) return k;
  }
  return 0;
}

static int LotIndexAt(const Plan *P, int side, float z) {
  for (int i = 0; i < P->lotCount[side]; i++) {
    if (z < P->lots[side][i].z1) return i;
  }
  return P->lotCount[side] - 1;
}

static BOOL NearBridge(const Plan *P, float z0, float z1, float margin) {
  return P->bridge.present && z1 > P->bridge.z0 - margin && z0 < P->bridge.z1 + margin;
}

static float StallDepth(const TownLayout *L) {
  return fminf(1.5f, L->halfWidth - 1.3f);
}

/// The centre of a wall lantern's glass, in wall space (d, y).
static simd_float2 WallLanternCentre(float face) {
  return (simd_float2){face - kArmReach, kArmY - 0.38f};
}

static void MakePlan(const TownLayout *L, int64_t seg, Plan *P) {
  memset(P, 0, sizeof *P);
  float hw = L->halfWidth;
  Rng r = RngFor(L->seed, seg, 0, 71);
  Bridge *b = &P->bridge;
  if (Rand(&r) < L->bridges) {
    b->present = YES;
    b->type = Rand(&r) < 0.55 ? 0 : 1;
    float t = b->type == 0 ? RF(&r, 2.2, 3.6) : RF(&r, 3.2, 5.0);
    b->z0 = RF(&r, 9, kTownSegment - 9 - t);
    b->z1 = b->z0 + t;
    float a = hw - kPier;
    b->spring = b->type == 0 ? RF(&r, 2.6, 3.3) : RF(&r, 6.5, 9.5);
    b->top = b->spring + a + (b->type == 0 ? RF(&r, 1.6, 3.4) : RF(&r, 3.6, 4.4));
    b->seed = (uint32_t)(Rand(&r) * 65535);
  }
  for (int side = 0; side < 2; side++) {
    Rng rs = RngFor(L->seed, seg, side + 1, 72);
    float z = 0;
    int n = 0;
    while (z < kTownSegment - 0.01f && n < kMaxLots) {
      float w = RF(&rs, 4.6, 9.0);
      if (kTownSegment - (z + w) < 3.8f || n == kMaxLots - 1) w = kTownSegment - z;
      Lot *lot = &P->lots[side][n++];
      lot->z0 = z;
      lot->z1 = z + w;
      lot->seed = (uint32_t)(Rand(&rs) * 65535);
      lot->tower = w < 7.0f && Rand(&rs) < 0.08;
      int dS = (int)floor(Range(&rs, -1, 1.99));
      lot->storeys = lot->tower ? L->storeys + 3 + (Rand(&rs) < 0.5) : MAX(2, L->storeys + dS);
      lot->ground = RF(&rs, 4.3, 4.9);
      lot->upper = RF(&rs, 3.0, 3.5);
      lot->offset = RF(&rs, -0.15, 0.35);
      lot->jetty = Rand(&rs) < 0.6 ? RF(&rs, 0.18, 0.34) : 0;
      if (lot->tower || NearBridge(P, lot->z0, lot->z1, 0.3f)) lot->jetty = 0;
      lot->roof = lot->tower ? kRoofHip : (w < 7.0f && Rand(&rs) < 0.45) ? kRoofGable : kRoofEaves;
      lot->course = RF(&rs, 0.27, 0.4);
      lot->tone = (float)Rand(&rs);
      lot->winW = RF(&rs, 0.72, 1.0);
      lot->winH = RF(&rs, 1.35, 1.75);
      lot->arched = Rand(&rs) < 0.6;
      lot->pilaster = (lot->jetty == 0 && !lot->tower && Rand(&rs) < 0.55) ? RF(&rs, 0.38, 0.55) : 0;
      lot->bigArch = !lot->tower && w >= 5.2f && lot->storeys >= 3 && Rand(&rs) < 0.3;
      if (lot->bigArch) lot->jetty = 0;
      lot->bayK0 = 1;
      lot->bayK1 = 0;
      float bw = fminf(w - 2 * lot->pilaster - 0.8f, RF(&rs, 2.0, 3.2));
      int k0 = lot->bigArch ? 2 : 1 + (int)(Rand(&rs) * 2);
      if (lot->jetty == 0 && !lot->tower && Rand(&rs) < 0.45 && bw >= 1.6f && k0 <= lot->storeys - 2) {
        lot->bayK0 = k0;
        lot->bayK1 = MIN(k0 + (Rand(&rs) < 0.5 ? 1 : 0), lot->storeys - 2);
        lot->bayZ0 = z + (w - bw) * RF(&rs, 0.3, 0.7);
        lot->bayZ1 = lot->bayZ0 + bw;
        lot->bayDepth = RF(&rs, 0.55, 0.85);
      }
      lot->timberFrom = 99;
      if (!lot->tower && lot->pilaster == 0 && lot->storeys >= 3 && Rand(&rs) < 0.4) {
        lot->timberFrom = MAX(MAX(lot->storeys - 1 - (Rand(&rs) < 0.5), 2), lot->bayK1 + 1);
        if (lot->jetty == 0 && !NearBridge(P, lot->z0, lot->z1, 0.3f)) lot->jetty = RF(&rs, 0.12, 0.22);
      }
      z += w;
    }
    P->lotCount[side] = n;
  }
  // Stalls in front of the houses.
  float D = StallDepth(L);
  for (int side = 0; side < 2 && D > 0.6f; side++) {
    Rng rs = RngFor(L->seed, seg, side + 1, 73);
    for (int i = 0; i < P->lotCount[side]; i++) {
      const Lot *lot = &P->lots[side][i];
      float W = lot->z1 - lot->z0;
      double pick = Rand(&rs);
      float room = W - 2 * lot->pilaster;
      float sw = fminf(room - 0.5f, RF(&rs, 2.4, 3.8));
      float z0 = lot->z0 + lot->pilaster + 0.25f + (float)Rand(&rs) * fmaxf(room - sw - 0.5f, 0);
      int kind = (int)(Rand(&rs) * kStallKinds);
      uint32_t seed = (uint32_t)(Rand(&rs) * 65535);
      BOOL lantern = Rand(&rs) < 0.5;
      if (room < 3.0f || pick >= L->market || P->stallCount >= kMaxStalls || NearBridge(P, z0, z0 + sw, 1.2f)) continue;
      Stall *st = &P->stalls[P->stallCount++];
      *st = (Stall){side, i, z0, z0 + sw, D, kind, seed, lantern, 0};
      float sgn = side ? 1 : -1, frontH = 2.15f + 0.15f * SceneHashF(seed, 1u);
      st->lanternAt = (simd_float3){sgn * (hw + FaceDepth(lot, 0) - D + 0.04f), frontH - 0.12f - 0.12f - 0.28f, z0 + sw * 0.3f};
    }
  }
  // Wall lanterns.
  for (int side = 0; side < 2; side++) {
    Rng rl = RngFor(L->seed, seg, side + 1, 74);
    float z = RF(&rl, 1.5, 9.0);
    while (z < kTownSegment - 1 && P->lanternCount < kMaxLanterns) {
      const Lot *lot = &P->lots[side][LotIndexAt(P, side, z)];
      if (!NearBridge(P, z, z, 1.5f) && z > lot->z0 + lot->pilaster + 0.25f && z < lot->z1 - lot->pilaster - 0.25f) P->lanterns[P->lanternCount++] = (WallLantern){side, z};
      z += RF(&rl, 9, 16);
    }
  }
  // Washing lines across the street.
  Rng rw = RngFor(L->seed, seg, 0, 75);
  int lines = (int)floor(L->laundry * 4.0 + Rand(&rw) * 0.999);
  for (int i = 0; i < lines && i < kMaxLines; i++) {
    float z = RF(&rw, 3, kTownSegment - 3), dz = RF(&rw, -1.2, 1.2);
    float y0 = RF(&rw, 4.8, 8.5), y1 = y0 + RF(&rw, -0.8, 0.8);
    uint32_t seed = (uint32_t)(Rand(&rw) * 65535);
    float z1 = fminf(fmaxf(z + dz, 0.5f), kTownSegment - 0.5f);
    if (NearBridge(P, fminf(z, z1), fmaxf(z, z1), 1.0f)) continue;
    const Lot *la = &P->lots[0][LotIndexAt(P, 0, z)], *lb = &P->lots[1][LotIndexAt(P, 1, z1)];
    y0 = fminf(y0, LotTop(la) - 1.2f);
    y1 = fminf(y1, LotTop(lb) - 1.2f);
    if (y0 < 4.8f || y1 < 4.8f) continue;
    P->lines[P->lineCount++] = (Line){z, z1, y0, y1, seed};
  }
}

float TownRoofHeight(const TownLayout *L) {
  return 4.6f + (float)(L->storeys - 1) * 3.25f + 1.0f;
}

int TownSegmentLights(const TownLayout *L, int64_t segment, TownLight *out, int max) {
  Plan P;
  MakePlan(L, segment, &P);
  int n = 0;
  for (int i = 0; i < P.lanternCount && n < max; i++) {
    const WallLantern *wl = &P.lanterns[i];
    const Lot *lot = &P.lots[wl->side][LotIndexAt(&P, wl->side, wl->z)];
    simd_float2 c = WallLanternCentre(FaceDepth(lot, 0));
    out[n++] = (TownLight){{(wl->side ? 1 : -1) * (L->halfWidth + c.x), c.y, wl->z}, 1.0f};
  }
  for (int i = 0; i < P.stallCount && n < max; i++) {
    if (P.stalls[i].lantern) out[n++] = (TownLight){P.stalls[i].lanternAt, 0.7f};
  }
  return n;
}

#pragma mark - Mesh helpers

/// Wall space: d metres into the wall from the street line (negative: into the street), y up,
/// z along; `side` −1 for the left facades (s < 0), +1 for the right.
typedef struct {
  __unsafe_unretained MeshBuilder *m;
  float side;
  float hw;
  BOOL timber;  // faces half-timbered (kTownTimber), reveals wood
  float uy;     // faces' uv.y = y - uy
} Wall;

static const uint32_t kOak = 0x3e3024;

static inline simd_float3 WP(const Wall *w, float d, float y, float z) {
  return (simd_float3){w->side * (w->hw + d), y, z};
}

/// A wall-space direction in street space.
static inline simd_float3 WN(const Wall *w, float d, float y, float z) {
  return simd_normalize((simd_float3){w->side * d, y, z});
}

static inline simd_float2 V2(float a, float b) {
  return (simd_float2){a, b};
}

static void Q(MeshBuilder *m, simd_float3 a, simd_float3 b, simd_float3 c, simd_float3 d, simd_float3 n, simd_float3 col, simd_float2 ta,
              simd_float2 tb, simd_float2 tc, simd_float2 td) {
  [m quadA:a b:b c:c d:d normal:n color:col uvA:ta uvB:tb uvC:tc uvD:td];
}

static void Tri(MeshBuilder *m, simd_float3 a, simd_float3 b, simd_float3 c, simd_float3 n, simd_float3 col, simd_float2 ta, simd_float2 tb,
                simd_float2 tc) {
  [m vertex:a normal:n color:col uv:ta];
  [m vertex:b normal:n color:col uv:tb];
  [m vertex:c normal:n color:col uv:tc];
}

/// An axis-aligned box in street space, uv in metres: on vertical faces (along, up), on
/// horizontal ones (z, s). `grain`: uv.x along the box's longest side wherever that lies in a
/// face (wood). A box standing on the street has no bottom (it would fight the cobbles' depth).
static void SBox(MeshBuilder *m, simd_float3 lo, simd_float3 hi, simd_float3 col, BOOL grain) {
  simd_float3 e = hi - lo;
  int longest = e.x >= e.y && e.x >= e.z ? 0 : e.y >= e.z ? 1 : 2;
  for (int axis = 0; axis < 3; axis++) {
    int ua = axis == 2 ? 0 : 2, va = axis == 1 ? 0 : 1;
    if (grain && va == longest) {
      int t = ua;
      ua = va;
      va = t;
    }
    for (int s = 0; s < 2; s++) {
      if (axis == 1 && s == 0 && lo.y < 0.005f) continue;
      simd_float3 n = 0;
      n[axis] = s ? 1 : -1;
      float us[4] = {lo[ua], hi[ua], hi[ua], lo[ua]}, vs[4] = {lo[va], lo[va], hi[va], hi[va]};
      simd_float3 p[4];
      for (int i = 0; i < 4; i++) {
        simd_float3 q = 0;
        q[axis] = s ? hi[axis] : lo[axis];
        q[ua] = us[i];
        q[va] = vs[i];
        p[i] = q;
      }
      Q(m, p[0], p[1], p[2], p[3], n, col, V2(us[0], vs[0]), V2(us[1], vs[1]), V2(us[2], vs[2]), V2(us[3], vs[3]));
    }
  }
}

/// A box in wall space (d0 < d1).
static void WBox(const Wall *w, float d0, float d1, float y0, float y1, float z0, float z1, simd_float3 col, BOOL grain) {
  simd_float3 a = WP(w, d0, y0, z0), b = WP(w, d1, y1, z1);
  SBox(w->m, simd_min(a, b), simd_max(a, b), col, grain);
}

/// A flat disc facing up.
static void Disc(MeshBuilder *m, simd_float3 c, float r, int n, simd_float3 col) {
  for (int i = 0; i < n; i++) {
    float a0 = 2 * (float)M_PI * i / n, a1 = 2 * (float)M_PI * (i + 1) / n;
    simd_float3 p0 = c + (simd_float3){r * cosf(a0), 0, r * sinf(a0)}, p1 = c + (simd_float3){r * cosf(a1), 0, r * sinf(a1)};
    Tri(m, c, p0, p1, (simd_float3){0, 1, 0}, col, V2(0, 0), V2(r * cosf(a0), r * sinf(a0)), V2(r * cosf(a1), r * sinf(a1)));
  }
}

/// A stone face toward the street at depth d.
static void Face(const Wall *w, float d, float z0, float z1, float y0, float y1, simd_float3 col) {
  if (z1 - z0 < 1e-4f || y1 - y0 < 1e-4f) return;
  w->m.material = w->timber ? kTownTimber : kTownStone;
  float u = w->uy;
  Q(w->m, WP(w, d, y0, z0), WP(w, d, y0, z1), WP(w, d, y1, z1), WP(w, d, y1, z0), WN(w, -1, 0, 0), col, V2(z0, y0 - u), V2(z1, y0 - u),
    V2(z1, y1 - u), V2(z0, y1 - u));
}

#pragma mark - Openings

enum { kFillGlass, kFillShutters, kFillDoor, kFillRecess, kFillDeep };

typedef struct {
  float z0, z1, y0, y1;  // y1: where the head starts (the springing of an arch)
  float rise;            // the arch's rise above y1 (0: a flat lintel)
  float depth;
  int fill;
  BOOL balcony;
  uint32_t seed;
} Opening;

/// The head's height at z.
static float ArchY(const Opening *o, float z) {
  if (o->rise <= 0) return o->y1;
  float h = (o->z1 - o->z0) / 2, zc = (o->z0 + o->z1) / 2;
  float R = (h * h + o->rise * o->rise) / (2 * o->rise), yc = o->y1 + o->rise - R, dz = z - zc;
  return yc + sqrtf(fmaxf(R * R - dz * dz, 0));
}

/// The intrados's normal at z, (along, up), toward the arch's centre.
static simd_float2 ArchNormal(const Opening *o, float z) {
  float h = (o->z1 - o->z0) / 2, zc = (o->z0 + o->z1) / 2;
  float R = (h * h + o->rise * o->rise) / (2 * o->rise), yc = o->y1 + o->rise - R;
  return simd_normalize((simd_float2){zc - z, yc - ArchY(o, z)});
}

static float ArchZ(const Opening *o, int k, int n) {
  // Denser toward the springings, where the curve is steep.
  float t = 0.5f - 0.5f * cosf((float)M_PI * (float)k / (float)n);
  return o->z0 + (o->z1 - o->z0) * t;
}

/// A band of wall from ya to yb at depth f with the openings cut out (sorted, inside the band).
static void Band(const Wall *w, float f, float za, float zb, float ya, float yb, simd_float3 col, const Opening *ops, int n) {
  float z = za, u = w->uy;
  for (int i = 0; i < n; i++) {
    const Opening *o = &ops[i];
    Face(w, f, z, o->z0, ya, yb, col);
    if (o->y0 > ya + 1e-3f) Face(w, f, o->z0, o->z1, ya, o->y0, col);
    if (o->rise <= 0) {
      Face(w, f, o->z0, o->z1, o->y1, yb, col);
    } else {
      const int N = 8;
      for (int k = 0; k < N; k++) {
        float a = ArchZ(o, k, N), b = ArchZ(o, k + 1, N), ha = ArchY(o, a), hb = ArchY(o, b);
        w->m.material = w->timber ? kTownTimber : kTownStone;
        Q(w->m, WP(w, f, ha, a), WP(w, f, hb, b), WP(w, f, yb, b), WP(w, f, yb, a), WN(w, -1, 0, 0), col, V2(a, ha - u), V2(b, hb - u), V2(b, yb - u),
          V2(a, yb - u));
      }
    }
    z = o->z1;
  }
  Face(w, f, z, zb, ya, yb, col);
}

/// An opening's reveals, head and what fills it.
static void Inside(const Wall *w, float f, const Opening *o, simd_float3 stone) {
  MeshBuilder *m = w->m;
  float d1 = f + o->depth;
  m.material = w->timber ? kTownWood : kTownStone;
  if (w->timber) stone = Hex(kOak);
  Q(m, WP(w, f, o->y0, o->z0), WP(w, d1, o->y0, o->z0), WP(w, d1, o->y1, o->z0), WP(w, f, o->y1, o->z0), (simd_float3){0, 0, 1}, stone,
    V2(o->z0 + f, o->y0), V2(o->z0 + d1, o->y0), V2(o->z0 + d1, o->y1), V2(o->z0 + f, o->y1));
  Q(m, WP(w, f, o->y0, o->z1), WP(w, d1, o->y0, o->z1), WP(w, d1, o->y1, o->z1), WP(w, f, o->y1, o->z1), (simd_float3){0, 0, -1}, stone,
    V2(o->z1 - f, o->y0), V2(o->z1 - d1, o->y0), V2(o->z1 - d1, o->y1), V2(o->z1 - f, o->y1));
  if (o->fill == kFillGlass || o->fill == kFillShutters) {
    Q(m, WP(w, f, o->y0, o->z0), WP(w, f, o->y0, o->z1), WP(w, d1, o->y0, o->z1), WP(w, d1, o->y0, o->z0), (simd_float3){0, 1, 0}, stone,
      V2(o->z0, f), V2(o->z1, f), V2(o->z1, d1), V2(o->z0, d1));
  }
  if (o->rise <= 0) {
    Q(m, WP(w, f, o->y1, o->z0), WP(w, f, o->y1, o->z1), WP(w, d1, o->y1, o->z1), WP(w, d1, o->y1, o->z0), (simd_float3){0, -1, 0}, stone,
      V2(o->z0, f), V2(o->z1, f), V2(o->z1, d1), V2(o->z0, d1));
  } else {
    const int N = 8;
    float arc = 0;
    m.material = w->timber ? kTownWood : kTownStone;
    for (int k = 0; k < N; k++) {
      float a = ArchZ(o, k, N), b = ArchZ(o, k + 1, N), ha = ArchY(o, a), hb = ArchY(o, b);
      simd_float2 an = ArchNormal(o, (a + b) / 2);
      float len = simd_length((simd_float2){b - a, hb - ha});
      Q(m, WP(w, f, ha, a), WP(w, f, hb, b), WP(w, d1, hb, b), WP(w, d1, ha, a), (simd_float3){0, an.y, an.x}, stone, V2(arc, f),
        V2(arc + len, f), V2(arc + len, d1), V2(arc, d1));
      arc += len;
    }
  }
  float top = o->y1 + o->rise, vt = (top - o->y0) / fmaxf(o->y1 - o->y0, 0.01f);
  if (o->fill == kFillDeep) return;
  if (o->fill == kFillRecess) {
    m.material = kTownRecess;
    Q(m, WP(w, d1, o->y0, o->z0), WP(w, d1, o->y0, o->z1), WP(w, d1, top, o->z1), WP(w, d1, top, o->z0), WN(w, -1, 0, 0), 0, V2(o->z0, o->y0),
      V2(o->z1, o->y0), V2(o->z1, top), V2(o->z0, top));
    Q(m, WP(w, f, 0.01f, o->z0), WP(w, f, 0.01f, o->z1), WP(w, d1, 0.01f, o->z1), WP(w, d1, 0.01f, o->z0), (simd_float3){0, 1, 0}, 0,
      V2(o->z0, f), V2(o->z1, f), V2(o->z1, d1), V2(o->z0, d1));
    return;
  }
  m.material = o->fill == kFillDoor ? kTownDoor : kTownWindow;
  simd_float3 c = {(float)(o->seed & 0xFFFF), o->rise / fmaxf(o->y1 - o->y0, 0.01f), o->fill == kFillShutters ? 1 : 0};
  Q(m, WP(w, d1, o->y0, o->z0), WP(w, d1, o->y0, o->z1), WP(w, d1, top, o->z1), WP(w, d1, top, o->z0), WN(w, -1, 0, 0), c, V2(0, 0), V2(1, 0),
    V2(1, vt), V2(0, vt));
}

/// The openings of a storey, sorted along z.
static BOOL HasBay(const Lot *lot, int k) {
  return k >= lot->bayK0 && k <= lot->bayK1;
}

/// The deep arch over the two lowest storeys.
static Opening BigArch(const Lot *lot) {
  float m = fmaxf(lot->pilaster, 0.55f) + 0.15f, z0 = lot->z0 + m, z1 = lot->z1 - m, rise = (z1 - z0) / 2;
  return (Opening){z0, z1, 0, StoreyY(lot, 2) - 0.55f - rise, rise, 1.3f, kFillDeep, NO, SceneHash(lot->seed, 150u) & 0xFFFF};
}

static int StoreyOpenings(const Lot *lot, int k, Opening *ops) {
  float za = lot->z0 + lot->pilaster, zb = lot->z1 - lot->pilaster;
  float W = zb - za, ya = StoreyY(lot, k), yb = StoreyY(lot, k + 1);
  if (lot->bigArch && k <= 1) {
    if (k == 1) return 0;
    ops[0] = BigArch(lot);
    return 1;
  }
  uint32_t h = SceneHash(lot->seed, 100u + (uint32_t)k);
  int n = 0;
  if (k == 0) {
    const float door = 1.1f;
    Opening dr = {.y0 = 0, .y1 = 2.05f, .rise = door / 2, .depth = 0.3f, .fill = kFillDoor, .seed = h & 0xFFFF};
    if (W >= 4.4f && h % 5 != 0) {
      float ow = fminf(W - 2.1f, 2.3f + SceneHashF(lot->seed, 101u) * 1.0f);
      Opening arch = {.y0 = 0, .y1 = 2.1f, .rise = fminf(ow / 2, 1.35f), .depth = 0.85f, .fill = kFillRecess, .seed = h & 0xFFFF};
      float spare = W - ow - door, pL = spare * (0.2f + 0.2f * SceneHashF(lot->seed, 102u)), pM = spare * 0.35f;
      Opening *first = (h >> 3) & 1 ? &dr : &arch, *second = first == &dr ? &arch : &dr;
      float w1 = first == &dr ? door : ow, w2 = second == &dr ? door : ow;
      first->z0 = za + pL;
      first->z1 = first->z0 + w1;
      second->z0 = first->z1 + pM;
      second->z1 = second->z0 + w2;
      ops[n++] = *first;
      ops[n++] = *second;
    } else {
      dr.z0 = za + (W - door) * (0.25f + 0.5f * SceneHashF(lot->seed, 103u));
      dr.z1 = dr.z0 + door;
      ops[n++] = dr;
    }
    return n;
  }
  if (lot->tower) {
    float zc = (lot->z0 + lot->z1) / 2;
    ops[n++] = (Opening){zc - 0.22f, zc + 0.22f, ya + 1.0f, ya + 1.85f, 0.22f, 0.45f, kFillGlass, NO, h & 0xFFFF};
    return n;
  }
  int count = (int)fminf(fmaxf(floorf((W - 0.5f) / 1.8f), 1), 4);
  float pitch = W / (float)count, rise = lot->arched ? lot->winW / 2 : 0;
  for (int i = 0; i < count; i++) {
    uint32_t hw = SceneHash(lot->seed, 200u + (uint32_t)(k * 8 + i));
    float zc = za + pitch * ((float)i + 0.5f);
    if (HasBay(lot, k) && zc + lot->winW / 2 > lot->bayZ0 - 0.15f && zc - lot->winW / 2 < lot->bayZ1 + 0.15f) continue;
    Opening o = {zc - lot->winW / 2, zc + lot->winW / 2, ya + 0.9f, ya + 0.9f + lot->winH - rise, rise, 0.22f, kFillGlass, NO, hw & 0xFFFF};
    if (hw % 4 == 0) o.fill = kFillShutters;
    if (k >= 2 && (hw >> 4) % 7 == 0) {  // a door onto a balcony
      o.balcony = YES;
      o.y0 = ya + 0.02f;
      o.y1 = ya + 2.15f - rise;
      o.fill = kFillGlass;
    }
    if (o.y1 + o.rise > yb - 0.3f) o.y1 = yb - 0.3f - o.rise;
    ops[n++] = o;
  }
  return n;
}

#pragma mark - Houses

static void Balcony(const Wall *w, float f, float y, float z0, float z1, simd_float3 stone) {
  MeshBuilder *m = w->m;
  m.material = kTownStone;
  WBox(w, f - 0.62f, f, y - 0.16f, y, z0, z1, stone, NO);
  for (int i = 0; i < 2; i++) {
    float zc = i ? z1 - 0.2f : z0 + 0.2f;
    WBox(w, f - 0.5f, f, y - 0.4f, y - 0.161f, zc - 0.09f, zc + 0.09f, stone, NO);
    WBox(w, f - 0.28f, f, y - 0.62f, y - 0.4f, zc - 0.08f, zc + 0.08f, stone, NO);
  }
  m.material = kTownIron;
  simd_float3 iron = {0.03f, 0.028f, 0.026f};
  float dR = f - 0.58f;
  WBox(w, dR - 0.02f, dR + 0.02f, y + 0.92f, y + 0.96f, z0 + 0.02f, z1 - 0.02f, iron, NO);
  WBox(w, dR - 0.015f, dR + 0.015f, y + 0.08f, y + 0.11f, z0 + 0.02f, z1 - 0.02f, iron, NO);
  for (int i = 0; i < 2; i++) {
    float z = i ? z1 - 0.06f : z0 + 0.02f;
    WBox(w, dR, f, y + 0.92f, y + 0.96f, z, z + 0.04f, iron, NO);
    for (float d = dR + 0.12f; d < f - 0.05f; d += 0.12f) WBox(w, d - 0.008f, d + 0.008f, y, y + 0.92f, z + 0.012f, z + 0.028f, iron, NO);
  }
  for (float z = z0 + 0.08f; z < z1 - 0.05f; z += 0.12f) WBox(w, dR - 0.008f, dR + 0.008f, y, y + 0.92f, z, z + 0.016f, iron, NO);
}

/// A carved panel in a moulded frame.
static void Relief(const Wall *w, float f, float zc, float y0, float width, float height, uint32_t seed, simd_float3 stone) {
  MeshBuilder *m = w->m;
  float z0 = zc - width / 2, z1 = zc + width / 2, y1 = y0 + height, b = 0.09f;
  m.material = kTownStone;
  WBox(w, f - 0.08f, f, y0 - b, y0, z0 - b, z1 + b, stone, NO);
  WBox(w, f - 0.08f, f, y1, y1 + b, z0 - b, z1 + b, stone, NO);
  WBox(w, f - 0.08f, f, y0, y1, z0 - b, z0, stone, NO);
  WBox(w, f - 0.08f, f, y0, y1, z1, z1 + b, stone, NO);
  m.material = kTownRelief;
  simd_float3 c = {(float)(seed & 0xFFFF), stone.z, w->side};
  float d = f - 0.012f;
  Q(m, WP(w, d, y0, z0), WP(w, d, y0, z1), WP(w, d, y1, z1), WP(w, d, y1, z0), WN(w, -1, 0, 0), c, V2(0, 0), V2(1, 0), V2(1, 1), V2(0, 1));
}

/// Ivy hanging down a house from `yTop`: strands of leaf cards.
static void Ivy(const Wall *w, MeshBuilder *cards, const Lot *lot, float zc, float yTop, float length, float width, Rng *r) {
  cards.material = kTownCard + kCellLeaves;
  int strands = MAX(3, (int)(width / 0.14f));
  simd_float3 out = WN(w, -1, 0, 0);
  for (int c = 0; c < strands; c++) {
    float across = ((float)c + 0.5f) / (float)strands - 0.5f;
    float z = zc + across * width + RF(r, -0.05, 0.05);
    float len = length * RF(r, 0.4, 1.0) * (1.0f - 0.6f * fabsf(across));
    for (float y = yTop; y > yTop - len && y > 0.4f; y -= RF(r, 0.12, 0.18)) {
     float f = FaceDepth(lot, StoreyAt(lot, y));
     for (int k = 0; k < 2; k++) {  // two cards crossed at each step: a mass of leaves
      float size = RF(r, 0.5, 0.8) * (0.65f + 0.35f * (y - (yTop - len)) / fmaxf(len, 0.1f));
      simd_float3 base = WP(w, f - 0.02f - RF(r, 0, 0.12), y + size * 0.4f, z + RF(r, -0.08, 0.08));
      float tilt = RF(r, 0.1, 0.6), phi = RF(r, -0.7, 0.7) + (float)k * 1.4f;
      simd_float3 across3 = {0, sinf(phi), cosf(phi)};
      simd_float3 down = simd_normalize(simd_cross(across3, out));
      if (down.y > 0) down = -down;
      simd_float3 along = simd_normalize(down * cosf(tilt) + out * sinf(tilt));
      simd_float3 n = simd_normalize(out * 0.8f + (simd_float3){0, 0.45f, 0});
      float occ = 0.45f + 0.55f * (float)Rand(r);
      [cards cardAt:base along:along across:across3 length:size width:size v0:1 v1:0 normal:n color:(simd_float3){occ, (float)Rand(r), 0}];
     }
    }
  }
}

static void Roof(const Wall *w, const Lot *lot, simd_float3 stone) {
  MeshBuilder *m = w->m;
  float top = LotTop(lot), ft = FaceDepth(lot, lot->storeys - 1), z0 = lot->z0, z1 = lot->z1, W = z1 - z0, zc = (z0 + z1) / 2;
  const float pitch = 1.2f;
  simd_float3 tiles = {(float)lot->seed, 0, 0};
  if (lot->roof == kRoofEaves) {
    float e = ft - 0.5f, run = 4.6f, ridge = top + (run + 0.5f) * pitch, back = ft + 2 * run + 0.5f, slope = (run + 0.5f) * 1.56f;
    m.material = kTownRoof;
    Q(m, WP(w, e, top - 0.02f, z0 - 0.04f), WP(w, e, top - 0.02f, z1 + 0.04f), WP(w, ft + run, ridge, z1 + 0.04f), WP(w, ft + run, ridge, z0 - 0.04f),
      WN(w, -pitch, 1, 0), tiles, V2(z0, 0), V2(z1, 0), V2(z1, slope), V2(z0, slope));
    Q(m, WP(w, ft + run, ridge, z0 - 0.04f), WP(w, ft + run, ridge, z1 + 0.04f), WP(w, back, top - 0.02f, z1 + 0.04f), WP(w, back, top - 0.02f, z0 - 0.04f),
      WN(w, pitch, 1, 0), tiles, V2(z0, slope), V2(z1, slope), V2(z1, 0), V2(z0, 0));
    m.material = kTownStone;
    for (int i = 0; i < 2; i++) {
      float z = i ? z1 : z0;
      Tri(m, WP(w, ft, top, z), WP(w, ft + run, ridge, z), WP(w, back - 0.5f, top, z), (simd_float3){0, 0, i ? 1.0f : -1.0f}, stone, V2(ft, top),
          V2(ft + run, ridge), V2(back, top));
    }
    if (SceneHashF(lot->seed, 400u) < 0.55f) {
      float cz = z0 + W * (0.2f + 0.6f * SceneHashF(lot->seed, 401u));
      WBox(w, ft + 1.4f, ft + 2.1f, top, ridge + 0.9f, cz - 0.35f, cz + 0.35f, stone, NO);
      WBox(w, ft + 1.33f, ft + 2.17f, ridge + 0.9f, ridge + 1.02f, cz - 0.42f, cz + 0.42f, stone, NO);
    }
  } else if (lot->roof == kRoofGable) {
    float ridge = top + W / 2 * pitch, over = 0.3f, eave = top - over * pitch, front = ft - 0.35f, back = ft + 9.0f;
    m.material = kTownStone;
    Tri(m, WP(w, ft, top, z0), WP(w, ft, top, z1), WP(w, ft, ridge, zc), WN(w, -1, 0, 0), stone, V2(z0, top), V2(z1, top), V2(zc, ridge));
    m.material = kTownRoof;
    float slope = (W / 2 + over) * 1.56f;
    Q(m, WP(w, front, ridge + 0.08f, zc), WP(w, back, ridge + 0.08f, zc), WP(w, back, eave, z0 - over), WP(w, front, eave, z0 - over),
      simd_normalize((simd_float3){0, 1, -pitch}), tiles, V2(front, slope), V2(back, slope), V2(back, 0), V2(front, 0));
    Q(m, WP(w, front, ridge + 0.08f, zc), WP(w, back, ridge + 0.08f, zc), WP(w, back, eave, z1 + over), WP(w, front, eave, z1 + over),
      simd_normalize((simd_float3){0, 1, pitch}), tiles, V2(front, slope), V2(back, slope), V2(back, 0), V2(front, 0));
    // A barge board along the verge.
    m.material = kTownWood;
    simd_float3 wood = Hex(0x4a3a2a);
    for (int i = 0; i < 2; i++) {
      float ze = i ? z1 + over : z0 - over;
      simd_float3 a = WP(w, front - 0.01f, eave, ze), b = WP(w, front - 0.01f, ridge + 0.08f, zc);
      simd_float3 a2 = a - (simd_float3){0, 0.22f, 0}, b2 = b - (simd_float3){0, 0.22f, 0};
      float len = simd_distance(a, b);
      Q(m, a2, b2, b, a, WN(w, -1, 0, 0), wood, V2(0, 0), V2(len, 0), V2(len, 0.22f), V2(0, 0.22f));
    }
  } else {
    float apexY = top + 6.5f;
    simd_float3 apex = WP(w, ft + 4.0f, apexY, zc);
    simd_float3 c[4] = {WP(w, ft - 0.3f, top, z0 - 0.3f), WP(w, ft - 0.3f, top, z1 + 0.3f), WP(w, ft + 8.3f, top, z1 + 0.3f), WP(w, ft + 8.3f, top, z0 - 0.3f)};
    m.material = kTownRoof;
    for (int i = 0; i < 4; i++) {
      simd_float3 a = c[i], b = c[(i + 1) % 4];
      simd_float3 n = simd_normalize(simd_cross(b - a, apex - a));
      if (n.y < 0) n = -n;
      float len = simd_distance(a, b), h = simd_distance((a + b) / 2, apex);
      Tri(m, a, b, apex, n, tiles, V2(0, 0), V2(len, 0), V2(len / 2, h));
    }
    m.material = kTownStone;
    WBox(w, ft + 3.9f, ft + 4.1f, apexY - 0.3f, apexY + 0.6f, zc - 0.05f, zc + 0.05f, (simd_float3){0.03f, 0.03f, 0.03f}, NO);
  }
}

/// A bay window standing out on corbels over one or two storeys, windows on its front, a sloping lid.
static void Bay(const Wall *w, const Lot *lot, simd_float3 stone) {
  MeshBuilder *m = w->m;
  float f = FaceDepth(lot, lot->bayK0), dB = f - lot->bayDepth, z0 = lot->bayZ0, z1 = lot->bayZ1, bw = z1 - z0;
  float y0 = StoreyY(lot, lot->bayK0), y1 = StoreyY(lot, lot->bayK1 + 1) - 0.3f;
  int count = MAX(1, (int)(bw / 1.15f));
  float pitch = bw / (float)count, ww = fminf(0.72f, pitch - 0.42f), rise = lot->arched ? ww / 2 : 0;
  for (int k = lot->bayK0; k <= lot->bayK1; k++) {
    float ya = StoreyY(lot, k), yb = k == lot->bayK1 ? y1 : StoreyY(lot, k + 1);
    Opening ops[4];
    int n = 0;
    for (int i = 0; i < count; i++) {
      float zc = z0 + pitch * ((float)i + 0.5f);
      uint32_t h = SceneHash(lot->seed, 600u + (uint32_t)(k * 8 + i));
      Opening o = {zc - ww / 2, zc + ww / 2, ya + 0.85f, ya + 0.85f + lot->winH - rise, rise, 0.18f, h % 5 == 0 ? kFillShutters : kFillGlass, NO, h & 0xFFFF};
      if (o.y1 + o.rise > yb - 0.25f) o.y1 = yb - 0.25f - o.rise;
      ops[n++] = o;
    }
    Band(w, dB, z0, z1, ya, yb, stone, ops, n);
    for (int i = 0; i < n; i++) {
      Inside(w, dB, &ops[i], stone);
      m.material = kTownStone;
      WBox(w, dB - 0.06f, dB, ops[i].y0 - 0.08f, ops[i].y0 + 0.01f, ops[i].z0 - 0.06f, ops[i].z1 + 0.06f, stone, NO);
    }
    if (k > lot->bayK0) WBox(w, dB - 0.07f, dB, ya - 0.04f, ya + 0.12f, z0, z1, stone, NO);
  }
  m.material = kTownStone;
  Q(m, WP(w, dB, y0, z0), WP(w, f, y0, z0), WP(w, f, y1, z0), WP(w, dB, y1, z0), (simd_float3){0, 0, -1}, stone, V2(dB, y0), V2(f, y0), V2(f, y1),
    V2(dB, y1));
  Q(m, WP(w, dB, y0, z1), WP(w, f, y0, z1), WP(w, f, y1, z1), WP(w, dB, y1, z1), (simd_float3){0, 0, 1}, stone, V2(dB, y0), V2(f, y0), V2(f, y1),
    V2(dB, y1));
  Q(m, WP(w, dB, y0, z0), WP(w, dB, y0, z1), WP(w, f, y0, z1), WP(w, f, y0, z0), (simd_float3){0, -1, 0}, stone, V2(z0, dB), V2(z1, dB), V2(z1, f),
    V2(z0, f));
  // A moulded base, stepped corbels under it, a cornice and a lid.
  WBox(w, dB - 0.07f, f, y0 - 0.16f, y0 + 0.08f, z0 - 0.07f, z1 + 0.07f, stone, NO);
  int corbels = MAX(2, (int)(bw / 0.8f) + 1);
  for (int i = 0; i < corbels; i++) {
    float zc = z0 + 0.15f + (bw - 0.3f) * (float)i / (float)(corbels - 1);
    WBox(w, dB + 0.02f, f, y0 - 0.42f, y0 - 0.16f, zc - 0.12f, zc + 0.12f, stone, NO);
    WBox(w, dB + 0.2f, f, y0 - 0.7f, y0 - 0.42f, zc - 0.1f, zc + 0.1f, stone, NO);
    WBox(w, dB + 0.4f, f, y0 - 0.95f, y0 - 0.7f, zc - 0.08f, zc + 0.08f, stone, NO);
  }
  WBox(w, dB - 0.14f, f, y1 - 0.02f, y1 + 0.16f, z0 - 0.1f, z1 + 0.1f, stone, NO);
  m.material = kTownRoof;
  simd_float3 tiles = {(float)lot->seed, 0, 0};
  float lift = lot->bayDepth * 0.7f;
  Q(m, WP(w, dB - 0.2f, y1 + 0.16f, z0 - 0.12f), WP(w, dB - 0.2f, y1 + 0.16f, z1 + 0.12f), WP(w, f, y1 + 0.16f + lift, z1 + 0.12f),
    WP(w, f, y1 + 0.16f + lift, z0 - 0.12f), WN(w, -0.7f, 1, 0), tiles, V2(z0, 0), V2(z1, 0), V2(z1, 1), V2(z0, 1));
}

/// A painted sign hanging from an iron bracket, its faces toward the street's length.
static void Sign(const Wall *w, float f, float z, uint32_t seed) {
  MeshBuilder *m = w->m;
  simd_float3 iron = {0.032f, 0.03f, 0.028f};
  const float y = 3.85f, reach = 1.0f;
  m.material = kTownIron;
  WBox(w, f - reach, f + 0.02f, y - 0.018f, y + 0.018f, z - 0.015f, z + 0.015f, iron, NO);
  [m tubeFrom:WP(w, f, y - 0.5f, z) to:WP(w, f - reach * 0.6f, y - 0.01f, z) r0:0.01f r1:0.01f segments:4 color:iron toColor:iron vScale:1];
  WBox(w, f - 0.025f, f + 0.01f, y - 0.58f, y + 0.06f, z - 0.045f, z + 0.045f, iron, NO);
  float d0 = f - reach + 0.06f, d1 = f - 0.36f, y0 = y - 0.66f, y1 = y - 0.16f;
  for (int i = 0; i < 2; i++) {
    float d = i ? d1 - 0.04f : d0 + 0.04f;
    WBox(w, d - 0.006f, d + 0.006f, y1, y, z - 0.006f, z + 0.006f, iron, NO);
  }
  m.material = kTownWood;
  simd_float3 wood = Hex(0x4a3828);
  WBox(w, d0, d1, y0, y1, z - 0.022f, z + 0.022f, wood, YES);
  m.material = kTownSign;
  simd_float3 c = {(float)(seed & 0xFFFF), 0, 0};
  for (int i = 0; i < 2; i++) {
    float zz = i ? z + 0.0235f : z - 0.0235f;
    Q(m, WP(w, d1, y0, zz), WP(w, d0, y0, zz), WP(w, d0, y1, zz), WP(w, d1, y1, zz), (simd_float3){0, 0, i ? 1.0f : -1.0f}, c, V2(0, 0), V2(1, 0),
      V2(1, 1), V2(0, 1));
  }
}

static void BuildLot(const Wall *w, MeshBuilder *cards, const TownLayout *L, const Lot *lot, Rng *r) {
  MeshBuilder *m = w->m;
  simd_float3 stone = {(float)lot->seed, lot->course, lot->tone};
  float z0 = lot->z0, z1 = lot->z1;
  float deep = lot->tower ? FaceDepth(lot, 0) + 8.3f : kReturnDepth;
  for (int k = 0; k < lot->storeys; k++) {
    float ya = StoreyY(lot, k), yb = StoreyY(lot, k + 1), f = FaceDepth(lot, k);
    if (lot->bigArch && k == 1) continue;  // the arch's band covers it
    if (lot->bigArch && k == 0) yb = StoreyY(lot, 2);
    Opening ops[6];
    int n = StoreyOpenings(lot, k, ops);
    Wall tw = *w;
    simd_float3 face = stone;
    if (k >= lot->timberFrom) {
      int count = (int)fminf(fmaxf(floorf((z1 - z0 - 0.5f) / 1.8f), 1), 4);
      tw.timber = YES;
      tw.uy = ya;
      face = (simd_float3){(z1 - z0) / (float)count, z0, yb - ya};
    }
    Band(&tw, f, z0, z1, ya, yb, face, ops, n);
    if (lot->bigArch && k == 0) {
      // The arch's back: a wall with a door.
      const Opening *big = &ops[0];
      float d1 = f + big->depth, zc = (big->z0 + big->z1) / 2;
      Opening door = {zc - 0.6f, zc + 0.6f, 0, 2.15f, 0.6f, 0.3f, kFillDoor, NO, SceneHash(lot->seed, 151u) & 0xFFFF};
      Band(w, d1, big->z0, big->z1, 0, big->y1 + big->rise + 0.05f, stone, &door, 1);
      Inside(w, d1, &door, stone);
    }
    for (int i = 0; i < n; i++) {
      const Opening *o = &ops[i];
      Inside(&tw, f, o, stone);
      m.material = kTownStone;
      if (o->balcony) {
        Balcony(w, f, ya, o->z0 - 0.35f, o->z1 + 0.35f, stone);
      } else if (o->fill == kFillGlass || o->fill == kFillShutters) {
        WBox(w, f - 0.07f, f, o->y0 - 0.09f, o->y0 + 0.01f, o->z0 - 0.07f, o->z1 + 0.07f, stone, NO);
      }
      if (o->fill == kFillGlass && !o->balcony && (o->seed >> 3) % 3 == 0) {
        // Shutters folded back against the wall on both sides.
        float before = i > 0 ? o->z0 - ops[i - 1].z1 : o->z0 - z0, after = i < n - 1 ? ops[i + 1].z0 - o->z1 : z1 - o->z1;
        float leaf = fminf((o->z1 - o->z0) / 2, fminf(before, after) / 2 - 0.06f);
        if (leaf > 0.2f) {
          m.material = kTownWindow;
          simd_float3 c = {(float)(o->seed & 0xFFFF), 0, 1};
          float y1 = o->y1 + o->rise * 0.5f, d = f - 0.03f;
          Q(m, WP(w, d, o->y0, o->z0 - 0.03f - leaf), WP(w, d, o->y0, o->z0 - 0.03f), WP(w, d, y1, o->z0 - 0.03f), WP(w, d, y1, o->z0 - 0.03f - leaf),
            WN(w, -1, 0, 0), c, V2(0, 0), V2(0.5f, 0), V2(0.5f, 1), V2(0, 1));
          Q(m, WP(w, d, o->y0, o->z1 + 0.03f), WP(w, d, o->y0, o->z1 + 0.03f + leaf), WP(w, d, y1, o->z1 + 0.03f + leaf), WP(w, d, y1, o->z1 + 0.03f),
            WN(w, -1, 0, 0), c, V2(0.5f, 0), V2(1, 0), V2(1, 1), V2(0.5f, 1));
          m.material = kTownStone;
        }
      }
    }
    m.material = kTownStone;
    Q(m, WP(w, f, ya, z0), WP(w, deep, ya, z0), WP(w, deep, yb, z0), WP(w, f, yb, z0), (simd_float3){0, 0, -1}, stone, V2(f, ya), V2(deep, ya),
      V2(deep, yb), V2(f, yb));
    Q(m, WP(w, f, ya, z1), WP(w, deep, ya, z1), WP(w, deep, yb, z1), WP(w, f, yb, z1), (simd_float3){0, 0, 1}, stone, V2(f, ya), V2(deep, ya),
      V2(deep, yb), V2(f, yb));
    if (lot->tower) Face(w, deep, z0, z1, ya, yb, stone);
    if (k >= 1) {
      float fl = FaceDepth(lot, k - 1);
      if (f < fl - 1e-3f) {
        // The storey stands out: its underside on corbels.
        Q(m, WP(w, f, ya, z0), WP(w, f, ya, z1), WP(w, fl, ya, z1), WP(w, fl, ya, z0), (simd_float3){0, -1, 0}, stone, V2(z0, f), V2(z1, f),
          V2(z1, fl), V2(z0, fl));
        WBox(w, f - 0.04f, f + 0.02f, ya - 0.14f, ya + 0.12f, z0, z1, stone, NO);
        int count = MAX(1, (int)floorf((z1 - z0) / 0.95f));
        float pitch = (z1 - z0) / (float)count;
        for (int i = 0; i < count; i++) {
          float zc = z0 + pitch * ((float)i + 0.5f);
          WBox(w, f + 0.02f, fl, ya - 0.24f, ya - 0.002f, zc - 0.12f, zc + 0.12f, stone, NO);
          WBox(w, (f + fl) / 2, fl, ya - 0.44f, ya - 0.24f, zc - 0.1f, zc + 0.1f, stone, NO);
        }
      } else {
        WBox(w, f - 0.08f, f, ya - 0.05f, ya + 0.15f, z0, z1, stone, NO);  // a string course
      }
    } else {
      // A plinth between the doorways.
      float z = z0;
      for (int i = 0; i <= n; i++) {
        float end = i < n ? ops[i].z0 : z1;
        if (end - z > 0.05f) WBox(w, f - 0.06f, f, 0, 0.42f, z, end, stone, NO);
        if (i < n) z = ops[i].z1;
      }
    }
    // A carved panel on the first storey above the street, in the widest stretch of wall.
    if (k == 1 && !lot->tower && SceneHashF(lot->seed, 300u) < 0.5f) {
      float best = 0, at = 0, z = z0 + 0.25f;
      for (int i = 0; i <= n; i++) {
        float end = i < n ? ops[i].z0 - 0.15f : z1 - 0.25f;
        if (end - z > best) {
          best = end - z;
          at = (z + end) / 2;
        }
        if (i < n) z = ops[i].z1 + 0.15f;
      }
      if (best >= 1.3f) Relief(w, f, at, ya + 0.6f, fminf(best - 0.3f, 1.05f), 1.15f, SceneHash(lot->seed, 301u), stone);
    }
  }
  float top = LotTop(lot), ft = FaceDepth(lot, lot->storeys - 1);
  m.material = kTownStone;
  if (lot->pilaster > 0) {  // piers at both ends, base to capital
    float p = lot->pilaster, f0 = FaceDepth(lot, 0), out = 0.3f;
    for (int i = 0; i < 2; i++) {
      float za = i ? z1 - p : z0, zb = za + p;
      WBox(w, f0 - out - 0.07f, f0, 0, 0.65f, za, zb, stone, NO);
      WBox(w, f0 - out, f0, 0.65f, top - 0.55f, za, zb, stone, NO);
      WBox(w, f0 - out - 0.08f, f0, top - 0.55f, top - 0.4f, za, zb, stone, NO);
    }
  }
  if (lot->bayK1 >= lot->bayK0) Bay(w, lot, stone);
  if (!lot->tower && SceneHashF(lot->seed, 700u) < 0.5f) {
    Opening g[6];
    int ng = StoreyOpenings(lot, 0, g);
    if (ng > 0) Sign(w, FaceDepth(lot, 0), g[ng - 1].z1 + 0.35f > z1 - lot->pilaster - 0.1f ? g[0].z0 - 0.3f : g[ng - 1].z1 + 0.35f, SceneHash(lot->seed, 701u));
  }
  BOOL timberTop = lot->storeys - 1 >= lot->timberFrom;
  m.material = timberTop ? kTownWood : kTownStone;
  simd_float3 eave = timberTop ? Hex(kOak) : stone;
  WBox(w, ft - 0.24f, ft, top - 0.26f, top, z0, z1, eave, timberTop);  // cornice
  WBox(w, ft - 0.14f, ft, top - 0.4f, top - 0.26f, z0, z1, eave, timberTop);
  Roof(w, lot, stone);
  // Ivy, from a ledge high up.
  if (lot->storeys >= 3 && SceneHashF(lot->seed, 500u) < L->ivy) {
    int curtains = 1 + (SceneHashF(lot->seed, 501u) < 0.4f);
    for (int i = 0; i < curtains; i++) {
      int ks = 2 + (int)(SceneHashF(lot->seed, 502u + (uint32_t)i) * (float)(lot->storeys - 1));
      float yTop = StoreyY(lot, MIN(ks, lot->storeys)) - 0.1f;
      float zc = z0 + 0.5f + (z1 - z0 - 1.0f) * SceneHashF(lot->seed, 504u + (uint32_t)i);
      float length = fminf(RF(r, 3.0, 9.0), yTop - 2.9f);
      if (length > 1) Ivy(w, cards, lot, zc, yTop, length, RF(r, 0.8, 1.8), r);
    }
  }
}

#pragma mark - Bridges

static void BuildBridge(MeshBuilder *m, const TownLayout *L, const Bridge *b) {
  float hw = L->halfWidth, a = hw - kPier, W = hw + 1.6f, s = b->spring, T = b->top, z0 = b->z0, z1 = b->z1;
  simd_float3 face = {a, s, (float)(b->seed * 2 + (uint32_t)b->type)};
  simd_float3 stone = {(float)b->seed, 0.34f, SceneHashF(b->seed, 3u)};
  const int N = 20;
  for (int e = 0; e < 2; e++) {
    float z = e ? z1 : z0;
    simd_float3 n = {0, 0, e ? 1.0f : -1.0f};
    m.material = kTownArch;
    Q(m, (simd_float3){-W, 0, z}, (simd_float3){-a, 0, z}, (simd_float3){-a, T, z}, (simd_float3){-W, T, z}, n, face, V2(-W, 0), V2(-a, 0), V2(-a, T),
      V2(-W, T));
    Q(m, (simd_float3){a, 0, z}, (simd_float3){W, 0, z}, (simd_float3){W, T, z}, (simd_float3){a, T, z}, n, face, V2(a, 0), V2(W, 0), V2(W, T), V2(a, T));
    for (int i = 0; i < N; i++) {
      float t0 = (float)M_PI * (1 - (float)i / N), t1 = (float)M_PI * (1 - (float)(i + 1) / N);
      float x0 = a * cosf(t0), y0 = s + a * sinf(t0), x1 = a * cosf(t1), y1 = s + a * sinf(t1);
      Q(m, (simd_float3){x0, y0, z}, (simd_float3){x1, y1, z}, (simd_float3){x1, T, z}, (simd_float3){x0, T, z}, n, face, V2(x0, y0), V2(x1, y1),
        V2(x1, T), V2(x0, T));
    }
    // Mouldings: a string course over the arch, imposts at the springing.
    m.material = kTownStone;
    float out = e ? 0.09f : -0.09f;
    SBox(m, (simd_float3){-W, s + a + 0.55f, fminf(z, z + out)}, (simd_float3){W, s + a + 0.75f, fmaxf(z, z + out)}, stone, NO);
    SBox(m, (simd_float3){-W, s - 0.2f, fminf(z, z + out)}, (simd_float3){-a + 0.06f, s, fmaxf(z, z + out)}, stone, NO);
    SBox(m, (simd_float3){a - 0.06f, s - 0.2f, fminf(z, z + out)}, (simd_float3){W, s, fmaxf(z, z + out)}, stone, NO);
  }
  m.material = kTownStone;
  float arc = 0;
  for (int i = 0; i < N; i++) {
    float t0 = (float)M_PI * (1 - (float)i / N), t1 = (float)M_PI * (1 - (float)(i + 1) / N), tm = (t0 + t1) / 2;
    simd_float3 p0 = {a * cosf(t0), s + a * sinf(t0), 0}, p1 = {a * cosf(t1), s + a * sinf(t1), 0};
    float len = a * (t0 - t1);
    Q(m, p0 + (simd_float3){0, 0, z0}, p1 + (simd_float3){0, 0, z0}, p1 + (simd_float3){0, 0, z1}, p0 + (simd_float3){0, 0, z1},
      (simd_float3){-cosf(tm), -sinf(tm), 0}, stone, V2(arc, z0), V2(arc + len, z0), V2(arc + len, z1), V2(arc, z1));
    arc += len;
  }
  Q(m, (simd_float3){-a, 0, z0}, (simd_float3){-a, 0, z1}, (simd_float3){-a, s, z1}, (simd_float3){-a, s, z0}, (simd_float3){1, 0, 0}, stone, V2(z0, 0),
    V2(z1, 0), V2(z1, s), V2(z0, s));
  Q(m, (simd_float3){a, 0, z0}, (simd_float3){a, 0, z1}, (simd_float3){a, s, z1}, (simd_float3){a, s, z0}, (simd_float3){-1, 0, 0}, stone, V2(z0, 0),
    V2(z1, 0), V2(z1, s), V2(z0, s));
  for (int e = 0; e < 2; e++) {  // ends inside the houses, in case one is lower
    float x = e ? W : -W;
    Q(m, (simd_float3){x, 0, z0}, (simd_float3){x, 0, z1}, (simd_float3){x, T, z1}, (simd_float3){x, T, z0}, (simd_float3){e ? 1.0f : -1.0f, 0, 0}, stone,
      V2(z0, 0), V2(z1, 0), V2(z1, T), V2(z0, T));
  }
  Q(m, (simd_float3){-W, T, z0}, (simd_float3){W, T, z0}, (simd_float3){W, T, z1}, (simd_float3){-W, T, z1}, (simd_float3){0, 1, 0}, stone, V2(-W, z0),
    V2(W, z0), V2(W, z1), V2(-W, z1));
  if (b->type == 0) {
    // A parapet with openings on both edges.
    for (int e = 0; e < 2; e++) {
      float za = e ? z1 - 0.3f : z0, zb = za + 0.3f;
      SBox(m, (simd_float3){-W, T, za}, (simd_float3){W, T + 0.28f, zb}, stone, NO);
      SBox(m, (simd_float3){-W, T + 0.86f, za - 0.04f}, (simd_float3){W, T + 1.06f, zb + 0.04f}, stone, NO);
      for (float x = -W; x < W - 0.2f; x += 0.92f) SBox(m, (simd_float3){x, T + 0.28f, za}, (simd_float3){x + 0.36f, T + 0.86f, zb}, stone, NO);
    }
  } else {
    // A covered passage: a cornice and a tiled roof along the street's width.
    SBox(m, (simd_float3){-W, T - 0.25f, z0 - 0.2f}, (simd_float3){W, T, z1 + 0.2f}, stone, NO);
    float zc = (z0 + z1) / 2, over = 0.35f, ridge = T + ((z1 - z0) / 2 + over) * 0.9f;
    m.material = kTownRoof;
    simd_float3 tiles = {(float)b->seed, 0, 0};
    float slope = ((z1 - z0) / 2 + over) * 1.35f;
    Q(m, (simd_float3){-W, T - 0.05f, z0 - over}, (simd_float3){W, T - 0.05f, z0 - over}, (simd_float3){W, ridge, zc}, (simd_float3){-W, ridge, zc},
      simd_normalize((simd_float3){0, 1, -0.9f}), tiles, V2(-W, 0), V2(W, 0), V2(W, slope), V2(-W, slope));
    Q(m, (simd_float3){-W, T - 0.05f, z1 + over}, (simd_float3){W, T - 0.05f, z1 + over}, (simd_float3){W, ridge, zc}, (simd_float3){-W, ridge, zc},
      simd_normalize((simd_float3){0, 1, 0.9f}), tiles, V2(-W, 0), V2(W, 0), V2(W, slope), V2(-W, slope));
  }
}

#pragma mark - Lanterns

/// A lantern with its glass centred at `c`.
static void Lantern(MeshBuilder *m, simd_float3 c) {
  const float hw = 0.085f, hh = 0.15f;
  simd_float3 iron = {0.032f, 0.03f, 0.028f};
  m.material = kTownIron;
  SBox(m, c + (simd_float3){-hw - 0.015f, -hh - 0.035f, -hw - 0.015f}, c + (simd_float3){hw + 0.015f, -hh, hw + 0.015f}, iron, NO);
  SBox(m, c + (simd_float3){-hw - 0.02f, hh, -hw - 0.02f}, c + (simd_float3){hw + 0.02f, hh + 0.03f, hw + 0.02f}, iron, NO);
  simd_float3 apex = c + (simd_float3){0, hh + 0.13f, 0};
  simd_float3 k[4] = {c + (simd_float3){-hw - 0.03f, hh + 0.03f, -hw - 0.03f}, c + (simd_float3){hw + 0.03f, hh + 0.03f, -hw - 0.03f},
                      c + (simd_float3){hw + 0.03f, hh + 0.03f, hw + 0.03f}, c + (simd_float3){-hw - 0.03f, hh + 0.03f, hw + 0.03f}};
  for (int i = 0; i < 4; i++) {
    simd_float3 a = k[i], b = k[(i + 1) % 4];
    simd_float3 n = simd_normalize(simd_cross(b - a, apex - a));
    if (n.y < 0) n = -n;
    Tri(m, a, b, apex, n, iron, V2(0, 0), V2(1, 0), V2(0.5f, 1));
  }
  SBox(m, apex - (simd_float3){0.012f, 0, 0.012f}, apex + (simd_float3){0.012f, 0.03f, 0.012f}, iron, NO);
  for (int i = 0; i < 4; i++) {
    float sx = (i & 1) ? 1 : -1, sz = (i & 2) ? 1 : -1;
    simd_float3 p = c + (simd_float3){sx * hw, 0, sz * hw};
    SBox(m, p + (simd_float3){-0.012f, -hh, -0.012f}, p + (simd_float3){0.012f, hh, 0.012f}, iron, NO);
  }
  m.material = kTownFlame;
  simd_float3 lit = {1, 1, 1};
  const float g = hw - 0.004f;
  for (int i = 0; i < 4; i++) {
    float ang = (float)M_PI_2 * (float)i;
    simd_float3 n = {cosf(ang), 0, sinf(ang)}, t = {-sinf(ang), 0, cosf(ang)};
    simd_float3 o = c + n * g;
    Q(m, o - t * g - (simd_float3){0, hh, 0}, o + t * g - (simd_float3){0, hh, 0}, o + t * g + (simd_float3){0, hh, 0}, o - t * g + (simd_float3){0, hh, 0},
      n, lit, V2(0, 0), V2(1, 0), V2(1, 1), V2(0, 1));
  }
}

static void BuildWallLantern(const Wall *w, float f, float z) {
  MeshBuilder *m = w->m;
  simd_float3 iron = {0.032f, 0.03f, 0.028f};
  m.material = kTownIron;
  WBox(w, f - kArmReach - 0.03f, f + 0.02f, kArmY - 0.022f, kArmY + 0.022f, z - 0.014f, z + 0.014f, iron, NO);
  WBox(w, f - 0.025f, f + 0.01f, kArmY - 0.55f, kArmY + 0.08f, z - 0.05f, z + 0.05f, iron, NO);
  [m tubeFrom:WP(w, f, kArmY - 0.48f, z) to:WP(w, f - kArmReach * 0.7f, kArmY - 0.02f, z) r0:0.011f r1:0.011f segments:4 color:iron toColor:iron vScale:1];
  simd_float2 c = WallLanternCentre(f);
  WBox(w, c.x - 0.008f, c.x + 0.008f, c.y + 0.28f, kArmY, z - 0.008f, z + 0.008f, iron, NO);
  Lantern(m, WP(w, c.x, c.y, z));
}

#pragma mark - Market stalls

static const uint32_t kAwnings[] = {0xc8b896, 0xa89676, 0xb8a07a, 0x9a4a32, 0x8a3c30, 0x5e6a48, 0xb08a48, 0x8a8274, 0x56606a, 0xd0c4a8};
static const uint32_t kWoods[] = {0x5a4632, 0x6a5440, 0x4a3a2a, 0x7a6450};
static const uint32_t kCloths[] = {0xbeb4a0, 0xa58c69, 0x6e5037, 0x5f6441, 0x8c4632, 0x646e78, 0xaa8246, 0x7a2e2a, 0x3e4a5a, 0xd4ccb8};
static const uint32_t kHerbs[] = {0x5a6034, 0x6a6a3a, 0x7a5a2a, 0x8a4a22, 0x4a4a2a, 0x9a7a3a, 0x3a3020, 0x6e7244};
static const uint32_t kProduce[] = {0x8a2018, 0x9a3a1a, 0x6a8a2a, 0xa8781e, 0x4a6a24, 0xc06a1a, 0x7a2a3a, 0xb0a070};

#define PICK(table, r) Hex(table[(int)(Rand(r) * (sizeof table / sizeof table[0]))])

static void Awning(const Wall *w, float dF, float f0, float frontH, float backH, float z0, float z1, simd_float3 cloth, Rng *r) {
  MeshBuilder *m = w->m;
  m.material = kTownCloth;
  enum { NZ = 16, ND = 6 };
  float za = z0 - 0.15f, zb = z1 + 0.15f, dBack = f0 - 0.03f, dFront = dF - 0.3f, yBack = backH + 0.05f, yFront = frontH + 0.02f;
  float sagZ = RF(r, 0.04, 0.1), sagD = RF(r, 0.04, 0.1), waves = floorf((zb - za) / RF(r, 0.35, 0.6)), phase = RF(r, 0, 6.28);
  simd_float3 P[NZ + 1][ND + 1];
  for (int i = 0; i <= NZ; i++) {
    for (int j = 0; j <= ND; j++) {
      float u = (float)i / NZ, t = (float)j / ND;
      float y = yBack + (yFront - yBack) * t - sagD * sinf((float)M_PI * t) * (0.4f + 0.6f * sinf((float)M_PI * u)) -
                sagZ * sinf((float)M_PI * u) * (0.3f + 0.7f * t) - 0.028f * t * sinf(u * waves * (float)M_PI + phase + t * 1.5f);
      P[i][j] = WP(w, dBack + (dFront - dBack) * t, y, za + (zb - za) * u);
    }
  }
  float slope = simd_distance(P[0][0], P[0][ND]);
  for (int i = 0; i < NZ; i++) {
    for (int j = 0; j < ND; j++) {
      simd_float3 c[4] = {P[i][j], P[i + 1][j], P[i + 1][j + 1], P[i][j + 1]};
      int ci[4][2] = {{i, j}, {i + 1, j}, {i + 1, j + 1}, {i, j + 1}};
      simd_float3 nn[4];
      simd_float2 uv[4];
      for (int k = 0; k < 4; k++) {
        int a = ci[k][0], b = ci[k][1];
        simd_float3 dz = P[MIN(a + 1, NZ)][b] - P[MAX(a - 1, 0)][b], dd = P[a][MIN(b + 1, ND)] - P[a][MAX(b - 1, 0)];
        simd_float3 n = simd_normalize(simd_cross(dz, dd));
        if (n.y < 0) n = -n;
        nn[k] = n;
        uv[k] = V2(P[a][b].z, slope * (float)b / ND);
      }
      int order[6] = {0, 1, 2, 0, 2, 3};
      for (int k = 0; k < 6; k++) [m vertex:c[order[k]] normal:nn[order[k]] color:cloth uv:uv[order[k]]];
    }
  }
  // A valance along the front, its hem worn ragged.
  float drop = RF(r, 0.18, 0.3), hem[NZ + 1];
  for (int i = 0; i <= NZ; i++) hem[i] = drop * RF(r, 0.7, 1.2);
  for (int i = 0; i < NZ; i++) {
    simd_float3 a = P[i][ND], b = P[i + 1][ND];
    Q(m, a, b, b - (simd_float3){0, hem[i + 1], 0}, a - (simd_float3){0, hem[i], 0}, WN(w, -1, 0, 0), cloth, V2(a.z, -0.001f), V2(b.z, -0.001f),
      V2(b.z, -hem[i + 1]), V2(a.z, -hem[i]));
  }
}

static void Jar(MeshBuilder *m, simd_float3 base, float r, float h, simd_float3 contents, simd_float3 lid) {
  m.material = kTownJar;
  simd_float3 up = {0, 1, 0};
  [m tubeFrom:base to:base + up * h r0:r r1:r segments:10 color:contents toColor:contents vScale:1];
  [m tubeFrom:base + up * h to:base + up * (h + r * 0.3f) r0:r r1:r * 0.62f segments:10 color:contents toColor:contents vScale:1];
  m.material = kTownPlain;
  [m tubeFrom:base + up * (h + r * 0.3f) to:base + up * (h + r * 0.3f + 0.035f) r0:r * 0.64f r1:r * 0.64f segments:10 color:lid toColor:lid vScale:1];
  Disc(m, base + up * (h + r * 0.3f + 0.035f), r * 0.64f, 10, lid);
}

/// Produce heaped in a box or basket: round things on a grid with some scatter.
static void Heap(MeshBuilder *m, simd_float3 lo, simd_float3 hi, float y, float size, simd_float3 col, Rng *r) {
  m.material = kTownProduce;
  for (float x = lo.x + size; x < hi.x - size * 0.5f; x += size * 1.8f) {
    for (float z = lo.z + size; z < hi.z - size * 0.5f; z += size * 1.8f) {
      float s = size * RF(r, 0.85, 1.15);
      simd_float3 c = {x + RF(r, -0.2, 0.2) * size, y + s * 0.6f + RF(r, 0, 0.5) * size, z + RF(r, -0.2, 0.2) * size};
      [m icosahedronAt:c radius:(simd_float3){s, s * 0.9f, s} color:[m vary:col by:0.12] jitter:0.08f];
    }
  }
}

static void Goods(const Wall *w, const Stall *st, float t0, float t1, float tableY, Rng *r) {
  MeshBuilder *m = w->m;
  float z0 = st->z0 + 0.18f, z1 = st->z1 - 0.18f;
  switch (st->kind) {
    case kStallHerbs: {
      simd_float3 lid = Hex(0x8a6a48);
      for (int row = 0; row < 3; row++) {
        float d = t0 + 0.1f + (t1 - t0 - 0.2f) * (float)row / 2.0f;
        for (float z = z0 + 0.02f; z < z1 - 0.12f;) {
          float rad = RF(r, 0.05, 0.08), h = RF(r, 0.12, 0.2) + 0.05f * (float)row;
          Jar(m, WP(w, d, tableY, z + rad), rad, h, PICK(kHerbs, r), lid);
          z += 2 * rad + RF(r, 0.015, 0.06);
        }
      }
      break;
    }
    case kStallProduce: {
      for (float z = z0; z < z1 - 0.3f;) {
        float len = RF(r, 0.38, 0.5);
        simd_float3 wood = PICK(kWoods, r), col = PICK(kProduce, r);
        if (Rand(r) < 0.5) {  // a crate
          m.material = kTownWood;
          simd_float3 a = WP(w, t0 + 0.04f, tableY, z), b = WP(w, t1 - 0.04f, tableY + 0.16f, z + len);
          simd_float3 lo = simd_min(a, b), hi = simd_max(a, b);
          SBox(m, lo, hi, wood, YES);
          Heap(m, lo, hi, tableY + 0.14f, RF(r, 0.035, 0.055), col, r);
        } else {  // a basket
          m.material = kTownWicker;
          float rad = fminf(len / 2, (t1 - t0) / 2 - 0.03f);
          simd_float3 c = WP(w, (t0 + t1) / 2, tableY, z + len / 2);
          [m tubeFrom:c to:c + (simd_float3){0, 0.14f, 0} r0:rad * 0.82f r1:rad segments:12 color:Hex(0x8a6a40) toColor:Hex(0x9a7a4a) vScale:1];
          Heap(m, c - (simd_float3){rad * 0.8f, 0, rad * 0.8f}, c + (simd_float3){rad * 0.8f, 0, rad * 0.8f}, tableY + 0.1f, RF(r, 0.035, 0.05), col, r);
        }
        z += len + RF(r, 0.03, 0.1);
      }
      break;
    }
    case kStallBread: {
      m.material = kTownWood;
      simd_float3 a = WP(w, t0 + 0.04f, tableY, z0), b = WP(w, t1 - 0.04f, tableY + 0.025f, z1);
      SBox(m, simd_min(a, b), simd_max(a, b), Hex(0x8a6a48), YES);
      m.material = kTownProduce;
      for (float z = z0 + 0.12f; z < z1 - 0.1f; z += RF(r, 0.2, 0.28)) {
        for (float d = t0 + 0.16f; d < t1 - 0.1f; d += RF(r, 0.2, 0.26)) {
          BOOL round = Rand(r) < 0.4;
          simd_float3 rad = round ? (simd_float3){0.1f, 0.06f, 0.1f} : (simd_float3){0.07f, 0.055f, 0.13f};
          simd_float3 crust = simd_mix(Hex(0x8a5a2a), Hex(0xb08040), (simd_float3)(float)Rand(r));
          [m icosahedronAt:WP(w, d, tableY + 0.06f, z) radius:rad color:crust jitter:0.06f];
        }
      }
      break;
    }
    case kStallCloth: {
      for (float z = z0; z < z1 - 0.25f;) {
        float len = RF(r, 0.28, 0.4);
        float y = tableY;
        int layers = 3 + (int)(Rand(r) * 5);
        for (int i = 0; i < layers; i++) {
          float h = RF(r, 0.035, 0.06);
          m.material = kTownCloth;
          simd_float3 a = WP(w, t0 + 0.08f + RF(r, -0.02, 0.02), y, z + RF(r, -0.02, 0.02)), b = WP(w, t1 - 0.12f, y + h, z + len);
          SBox(m, simd_min(a, b), simd_max(a, b), PICK(kCloths, r), NO);
          y += h;
        }
        z += len + RF(r, 0.04, 0.1);
      }
      break;
    }
    default: {  // pots and jugs
      m.material = kTownProduce;
      for (int row = 0; row < 2; row++) {
        float d = t0 + 0.14f + (t1 - t0 - 0.28f) * (float)row;
        for (float z = z0 + 0.05f; z < z1 - 0.15f;) {
          float rad = RF(r, 0.07, 0.12), h = RF(r, 0.14, 0.26);
          simd_float3 col = Rand(r) < 0.6 ? [m vary:Hex(0x9a5a3e) by:0.12] : PICK(kHerbs, r) * 0.7f;
          simd_float3 c = WP(w, d, tableY, z + rad);
          [m tubeFrom:c to:c + (simd_float3){0, h * 0.55f, 0} r0:rad * 0.65f r1:rad segments:10 color:col toColor:col vScale:1];
          [m tubeFrom:c + (simd_float3){0, h * 0.55f, 0} to:c + (simd_float3){0, h, 0} r0:rad r1:rad * 0.45f segments:10 color:col toColor:col vScale:1];
          [m tubeFrom:c + (simd_float3){0, h, 0} to:c + (simd_float3){0, h + 0.04f, 0} r0:rad * 0.45f r1:rad * 0.5f segments:10 color:col toColor:col vScale:1];
          z += 2 * rad + RF(r, 0.03, 0.08);
        }
      }
      break;
    }
  }
}

static void BuildStall(MeshBuilder *m, const TownLayout *L, const Plan *P, const Stall *st) {
  Wall w = {m, st->side ? 1.0f : -1.0f, L->halfWidth};
  const Lot *lot = &P->lots[st->side][st->lot];
  float f0 = FaceDepth(lot, 0), D = st->depth, dF = f0 - D, z0 = st->z0, z1 = st->z1;
  Rng r = RngFor(st->seed, 0, 0, 81);
  simd_float3 wood = PICK(kWoods, &r), wood2 = PICK(kWoods, &r), cloth = PICK(kAwnings, &r);
  float frontH = 2.15f + 0.15f * SceneHashF(st->seed, 1u), backH = 3.0f + RF(&r, 0, 0.3);
  m.material = kTownWood;
  WBox(&w, dF, dF + 0.08f, 0, frontH, z0, z0 + 0.08f, wood, YES);
  WBox(&w, dF, dF + 0.08f, 0, frontH, z1 - 0.08f, z1, wood, YES);
  WBox(&w, f0 - 0.12f, f0 - 0.04f, 0, backH, z0, z0 + 0.08f, wood, YES);
  WBox(&w, f0 - 0.12f, f0 - 0.04f, 0, backH, z1 - 0.08f, z1, wood, YES);
  WBox(&w, dF - 0.01f, dF + 0.09f, frontH - 0.12f, frontH, z0 - 0.05f, z1 + 0.05f, wood, YES);
  WBox(&w, f0 - 0.13f, f0 - 0.03f, backH - 0.12f, backH, z0 - 0.05f, z1 + 0.05f, wood, YES);
  m.material = kTownPlain;
  for (int i = 0; i < 2; i++) {
    float z = i ? z1 - 0.04f : z0 + 0.04f;
    [m tubeFrom:WP(&w, dF + 0.04f, frontH - 0.05f, z) to:WP(&w, f0 - 0.08f, backH - 0.05f, z) r0:0.035f r1:0.035f segments:5 color:wood * 0.8f
        toColor:wood * 0.8f vScale:1];
  }
  // The table: a top on a plank front.
  float tableY = 0.84f + RF(&r, 0, 0.06), t0 = dF + 0.1f, t1 = fminf(dF + 0.95f, f0 - 0.25f);
  m.material = kTownWood;
  WBox(&w, t0, t1, tableY - 0.05f, tableY, z0 + 0.1f, z1 - 0.1f, wood2, YES);
  WBox(&w, t0 + 0.02f, t0 + 0.05f, 0.06f, tableY - 0.05f, z0 + 0.14f, z1 - 0.14f, wood2 * 0.85f, YES);
  WBox(&w, t0 + 0.05f, t1 - 0.05f, 0.06f, tableY - 0.05f, z0 + 0.14f, z0 + 0.17f, wood2 * 0.85f, YES);
  WBox(&w, t0 + 0.05f, t1 - 0.05f, 0.06f, tableY - 0.05f, z1 - 0.17f, z1 - 0.14f, wood2 * 0.85f, YES);
  Awning(&w, dF, f0, frontH, backH, z0, z1, cloth, &r);
  Goods(&w, st, t0, t1, tableY, &r);
  // A cloth over the table's front.
  if (Rand(&r) < 0.6) {
    m.material = kTownCloth;
    simd_float3 c = PICK(kCloths, &r);
    float drop = RF(&r, 0.3, 0.6), d = t0 - 0.012f;
    Q(m, WP(&w, d, tableY, z0 + 0.1f), WP(&w, d, tableY, z1 - 0.1f), WP(&w, d, tableY - drop, z1 - 0.1f), WP(&w, d, tableY - drop, z0 + 0.1f),
      WN(&w, -1, 0, 0), c, V2(z0, 0), V2(z1, 0), V2(z1, drop), V2(z0, drop));
  }
  // Shelves against the wall, crowded with jars, pots and bottles.
  float sh0 = f0 - 0.38f, sh1 = f0 - 0.05f;
  if (sh0 > t1 + 0.25f) {
    for (int i = 0; i < 2; i++) {
      float y = 1.2f + 0.45f * (float)i;
      m.material = kTownWood;
      WBox(&w, sh0, sh1, y - 0.035f, y, z0 + 0.1f, z1 - 0.1f, wood2, YES);
      for (float z = z0 + 0.16f; z < z1 - 0.2f;) {
        float rad = RF(&r, 0.045, 0.075), h = RF(&r, 0.12, 0.26);
        double pick = Rand(&r);
        simd_float3 base = WP(&w, (sh0 + sh1) / 2 + RF(&r, -0.05, 0.05), y, z + rad);
        if (pick < 0.5) {
          Jar(m, base, rad, h * 0.8f, PICK(kHerbs, &r), Hex(0x8a6a48));
        } else if (pick < 0.75) {  // a bottle
          m.material = kTownJar;
          simd_float3 glass = Rand(&r) < 0.5 ? Hex(0x1e3a22) : Hex(0x3a2412);
          [m tubeFrom:base to:base + (simd_float3){0, h * 0.65f, 0} r0:rad * 0.8f r1:rad * 0.8f segments:8 color:glass toColor:glass vScale:1];
          [m tubeFrom:base + (simd_float3){0, h * 0.65f, 0} to:base + (simd_float3){0, h * 1.1f, 0} r0:rad * 0.8f r1:rad * 0.25f segments:8 color:glass
                  toColor:glass vScale:1];
        } else {  // a pot
          m.material = kTownProduce;
          simd_float3 col = [m vary:Hex(0x8a5236) by:0.15];
          [m tubeFrom:base to:base + (simd_float3){0, h * 0.6f, 0} r0:rad * 0.7f r1:rad * 1.1f segments:8 color:col toColor:col vScale:1];
          [m tubeFrom:base + (simd_float3){0, h * 0.6f, 0} to:base + (simd_float3){0, h * 0.85f, 0} r0:rad * 1.1f r1:rad * 0.6f segments:8 color:col
                  toColor:col vScale:1];
        }
        z += 2 * rad + RF(&r, 0.01, 0.05);
      }
    }
  }
  // Crates, baskets or a barrel beside the stall, where the house front leaves room.
  for (int e = 0; e < 2; e++) {
    float za = e ? z1 + 0.05f : z0 - 0.6f, zb = za + 0.55f;
    if (za < lot->z0 + lot->pilaster + 0.1f || zb > lot->z1 - lot->pilaster - 0.1f || Rand(&r) < 0.3) continue;
    double pick = Rand(&r);
    float dm = dF + 0.45f;
    if (pick < 0.4) {
      m.material = kTownWood;
      float y = 0;
      int stack = 1 + (int)(Rand(&r) * 3);
      for (int i = 0; i < stack; i++) {
        float h = RF(&r, 0.26, 0.34);
        simd_float3 a = WP(&w, dm - 0.25f + RF(&r, -0.03, 0.03), y, za + RF(&r, 0, 0.05)), b = WP(&w, dm + 0.2f, y + h, za + 0.5f);
        SBox(m, simd_min(a, b), simd_max(a, b), PICK(kWoods, &r), YES);
        y += h;
      }
      simd_float3 a = WP(&w, dm - 0.22f, y, za), b = WP(&w, dm + 0.17f, y, za + 0.5f);
      Heap(m, simd_min(a, b), simd_max(a, b), y - 0.04f, RF(&r, 0.035, 0.05), PICK(kProduce, &r), &r);
    } else if (pick < 0.75) {
      m.material = kTownWicker;
      int baskets = 1 + (Rand(&r) < 0.5);
      for (int i = 0; i < baskets; i++) {
        float rad = RF(&r, 0.17, 0.24);
        simd_float3 c = WP(&w, dm + (i ? -0.3f : 0.1f), 0, za + 0.27f);
        [m tubeFrom:c to:c + (simd_float3){0, RF(&r, 0.25, 0.4), 0} r0:rad * 0.85f r1:rad segments:12 color:Hex(0x8a6a40) toColor:Hex(0x9a7a4a) vScale:1];
        Heap(m, c - (simd_float3){rad * 0.8f, 0, rad * 0.8f}, c + (simd_float3){rad * 0.8f, 0, rad * 0.8f}, 0.25f, RF(&r, 0.035, 0.05), PICK(kProduce, &r), &r);
        m.material = kTownWicker;
      }
    } else {
      simd_float3 c = WP(&w, dm, 0, za + 0.28f), wood = PICK(kWoods, &r), iron = {0.035f, 0.032f, 0.03f};
      m.material = kTownPlain;
      [m tubeFrom:c to:c + (simd_float3){0, 0.4f, 0} r0:0.25f r1:0.29f segments:12 color:wood toColor:wood vScale:1];
      [m tubeFrom:c + (simd_float3){0, 0.4f, 0} to:c + (simd_float3){0, 0.8f, 0} r0:0.29f r1:0.25f segments:12 color:wood toColor:wood vScale:1];
      Disc(m, c + (simd_float3){0, 0.8f, 0}, 0.25f, 12, wood * 0.8f);
      m.material = kTownIron;
      for (int i = 0; i < 3; i++) {
        float y = 0.1f + 0.3f * (float)i, rr = i == 1 ? 0.295f : 0.275f;
        [m tubeFrom:c + (simd_float3){0, y, 0} to:c + (simd_float3){0, y + 0.035f, 0} r0:rr r1:rr segments:12 color:iron toColor:iron vScale:1];
      }
    }
  }
  // Herbs drying from the front beam.
  if (Rand(&r) < 0.85) {
    m.material = kTownProduce;
    for (float z = z0 + 0.2f; z < z1 - 0.15f; z += RF(&r, 0.12, 0.24)) {
      if (st->lantern && fabsf(z - st->lanternAt.z) < 0.25f) continue;
      float len = RF(&r, 0.22, 0.4);
      simd_float3 top = WP(&w, dF + 0.04f, frontH - 0.12f, z), col = PICK(kHerbs, &r);
      [m tubeFrom:top - (simd_float3){0, 0.05f, 0} to:top - (simd_float3){0, 0.05f + len, 0} r0:RF(&r, 0.04, 0.065) r1:0.008f segments:6 color:col
          toColor:col * 0.7f vScale:1];
      m.material = kTownPlain;
      [m tubeFrom:top to:top - (simd_float3){0, 0.06f, 0} r0:0.006f r1:0.006f segments:3 color:Hex(0x6a5a44) toColor:Hex(0x6a5a44) vScale:1];
      m.material = kTownProduce;
    }
  }
  // Sacks by the front posts.
  m.material = kTownCloth;
  int sacks = (int)(Rand(&r) * 3);
  for (int i = 0; i < sacks; i++) {
    float z = i ? z1 - 0.3f : z0 + 0.3f, rr = RF(&r, 0.17, 0.24);
    [m icosahedronAt:WP(&w, dF + 0.35f, rr * 1.1f, z) radius:(simd_float3){rr, rr * 1.25f, rr} color:[m vary:Hex(0x8a7656) by:0.12] jitter:0.1f];
  }
  if (st->lantern) {
    simd_float3 c = st->lanternAt;
    simd_float3 iron = {0.032f, 0.03f, 0.028f};
    m.material = kTownIron;
    SBox(m, c + (simd_float3){-0.008f, 0.28f, -0.008f}, (simd_float3){c.x + 0.008f, frontH - 0.12f, c.z + 0.008f}, iron, NO);
    Lantern(m, c);
  }
}

#pragma mark - Washing lines

static void Garment(MeshBuilder *m, simd_float3 a, simd_float3 b, float h, simd_float3 col, Rng *r) {
  m.material = kTownCloth;
  enum { NU = 4, NV = 3 };
  simd_float3 along = simd_normalize(b - a), side = simd_normalize(simd_cross(along, (simd_float3){0, 1, 0}));
  float width = simd_distance(a, b), phase = RF(r, 0, 6.28), fold = RF(r, 0.015, 0.05), tilt = RF(r, -0.12, 0.12);
  simd_float3 P[NU + 1][NV + 1];
  simd_float2 T[NU + 1][NV + 1];
  for (int i = 0; i <= NU; i++) {
    float u = (float)i / NU;
    simd_float3 top = simd_mix(a, b, (simd_float3)u) - (simd_float3){0, 0.012f, 0};
    float len = h * (1 + tilt * (u - 0.5f) * 2);
    for (int j = 0; j <= NV; j++) {
      float v = (float)j / NV;
      P[i][j] = top - (simd_float3){0, len * v, 0} + side * (fold * sinf(u * 9.4f + phase) * (0.3f + v));
      T[i][j] = V2(u * width, -len * v - 0.001f);
    }
  }
  for (int i = 0; i < NU; i++) {
    for (int j = 0; j < NV; j++) {
      simd_float3 n = simd_normalize(side + along * (-fold * 9.4f / width * cosf(((float)i + 0.5f) / NU * 9.4f + phase)));
      int idx[6][2] = {{i, j}, {i + 1, j}, {i + 1, j + 1}, {i, j}, {i + 1, j + 1}, {i, j + 1}};
      for (int k = 0; k < 6; k++) [m vertex:P[idx[k][0]][idx[k][1]] normal:n color:col uv:T[idx[k][0]][idx[k][1]]];
    }
  }
}

static void BuildLine(MeshBuilder *m, const TownLayout *L, const Plan *P, const Line *ln) {
  float hw = L->halfWidth;
  const Lot *la = &P->lots[0][LotIndexAt(P, 0, ln->z0)], *lb = &P->lots[1][LotIndexAt(P, 1, ln->z1)];
  float da = FaceDepth(la, StoreyAt(la, ln->y0)), db = FaceDepth(lb, StoreyAt(lb, ln->y1));
  simd_float3 A = {-(hw + da) + 0.05f, ln->y0, ln->z0}, B = {hw + db - 0.05f, ln->y1, ln->z1};
  Rng r = RngFor(ln->seed, 0, 0, 91);
  float len = simd_distance(A, B), sag = len * RF(&r, 0.035, 0.06);
#define ROPE(t) (simd_mix(A, B, (simd_float3)(t)) - (simd_float3){0, 4 * sag * (t) * (1 - (t)), 0})
  simd_float3 rope = Hex(0x6a5a44);
  m.material = kTownPlain;
  const int N = 14;
  for (int i = 0; i < N; i++) {
    float t0 = (float)i / N, t1 = (float)(i + 1) / N;
    [m tubeFrom:ROPE(t0) to:ROPE(t1) r0:0.008f r1:0.008f segments:4 color:rope toColor:rope vScale:1];
  }
  m.material = kTownIron;
  SBox(m, A - (simd_float3){0.06f, 0.025f, 0.025f}, A + (simd_float3){0.0f, 0.025f, 0.025f}, (simd_float3){0.03f, 0.03f, 0.03f}, NO);
  SBox(m, B - (simd_float3){0.0f, 0.025f, 0.025f}, B + (simd_float3){0.06f, 0.025f, 0.025f}, (simd_float3){0.03f, 0.03f, 0.03f}, NO);
  float pos = len * RF(&r, 0.05, 0.14);
  while (pos < len * 0.92f) {
    float w = RF(&r, 0.4, 0.95), h = Rand(&r) < 0.25 ? RF(&r, 0.9, 1.4) : RF(&r, 0.45, 0.9);
    if (pos + w > len * 0.95f) break;
    Garment(m, ROPE(pos / len), ROPE((pos + w) / len), h, PICK(kCloths, &r), &r);
    pos += w + RF(&r, 0.04, 0.4);
  }
#undef ROPE
}

#pragma mark - The segment

NSData *TownSegmentMesh(const TownLayout *L, int64_t segment, NSUInteger *opaqueVertices) {
  Plan P;
  MakePlan(L, segment, &P);
  uint32_t seed = SceneHash(L->seed, (uint32_t)segment);
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:seed], *cards = [[MeshBuilder alloc] initWithSeed:seed + 1];
  // The street (cobbles, their pattern continuous across segments; wrapped every 4800 m).
  float e = L->halfWidth + 1.8f, wrap = (float)fmod((double)segment * kTownSegment, 4800.0);
  if (wrap < 0) wrap += 4800;
  m.material = kTownCobble;
  Q(m, (simd_float3){-e, 0, 0}, (simd_float3){e, 0, 0}, (simd_float3){e, 0, kTownSegment}, (simd_float3){-e, 0, kTownSegment}, (simd_float3){0, 1, 0}, 0,
    V2(-e, wrap), V2(e, wrap), V2(e, wrap + kTownSegment), V2(-e, wrap + kTownSegment));
  for (int side = 0; side < 2; side++) {
    Wall w = {m, side ? 1.0f : -1.0f, L->halfWidth};
    for (int i = 0; i < P.lotCount[side]; i++) {
      Rng r = RngFor(L->seed, segment, side * 100 + i, 77);
      BuildLot(&w, cards, L, &P.lots[side][i], &r);
    }
  }
  if (P.bridge.present) BuildBridge(m, L, &P.bridge);
  for (int i = 0; i < P.stallCount; i++) BuildStall(m, L, &P, &P.stalls[i]);
  for (int i = 0; i < P.lanternCount; i++) {
    const WallLantern *wl = &P.lanterns[i];
    Wall w = {m, wl->side ? 1.0f : -1.0f, L->halfWidth};
    BuildWallLantern(&w, FaceDepth(&P.lots[wl->side][LotIndexAt(&P, wl->side, wl->z)], 0), wl->z);
  }
  for (int i = 0; i < P.lineCount; i++) BuildLine(m, L, &P, &P.lines[i]);
  *opaqueVertices = m.vertexCount;
  NSMutableData *all = [m.data mutableCopy];
  [all appendData:cards.data];
  return all;
}
