#import "ParisScene.h"

#import "Plants.h"
#import "OutdoorEnvironment.h"
#import "ParisProps.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"

#pragma mark - Street proportions

enum { kRue, kAvenue, kBoulevard };

typedef struct {
  float halfWidth;   // facade to street centre
  float sidewalk;
  float crossWidth;
  float walkFromFacade;
  int terraceRows;   // café tables in front of cafés
  BOOL trees, column, centerLine;
  float oldShare;    // share of older, plastered buildings
} StreetType;

static const StreetType kStreets[3] = {
  {6.5f, 2.4f, 10, 1.25f, 0, NO, NO, NO, 0.45f},     // rue: narrow, cars on one side
  {11.0f, 4.5f, 12, 2.2f, 1, YES, NO, YES, 0.15f},   // avenue
  {16.0f, 6.0f, 14, 3.7f, 2, YES, YES, YES, 0.05f},  // boulevard
};

static const float kDepth = 14;          // buildings' depth from the facade
static const float kFlankLength = 46;    // cross-street buildings beyond the corner building
static const float kChamfer = 2.6f;      // corner buildings are cut (pan coupé) this far along each street
static const float kCrossSidewalk = 2.0f;  // sidewalks along the cross streets

typedef struct {
  StreetType street;
  int streetType;
  float curbX;
  int storeys;
  float shops, trees, cars, tone;
  BOOL terraces;
  uint32_t seed;
} Layout;

#pragma mark - Lots

typedef struct {
  float z0, z1;  // along the block (0 … kBlockLength)
  float f0, f1;  // the street facade (corner buildings: between their cut corners)
  unsigned int building;
  int storeys, bays, type;
  float bayWidth, height;
  BOOL first, last;
} Lot;

enum { kMaxLots = 16 };

static unsigned int BuildingID(const Layout *L, int64_t block, int side, int lot, unsigned int salt) {
  return ParisHash(L->seed * 2654435761u ^ (unsigned int)(block + 1000000) * 7919u, (unsigned int)(lot * 4 + (side > 0) + salt * 64)) & 0xFFFFu;
}

static int StoreysFor(const Layout *L, unsigned int building, int type) {
  float r = ParisHashF(building, 3u);
  int s = L->storeys + (r < 0.22f ? -1 : r > 0.86f ? 1 : 0) - (type == kTypeOld);
  return MIN(MAX(s, type == kTypeOld ? 2 : 3), 6);
}

static int BaysFor(float width, int type) {
  return MAX(1, (int)lroundf(width / (type == kTypeOld ? 2.8f : 3.3f)));
}

/// The buildings of one side of block `block`, from its cross street to its end.
static int LotsOfBlock(const Layout *L, int64_t block, int side, Lot *lots) {
  Rng r = RngFor(L->seed, block, side, 11);
  float z = L->street.crossWidth;
  int n = 0;
  while (z < kBlockLength - 0.01f && n < kMaxLots) {
    float w = (float)Range(&r, 12, 21);
    if (kBlockLength - (z + w) < 9 || n == kMaxLots - 1) w = kBlockLength - z;
    Lot *lot = &lots[n];
    lot->z0 = z;
    lot->z1 = z + w;
    lot->first = n == 0;
    lot->last = NO;
    lot->building = BuildingID(L, block, side, n, 0);
    lot->type = ParisBuildingType(lot->building, L->street.oldShare);
    lot->storeys = StoreysFor(L, lot->building, lot->type);
    lot->height = ParisLevelBase(2 + lot->storeys, lot->storeys, lot->type);
    z += w;
    n++;
  }
  lots[n - 1].last = YES;
  for (int i = 0; i < n; i++) {
    Lot *lot = &lots[i];
    lot->f0 = lot->z0 + (lot->first ? kChamfer : 0);
    lot->f1 = lot->z1 - (lot->last ? kChamfer : 0);
    lot->bays = MAX(2, BaysFor(lot->f1 - lot->f0, lot->type));
    lot->bayWidth = (lot->f1 - lot->f0) / lot->bays;
  }
  return n;
}

#pragma mark - Block meshes

static void Quad(MeshBuilder *m, simd_float3 p0, simd_float3 p1, simd_float3 p2, simd_float3 p3, simd_float3 n, simd_float3 c,
                 simd_float2 t0, simd_float2 t1, simd_float2 t2, simd_float2 t3) {
  [m vertex:p0 normal:n color:c uv:t0];
  [m vertex:p1 normal:n color:c uv:t1];
  [m vertex:p2 normal:n color:c uv:t2];
  [m vertex:p0 normal:n color:c uv:t0];
  [m vertex:p2 normal:n color:c uv:t2];
  [m vertex:p3 normal:n color:c uv:t3];
}

static void Tri(MeshBuilder *m, simd_float3 p0, simd_float3 p1, simd_float3 p2, simd_float3 n, simd_float3 c) {
  [m vertex:p0 normal:n color:c uv:(simd_float2){0, 0}];
  [m vertex:p1 normal:n color:c uv:(simd_float2){1, 0}];
  [m vertex:p2 normal:n color:c uv:(simd_float2){0, 1}];
}

/// A flat rectangle on the ground (y), x0…x1 × z0…z1.
static void Ground(MeshBuilder *m, float x0, float x1, float z0, float z1, float y) {
  simd_float3 up = {0, 1, 0}, none = {0, 0, 0};
  float a = fminf(x0, x1), b = fmaxf(x0, x1);
  Quad(m, (simd_float3){a, y, z0}, (simd_float3){b, y, z0}, (simd_float3){b, y, z1}, (simd_float3){a, y, z1}, up, none, (simd_float2){0, 0},
       (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
}

/// A curb face from (x0, z0) to (x1, z1) facing `n`.
static void Curb(MeshBuilder *m, float x0, float z0, float x1, float z1, simd_float3 n) {
  m.material = kCityCurb;
  Quad(m, (simd_float3){x0, 0, z0}, (simd_float3){x1, 0, z1}, (simd_float3){x1, kSidewalkY, z1}, (simd_float3){x0, kSidewalkY, z0}, n, (simd_float3){0, 0, 0},
       (simd_float2){0, 0}, (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
}

/// Side space, for what sits on party walls: a = metres from the street facade into the building
/// (negative: toward the street), y up, z along the block.
typedef struct {
  __unsafe_unretained MeshBuilder *m;
  float side, facadeX;
} Side;

static simd_float3 P(const Side *s, float a, float y, float z) {
  return (simd_float3){s->side * (s->facadeX + a), y, z};
}

static void Box(const Side *s, float a0, float a1, float y0, float y1, float z0, float z1, simd_float3 color) {
  simd_float3 p = P(s, a0, y0, z0), q = P(s, a1, y1, z1);
  [s->m boxFrom:simd_min(p, q) to:simd_max(p, q) color:color];
}

/// The facade's stone colour (keep in sync with stoneColor in Paris.metal).
static simd_float3 StoneColor(const Layout *L, unsigned int building) {
  simd_float3 cream = Hex(0xdccfb4), grey = Hex(0xc4c0b6);
  float t = fminf(fmaxf(L->tone + (ParisHashF(building, 9u) - 0.5f) * 0.5f, 0), 1);
  return simd_mix(cream, grey, t) * (0.9f + 0.14f * ParisHashF(building, 10u));
}

/// An old building's plaster (keep in sync with plasterColor in Paris.metal).
static simd_float3 PlasterColor(unsigned int building) {
  static const uint32_t palette[] = {0xe2cfa6, 0xd9c08e, 0xe8dcc4, 0xcfc8bb, 0xdcc0a0, 0xe6d6b0};
  return Hex(palette[ParisHash(building, 44u) % 6]) * (0.92f + 0.12f * ParisHashF(building, 45u));
}

static simd_float3 WallColor(const Layout *L, unsigned int building, int type) {
  return type == kTypeOld ? PlasterColor(building) : StoneColor(L, building);
}

/// Shutter paint (keep in sync with shutterPaint in Paris.metal).
static simd_float3 ShutterPaint(unsigned int building, int type) {
  static const uint32_t persiennes[] = {0xe2e0d8, 0xbfc1bc, 0xa9a596, 0x8e9294};
  static const uint32_t volets[] = {0x5a6e7d, 0x465f4b, 0xe1dccd, 0x785040, 0x96a0a5, 0x6b4a3a};
  unsigned int h = ParisHash(building, 46u);
  return Hex(type == kTypeOld ? volets[h % 6] : persiennes[h % 4]);
}

#pragma mark Facades

/// A facade in block coordinates: u along it (metres), v up, d into the building (negative:
/// toward the street). `out` is its outward normal.
typedef struct {
  simd_float3 origin, along, out;
  float width, height;
  int bays, storeys, type;
  float bayWidth;
  unsigned int building;
  BOOL corner;              // a cut corner: one bay, usually a café below
  BOOL joinStart, joinEnd;  // another facade turns the corner at u = 0 / u = width
} Facade;

static simd_float3 FP(const Facade *f, float u, float v, float d) {
  return f->origin + f->along * u + (simd_float3){0, v, 0} - f->out * d;
}

/// A box in facade space (u0…u1, v0…v1, d0…d1); uv in metres on every face. No back face when it
/// sits against the wall.
static void FBox(MeshBuilder *m, const Facade *f, float u0, float u1, float v0, float v1, float d0, float d1, simd_float3 c) {
  simd_float3 up = {0, 1, 0}, a = f->along, o = f->out;
  Quad(m, FP(f, u0, v0, d0), FP(f, u1, v0, d0), FP(f, u1, v1, d0), FP(f, u0, v1, d0), o, c, (simd_float2){u0, v0}, (simd_float2){u1, v0},
       (simd_float2){u1, v1}, (simd_float2){u0, v1});
  if (d1 < -0.001f) {
    Quad(m, FP(f, u0, v0, d1), FP(f, u0, v1, d1), FP(f, u1, v1, d1), FP(f, u1, v0, d1), -o, c, (simd_float2){u0, v0}, (simd_float2){u0, v1},
         (simd_float2){u1, v1}, (simd_float2){u1, v0});
  }
  Quad(m, FP(f, u0, v0, d0), FP(f, u0, v0, d1), FP(f, u1, v0, d1), FP(f, u1, v0, d0), -up, c, (simd_float2){u0, d0}, (simd_float2){u0, d1},
       (simd_float2){u1, d1}, (simd_float2){u1, d0});
  Quad(m, FP(f, u0, v1, d0), FP(f, u1, v1, d0), FP(f, u1, v1, d1), FP(f, u0, v1, d1), up, c, (simd_float2){u0, d0}, (simd_float2){u1, d0},
       (simd_float2){u1, d1}, (simd_float2){u0, d1});
  Quad(m, FP(f, u0, v0, d0), FP(f, u0, v1, d0), FP(f, u0, v1, d1), FP(f, u0, v0, d1), -a, c, (simd_float2){d0, v0}, (simd_float2){d0, v1},
       (simd_float2){d1, v1}, (simd_float2){d1, v0});
  Quad(m, FP(f, u1, v0, d0), FP(f, u1, v0, d1), FP(f, u1, v1, d1), FP(f, u1, v1, d0), a, c, (simd_float2){d0, v0}, (simd_float2){d1, v0},
       (simd_float2){d1, v1}, (simd_float2){d0, v1});
}

/// A railing along the facade at depth d (uv: metres along, 0…1 up).
static void FRailing(MeshBuilder *m, const Facade *f, float u0, float u1, float d, float v, float height) {
  m.material = kCityRailing;
  float w = u1 - u0;
  Quad(m, FP(f, u0, v, d), FP(f, u1, v, d), FP(f, u1, v + height, d), FP(f, u0, v + height, d), f->out, (simd_float3){0, 0, 0}, (simd_float2){0, 0},
       (simd_float2){w, 0}, (simd_float2){w, 1}, (simd_float2){0, 1});
}

/// A railing across the facade's depth at u, from d0 to d1.
static void FRailingSide(MeshBuilder *m, const Facade *f, float u, float d0, float d1, float v, float height) {
  m.material = kCityRailing;
  float w = fabsf(d1 - d0);
  Quad(m, FP(f, u, v, d0), FP(f, u, v, d1), FP(f, u, v + height, d1), FP(f, u, v + height, d0), f->along, (simd_float3){0, 0, 0},
       (simd_float2){0, 0}, (simd_float2){w, 0}, (simd_float2){w, 1}, (simd_float2){0, 1});
}

/// A piece of wall (kCityFacade, uv = facade metres).
static void WallRect(MeshBuilder *m, const Facade *f, float u0, float u1, float v0, float v1, simd_float3 code) {
  if (u1 - u0 < 1e-3f || v1 - v0 < 1e-3f) return;
  m.material = kCityFacade;
  Quad(m, FP(f, u0, v0, 0), FP(f, u1, v0, 0), FP(f, u1, v1, 0), FP(f, u0, v1, 0), f->out, code, (simd_float2){u0, v0}, (simd_float2){u1, v0},
       (simd_float2){u1, v1}, (simd_float2){u0, v1});
}

/// The ground floor bay kind of a facade's bay.
static int FacadeBayKind(const Facade *f, const Layout *L, int bay) {
  return f->corner ? ParisCornerKind(f->building, L->shops) : ParisBayKind(f->building, bay, f->bays, L->shops);
}

/// Walls, openings (reveals, the glass or door set back), sills, shutters, balconies.
static void EmitFacade(MeshBuilder *m, const Facade *f, const Layout *L) {
  float bw = f->bayWidth, W = f->width;
  int S = f->storeys, T = f->type;
  BOOL old = T == kTypeOld;
  simd_float3 code = {bw, ParisFacadeCode(S, f->bays, f->corner, T), (float)f->building};
  simd_float3 wall = WallColor(L, f->building, T), paint = ShutterPaint(f->building, T), up = {0, 1, 0};
  float ww = ParisWindowWidth(bw, T);
  for (int level = 0; level < 2 + S; level++) {
    float base = ParisLevelBase(level, S, T), lh = ParisLevelHeight(level, S, T);
    for (int b = 0; b < f->bays; b++) {
      float x0 = b * bw, x1 = x0 + bw, xc = x0 + bw / 2;
      int kind = level == 0 ? FacadeBayKind(f, L, b) : -1;
      ParisOpening o = ParisOpeningIn(level, kind, T, bw, lh);
      float ol = xc + o.lo.x, oh = xc + o.hi.x, vl = base + o.lo.y, vh = base + o.hi.y, D = o.depth;
      WallRect(m, f, x0, x1, base, vl, code);
      WallRect(m, f, x0, x1, vh, base + lh, code);
      WallRect(m, f, x0, ol, vl, vh, code);
      WallRect(m, f, oh, x1, vl, vh, code);
      // Reveals (uv: metres along the edge, 0 at the facade … 1 at the glass).
      m.material = kCityReveal;
      simd_float3 rc = wall * 0.97f;
      Quad(m, FP(f, ol, vl, 0), FP(f, ol, vh, 0), FP(f, ol, vh, D), FP(f, ol, vl, D), f->along, rc, (simd_float2){vl, 0}, (simd_float2){vh, 0},
           (simd_float2){vh, 1}, (simd_float2){vl, 1});
      Quad(m, FP(f, oh, vl, 0), FP(f, oh, vl, D), FP(f, oh, vh, D), FP(f, oh, vh, 0), -f->along, rc, (simd_float2){vl, 0}, (simd_float2){vl, 1},
           (simd_float2){vh, 1}, (simd_float2){vh, 0});
      Quad(m, FP(f, ol, vh, 0), FP(f, ol, vh, D), FP(f, oh, vh, D), FP(f, oh, vh, 0), -up, rc, (simd_float2){ol, 0}, (simd_float2){ol, 1},
           (simd_float2){oh, 1}, (simd_float2){oh, 0});
      if (o.lo.y > 0.2f) {
        Quad(m, FP(f, ol, vl, 0), FP(f, oh, vl, 0), FP(f, oh, vl, D), FP(f, ol, vl, D), up, rc, (simd_float2){ol, 0}, (simd_float2){oh, 0},
             (simd_float2){oh, 1}, (simd_float2){ol, 1});
      }
      // What's set back in the opening: glass, a shop window or a door (drawn by the shader).
      m.material = kCityWindow;
      Quad(m, FP(f, ol, vl, D), FP(f, oh, vl, D), FP(f, oh, vh, D), FP(f, ol, vh, D), f->out, code, (simd_float2){ol, vl}, (simd_float2){oh, vl},
           (simd_float2){oh, vh}, (simd_float2){ol, vh});
      // Sills under windows that have no balcony.
      BOOL windowAbove = level >= 1 || kind == kBayWall;
      BOOL balconette = !old && level >= 3 && level < 1 + S;
      BOOL balcony = !old && (level == 2 || level == 1 + S);
      if (windowAbove && !balconette && !balcony && o.lo.y > 0.2f) {
        m.material = kCityTrim;
        FBox(m, f, ol - 0.07f, oh + 0.07f, vl - 0.07f, vl, -0.07f, D * 0.6f, wall * 0.98f);
      }
      // A small cornice over the noble floor's windows.
      if (!old && level == 2) {
        m.material = kCityTrim;
        FBox(m, f, ol - 0.24f, oh + 0.24f, vh + 0.2f, vh + 0.36f, -0.13f, 0, wall);
      }
      if (balconette) {
        float half = ww / 2 + 0.14f;
        m.material = kCityTrim;
        FBox(m, f, xc - half, xc + half, base - 0.1f, base + 0.02f, -0.28f, 0, wall);
        FRailing(m, f, xc - half + 0.03f, xc + half - 0.03f, -0.25f, base + 0.02f, 0.92f);
      }
      // Shutters: open ones fold into the reveal (metal persiennes) or lie against the wall
      // (wooden); closed ones are drawn on the glass.
      if (ParisShutter(f->building, level, b, T) == kShutterOpen) {
        m.material = kCityShutter;
        if (old) {
          float pw = (oh - ol) * 0.5f + 0.02f;
          FBox(m, f, ol - pw - 0.03f, ol - 0.03f, vl - 0.02f, vh + 0.02f, -0.045f, -0.008f, paint);
          FBox(m, f, oh + 0.03f, oh + pw + 0.03f, vl - 0.02f, vh + 0.02f, -0.045f, -0.008f, paint);
        } else {
          FBox(m, f, ol, ol + 0.12f, vl + 0.03f, vh - 0.03f, 0.04f, 0.24f, paint);
          FBox(m, f, oh - 0.12f, oh, vl + 0.03f, vh - 0.03f, 0.04f, 0.24f, paint);
        }
      }
    }
    // Balconies along the noble and top floors, on corbels.
    if (!old && (level == 2 || level == 1 + S)) {
      float depth = level == 2 ? 0.85f : 0.68f, y = base;
      float e0 = f->joinStart ? -depth * 0.414f : 0.04f, e1 = f->joinEnd ? W + depth * 0.414f : W - 0.04f;
      float lift = f->corner ? 0.004f : 0;  // where two balconies overlap at a corner
      m.material = kCityTrim;
      FBox(m, f, e0, e1, y - 0.22f + lift, y + lift, -depth, 0, wall);
      FBox(m, f, e0, e1, y - 0.3f + lift, y - 0.2f + lift, -depth - 0.05f, -depth + 0.06f, wall * 0.95f);
      float r = depth - 0.03f;
      FRailing(m, f, f->joinStart ? -r * 0.414f : 0.08f, f->joinEnd ? W + r * 0.414f : W - 0.08f, -r, y, 1.0f);
      if (!f->joinStart) FRailingSide(m, f, 0.08f, -r, 0, y, 1.0f);
      if (!f->joinEnd) FRailingSide(m, f, W - 0.08f, -r, 0, y, 1.0f);
      m.material = kCityTrim;
      for (int b = 0; b < f->bays; b++) {
        float xc = (b + 0.5f) * bw;
        for (int e = -1; e <= 1; e += 2) {
          float uc = xc + e * (ww / 2 + 0.33f);
          if (uc < 0.2f || uc > W - 0.2f) continue;
          FBox(m, f, uc - 0.09f, uc + 0.09f, y - 0.75f, y - 0.22f, -depth + 0.12f, 0, wall * 0.97f);
        }
      }
    }
  }
  // Over the shops: a band (Haussmann) the width of the facade.
  if (!old) {
    m.material = kCityTrim;
    FBox(m, f, f->joinStart ? -0.05f : 0, f->joinEnd ? W + 0.05f : W, 3.92f, 4.14f, -0.12f, 0, wall * 1.02f);
  }
}

/// The main cornice and the mansard roof with dormers. Where another facade turns the corner the
/// roof is hipped (cut back along the corner's bisector, 22.5° off this facade's normal).
static void EmitRoof(MeshBuilder *m, const Facade *f, simd_float3 wall) {
  float h = f->height, W = f->width;
  float t0 = f->joinStart ? 0.4142f : 0, t1 = f->joinEnd ? 0.4142f : 0;
  BOOL old = f->type == kTypeOld;
  m.material = kCityTrim;
  FBox(m, f, -t0 * 0.28f, W + t1 * 0.28f, h - 0.4f, h - 0.12f, -0.28f, 0, wall * 0.97f);
  FBox(m, f, -t0 * 0.6f, W + t1 * 0.6f, h - 0.12f, h + 0.3f, old ? -0.4f : -0.6f, 0.15f, wall);
  simd_float3 zinc = Hex(0x6e7883), up = {0, 1, 0};
  float y0 = h + 0.3f, y1 = h + 3.3f, y2 = h + 4.5f;
  simd_float3 steep = simd_normalize(f->out * 3.0f + up * 1.1f), flat = simd_normalize(f->out * 1.2f + up * 5.6f);
  m.material = kCityZinc;
  float s0 = t0 * 0.3f, s1 = W - t1 * 0.3f, s2 = t0 * 1.4f, s3 = W - t1 * 1.4f;
  float f2 = fminf(t0 * 7.0f, W / 2), f3 = fmaxf(W - t1 * 7.0f, W / 2);
  Quad(m, FP(f, s0, y0, 0.3f), FP(f, s1, y0, 0.3f), FP(f, s3, y1, 1.4f), FP(f, s2, y1, 1.4f), steep, zinc, (simd_float2){s0, 0}, (simd_float2){s1, 0},
       (simd_float2){s3, 3.2f}, (simd_float2){s2, 3.2f});
  Quad(m, FP(f, s2, y1, 1.4f), FP(f, s3, y1, 1.4f), FP(f, f3, y2, 7.0f), FP(f, f2, y2, 7.0f), flat, zinc * 0.9f, (simd_float2){s2, 3.2f},
       (simd_float2){s3, 3.2f}, (simd_float2){f3, 9}, (simd_float2){f2, 9});
  for (int e = 0; e < 2; e++) {  // roof ends against a neighbour
    if (e == 0 ? f->joinStart : f->joinEnd) continue;
    float u = e ? W : 0;
    Quad(m, FP(f, u, y0, 0.3f), FP(f, u, y0, 7.0f), FP(f, u, y2, 7.0f), FP(f, u, y1, 1.4f), e ? f->along : -f->along, zinc * 0.85f,
         (simd_float2){0, 0}, (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
  }
  float bw = f->bayWidth;
  for (int b = 0; b < f->bays; b++) {
    if (bw < 2.6f && b % 2) continue;
    float uc = (b + 0.5f) * bw;
    if (uc - 0.7f < t0 * 1.7f || uc + 0.7f > W - t1 * 1.7f) continue;
    float d0 = y0 + 0.5f, d1 = y0 + 2.0f, top = d1 + 0.45f;
    m.material = kCityDormer;
    Quad(m, FP(f, uc - 0.5f, d0, 0.55f), FP(f, uc + 0.5f, d0, 0.55f), FP(f, uc + 0.5f, d1, 0.55f), FP(f, uc - 0.5f, d1, 0.55f), f->out, wall,
         (simd_float2){0, 0}, (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
    m.material = kCityTrim;
    FBox(m, f, uc - 0.62f, uc + 0.62f, d0 - 0.12f, d0, 0.5f, 0.6f, wall);  // sill
    Tri(m, FP(f, uc - 0.62f, d1, 0.5f), FP(f, uc + 0.62f, d1, 0.5f), FP(f, uc, top, 0.5f), f->out, wall);  // pediment
    m.material = kCityZinc;
    for (int e = -1; e <= 1; e += 2) {
      Quad(m, FP(f, uc + e * 0.52f, d0, 0.55f), FP(f, uc + e * 0.52f, d0, 1.5f), FP(f, uc + e * 0.52f, d1, 1.5f), FP(f, uc + e * 0.52f, d1, 0.55f),
           f->along * (float)e, zinc, (simd_float2){0, 0}, (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
      simd_float3 n = simd_normalize(up * 1.24f + f->along * (e * 0.45f));
      Quad(m, FP(f, uc + e * 0.68f, d1, 0.45f), FP(f, uc + e * 0.68f, d1, 1.7f), FP(f, uc, top, 1.7f), FP(f, uc, top, 0.45f), n, zinc,
           (simd_float2){0, 0}, (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
    }
  }
}

/// The shop unit and kind of a facade's ground-floor bay (kind -1 when it isn't a shop).
static int FacadeShop(const Facade *f, const Layout *L, int bay, int *first, int *count) {
  int kind = FacadeBayKind(f, L, bay);
  if (kind != kBayShop && kind != kBayCafe) return -1;
  int unit = f->corner ? 15 * 16 + 1 : ParisShopUnit(f->building, bay, f->bays);
  *first = unit / 16;
  *count = unit % 16;
  return ParisShopType(f->building, *first);
}

/// Awnings over most shops and all cafés (one per unit, its name on the valance at cafés), lit
/// signs standing out from the wall: a pharmacy's green cross, a tobacconist's red sign.
static void EmitAwnings(MeshBuilder *m, const Facade *f, const Layout *L) {
  float bw = f->bayWidth, h0 = ParisLevelHeight(0, f->storeys, f->type);
  simd_float3 up = {0, 1, 0};
  for (int b = 0; b < f->bays; b++) {
    int first, count, shop = FacadeShop(f, L, b, &first, &count);
    if (shop < 0 || shop == kShopClosed) continue;
    int unitStart = f->corner ? 0 : first;
    if (b != unitStart) continue;  // once per unit
    float u0 = unitStart * bw, u1 = (unitStart + (f->corner ? 1 : count)) * bw;
    BOOL cafe = shop == kShopCafe || shop == kShopRestaurant;
    int word = ParisSignWord(f->building, first, shop);
    if (cafe || ParisHashF(f->building, 300u + b) < 0.55f) {
      static const uint32_t cafeCloth[] = {0x8c1c1c, 0x1d4a2c, 0x1d2a4a, 0x7a1a2a}, shopCloth[] = {0xd8cdb0, 0x55705a, 0x2a2a2a, 0x9a3a2a, 0x2c3e5c};
      uint32_t hex = cafe ? cafeCloth[ParisHash(f->building, 21u + first) % 4] : shopCloth[ParisHash(f->building, 22u + first) % 5];
      simd_float3 cloth = Hex(hex);
      ParisOpening o = ParisOpeningIn(0, cafe ? kBayCafe : kBayShop, f->type, bw, h0);
      float top = fminf(o.hi.y + 0.6f, h0 - 0.25f), za = u0 + 0.08f, zb = u1 - 0.08f, w = zb - za;
      float out = L->streetType == kRue ? -1.1f : cafe ? -2.0f : -1.5f;
      m.material = kCityAwning;
      simd_float3 n = simd_normalize(f->out * 0.85f + up * 1.6f);
      Quad(m, FP(f, za, top, 0), FP(f, zb, top, 0), FP(f, zb, top - 0.8f, out), FP(f, za, top - 0.8f, out), n, cloth, (simd_float2){0, 0},
           (simd_float2){w, 0}, (simd_float2){w, 1}, (simd_float2){0, 1});
      float k = cafe && word >= 0 ? 2 + 2 * (word + 32 * lroundf(w * 10)) : 0;  // the valance's text (Paris.metal)
      Quad(m, FP(f, za, top - 1.05f, out), FP(f, zb, top - 1.05f, out), FP(f, zb, top - 0.8f, out), FP(f, za, top - 0.8f, out), f->out, cloth * 0.9f,
           (simd_float2){0, k}, (simd_float2){w, k}, (simd_float2){w, k + (k > 0)}, (simd_float2){0, k + (k > 0)});
    }
    float sv = fminf(3.2f, h0 - 0.8f);
    if (shop == kShopPharmacy) {
      m.material = kCityGlow;
      simd_float3 green = Hex(0x18c060);
      FBox(m, f, u0 - 0.05f, u0 + 0.05f, sv, sv + 0.7f, -0.62f, -0.18f, green);
      FBox(m, f, u0 - 0.05f, u0 + 0.05f, sv + 0.23f, sv + 0.47f, -0.75f, -0.05f, green);
    } else if (shop == kShopCafe && word == 4) {  // "BAR TABAC": the red sign
      m.material = kCityGlow;
      FBox(m, f, u0 - 0.05f, u0 + 0.05f, sv, sv + 0.75f, -0.55f, -0.2f, Hex(0xc0281c));
    }
  }
}

static void FullFacade(MeshBuilder *m, const Facade *f, const Layout *L) {
  EmitFacade(m, f, L);
  EmitRoof(m, f, WallColor(L, f->building, f->type));
  EmitAwnings(m, f, L);
}

/// One building: its street facade, at corners the cut corner and the facade along the cross
/// street, party walls where a neighbour is lower, chimneys.
static void Building(MeshBuilder *m, const Layout *L, const Lot *lot, float side, float hw) {
  Facade street = {.origin = {side * hw, 0, lot->f0}, .along = {0, 0, 1}, .out = {-side, 0, 0}, .width = lot->f1 - lot->f0,
                   .height = lot->height, .bays = lot->bays, .storeys = lot->storeys, .type = lot->type, .bayWidth = lot->bayWidth,
                   .building = lot->building, .joinStart = lot->first, .joinEnd = lot->last};
  FullFacade(m, &street, L);
  for (int e = 0; e < 2; e++) {
    if (e == 0 ? !lot->first : !lot->last) continue;
    float zc = e == 0 ? lot->z0 : lot->z1, dz = e == 0 ? -1 : 1;
    simd_float3 a = {side * hw, 0, zc - dz * kChamfer}, b = {side * (hw + kChamfer), 0, zc};
    Facade cut = street;
    cut.origin = a;
    cut.along = simd_normalize(b - a);
    cut.out = simd_normalize((simd_float3){-side, 0, dz});
    cut.width = kChamfer * (float)M_SQRT2;
    cut.bays = 1;
    cut.bayWidth = cut.width;
    cut.corner = YES;
    cut.joinStart = cut.joinEnd = YES;
    FullFacade(m, &cut, L);
    Facade cross = street;
    cross.origin = b;
    cross.along = (simd_float3){side, 0, 0};
    cross.out = (simd_float3){0, 0, dz};
    cross.width = kDepth - kChamfer;
    cross.bays = BaysFor(cross.width, lot->type);
    cross.bayWidth = cross.width / cross.bays;
    cross.joinStart = YES;
    cross.joinEnd = NO;
    FullFacade(m, &cross, L);
  }

  Side s = {m, side, hw};
  float h = lot->height, z0 = lot->z0, z1 = lot->z1;
  simd_float3 party = WallColor(L, lot->building, lot->type) * 0.82f;
  m.material = kCityTrim;
  for (int e = 0; e < 2; e++) {  // party walls (seen where a neighbour is lower)
    if (e == 0 ? lot->first : lot->last) continue;
    float z = e ? z1 : z0;
    Quad(m, P(&s, 0, 0, z), P(&s, kDepth, 0, z), P(&s, kDepth, h + 4.6f, z), P(&s, 0, h + 0.3f, z), (simd_float3){0, 0, e ? 1.0f : -1.0f}, party,
         (simd_float2){0, 0}, (simd_float2){1, 0}, (simd_float2){1, 1}, (simd_float2){0, 1});
  }
  // Chimney stacks on the party walls, and one in the middle of long roofs, with clay pots.
  simd_float3 plaster = Hex(0xb8a88c), pot = Hex(0xa45a36);
  float y1 = h + 3.3f, y2 = h + 4.5f;
  for (int e = 0; e < 3; e++) {
    if (e == 1 && !lot->last) continue;
    if (e == 2 && (z1 - z0 < 15 || ParisHashF(lot->building, 33u) < 0.4f)) continue;
    float z = e == 0 ? z0 + (lot->first ? 6.0f : 0) : e == 1 ? z1 - (lot->last ? 6.0f : 0) : (z0 + z1) / 2;
    float a0 = 3.6f + 1.5f * ParisHashF(lot->building, 30u + e);
    int pots = 3 + (int)(ParisHashF(lot->building, 34u + e) * 4);
    float len = 0.3f + pots * 0.55f;
    Box(&s, a0, a0 + len, y1 - 0.5f, y2 + 1.6f, z - 0.35f, z + 0.35f, plaster);
    Box(&s, a0 - 0.05f, a0 + len + 0.05f, y2 + 1.45f, y2 + 1.6f, z - 0.4f, z + 0.4f, plaster * 0.9f);
    for (int k = 0; k < pots; k++) {
      float hk = 0.3f + 0.25f * ParisHashF(lot->building, 50u + e * 8 + k);
      Box(&s, a0 + 0.2f + k * 0.55f, a0 + 0.42f + k * 0.55f, y2 + 1.6f, y2 + 1.6f + hk, z - 0.11f, z + 0.11f, pot * (0.85f + 0.3f * ParisHashF(lot->building, 60u + k)));
    }
  }
}

/// Block `block`'s mesh, in block coordinates (z from the block's start): buildings on both
/// sides, the buildings along its cross street, the road, sidewalks and curbs.
static NSData *BlockMesh(const Layout *L, int64_t block) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:(uint32_t)block];
  float hw = L->street.halfWidth, curb = L->curbX, cross = L->street.crossWidth, sw = kCrossSidewalk;
  float far = hw + kDepth + kFlankLength;
  for (int side = -1; side <= 1; side += 2) {
    Lot lots[kMaxLots];
    int n = LotsOfBlock(L, block, side, lots);
    for (int i = 0; i < n; i++) Building(m, L, &lots[i], side, hw);
    // Along the cross street: two more buildings beyond each corner building, on both of its sides.
    for (int c = 0; c < 2; c++) {
      float z = c == 0 ? cross : 0;
      float dir = c == 0 ? -1 : 1;
      for (int k = 0; k < 2; k++) {
        unsigned int b = BuildingID(L, block, side, k, 7u + c);
        int T = ParisBuildingType(b, L->street.oldShare), S = StoreysFor(L, b, T);
        float a0 = kDepth + k * kFlankLength / 2, w = kFlankLength / 2;
        int bays = BaysFor(w, T);
        Facade f = {.origin = {side * (hw + a0), 0, z}, .along = {(float)side, 0, 0}, .out = {0, 0, dir}, .width = w,
                    .height = ParisLevelBase(2 + S, S, T), .bays = bays, .storeys = S, .type = T, .bayWidth = w / bays, .building = b};
        FullFacade(m, &f, L);
      }
    }
    // Sidewalks: along the street, along both sides of the cross street, round the cut corners.
    m.material = kCitySidewalk;
    Ground(m, side * curb, side * (hw + 0.4f), cross, kBlockLength, kSidewalkY);
    Ground(m, side * curb, side * far, 0, sw, kSidewalkY);
    Ground(m, side * curb, side * far, cross - sw, cross, kSidewalkY);
    simd_float3 up = {0, 1, 0}, none = {0, 0, 0};
    for (int e = 0; e < 2; e++) {
      float z = e ? kBlockLength : cross, dz = e ? -1 : 1;
      Tri(m, (simd_float3){side * hw, kSidewalkY, z}, (simd_float3){side * (hw + kChamfer + 0.4f), kSidewalkY, z},
          (simd_float3){side * hw, kSidewalkY, z + dz * (kChamfer + 0.4f)}, up, none);
    }
    float x0 = side * curb, x1 = side * far;
    Curb(m, x0, cross - sw, x0, kBlockLength, (simd_float3){-(float)side, 0, 0});
    Curb(m, x0, 0, x0, sw, (simd_float3){-(float)side, 0, 0});
    Curb(m, x0, sw, x1, sw, (simd_float3){0, 0, 1});
    Curb(m, x0, cross - sw, x1, cross - sw, (simd_float3){0, 0, -1});
    // The cross street's road beside the main road.
    m.material = kCityRoad;
    Ground(m, x0, x1, sw, cross - sw, 0);
  }
  m.material = kCityRoad;
  Ground(m, -curb, curb, 0, kBlockLength, 0);
  return m.data;
}

#pragma mark - Scene

/// A cached block mesh, its triangles sorted by city_fs group (ParisMaterialGroup).
@interface CityBlock : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NSUInteger vertices;
@property(nonatomic) NSUInteger *groupStart, *groupCount;  // kCityGroups each
@end

@implementation CityBlock {
  NSUInteger _start[kCityGroups], _count[kCityGroups];
}

- (instancetype)initWithMesh:(NSData *)mesh device:(id<MTLDevice>)device {
  if (!(self = [super init])) return nil;
  // Sort the triangles by group: one draw per group, each with its own pipeline.
  const MeshVertex *v = mesh.bytes;
  NSUInteger triangles = mesh.length / sizeof(MeshVertex) / 3;
  NSMutableData *sorted[kCityGroups];
  for (int g = 0; g < kCityGroups; g++) sorted[g] = [NSMutableData data];
  for (NSUInteger t = 0; t < triangles; t++) {
    int g = ParisMaterialGroup((int)lroundf(v[t * 3].material));
    [sorted[g] appendBytes:&v[t * 3] length:3 * sizeof(MeshVertex)];
  }
  NSMutableData *all = [NSMutableData dataWithCapacity:mesh.length];
  for (int g = 0; g < kCityGroups; g++) {
    _start[g] = all.length / sizeof(MeshVertex);
    _count[g] = sorted[g].length / sizeof(MeshVertex);
    [all appendData:sorted[g]];
  }
  _buffer = SceneBuffer(device, all);
  _vertices = all.length / sizeof(MeshVertex);
  _groupStart = _start;
  _groupCount = _count;
  return self;
}

@end

// Prop draw groups: the props, then plane trees (3 variants × full/lite).
enum { kTreeGroups = kPlantVariants * 2, kGroups = PropKindCount + kTreeGroups };

@implementation ParisScene {
  id<MTLDevice> _device;
  id<MTLRenderPipelineState> _cityPipes[kCityGroups], _cityShadowPipe, _plantPipe, _plantShadowPipe;
  id<MTLDepthStencilState> _depthOn;
  id<MTLTexture> _atlas;
  id<MTLBuffer> _meshes[kGroups];
  NSUInteger _meshVertices[kGroups];
  NSMutableDictionary<NSNumber *, CityBlock *> *_blocks;

  id<MTLBuffer> _instances, _lots;
  NSUInteger _groupBase[kGroups], _groupCount[kGroups], _instanceTotal;

  double _originZ;
  int64_t _builtTile;
  uint64_t _builtLayout;
  Layout _layout;
  ParisUniforms _uniforms;
  PlantUniforms _treeUniforms, _propUniforms;
}

+ (void)load {
  [SceneRegistry registerScene:self];
}

+ (NSString *)identifier {
  return @"paris";
}

+ (NSString *)title {
  return @"Paris street";
}

+ (NSArray<SceneParameter *> *)parameters {
  NSString *street = @"Street", *life = @"Street life";
  return @[
    [OutdoorEnvironment lightingParameter:OutdoorEnvironment.presetNames default:@"Sunny"],
    [[SceneParameter choiceWithKey:@"street" title:@"Street" section:street choices:@[ @"Rue", @"Avenue", @"Boulevard" ] value:1] relayout],
    [SceneParameter choiceWithKey:@"sidewalk" title:@"Walk on the" section:street choices:@[ @"Left sidewalk", @"Right sidewalk" ] value:1],
    [[SceneParameter sliderWithKey:@"storeys" title:@"Storeys" section:street minimum:3 maximum:6 step:1 value:4 format:@"%.0f + mansard"] relayout],
    [[SceneParameter sliderWithKey:@"tone" title:@"Stone" section:street minimum:0 maximum:1 step:0.05 value:0.25 format:@"%.2f"] relayout],
    [SceneParameter choiceWithKey:@"paving" title:@"Road" section:street choices:@[ @"Asphalt", @"Cobblestones" ] value:0],
    [SceneParameter seedWithKey:@"seed" title:@"New Street" section:street value:3],
    [[SceneParameter sliderWithKey:@"shops" title:@"Shops and cafés" section:life minimum:0 maximum:1 step:0.05 value:0.65 format:@"%.2f"] relayout],
    [[SceneParameter toggleWithKey:@"terraces" title:@"Café terraces" section:life value:YES] relayout],
    [[SceneParameter sliderWithKey:@"trees" title:@"Plane trees" section:life minimum:0 maximum:1 step:0.05 value:0.85 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"cars" title:@"Parked cars" section:life minimum:0 maximum:1 step:0.05 value:0.6 format:@"%.2f"] relayout],
  ];
}

+ (Class)environment {
  return OutdoorEnvironment.class;
}

+ (NSArray<NSString *> *)shaderSources {
  // The kit's plant shaders draw the trees and props.
  return @[ @"Plants.h", @"Plants.metal", @"ParisScene.h", @"Paris.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _blocks = [NSMutableDictionary dictionary];
  _builtTile = INT64_MIN;
  _builtLayout = UINT64_MAX;
  _originZ = NAN;

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, YES);
  pd.alphaToCoverageEnabled = YES;  // railings and leaves are cut out
  pd.vertexFunction = [lib newFunctionWithName:@"city_vs"];
  for (int g = 0; g < kCityGroups; g++) {
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    [cv setConstantValue:&g type:MTLDataTypeInt atIndex:0];
    pd.fragmentFunction = [lib newFunctionWithName:@"city_fs" constantValues:cv error:error];
    _cityPipes[g] = pd.fragmentFunction ? [device newRenderPipelineStateWithDescriptor:pd error:error] : nil;
    if (!_cityPipes[g]) return nil;
  }
  pd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"paris_prop_fs" constantValues:[MTLFunctionConstantValues new] error:error];
  _plantPipe = pd.fragmentFunction ? [device newRenderPipelineStateWithDescriptor:pd error:error] : nil;
  MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
  sd.depthAttachmentPixelFormat = kShadowFormat;
  sd.vertexFunction = [lib newFunctionWithName:@"city_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"city_shadow_fs"];
  _cityShadowPipe = [device newRenderPipelineStateWithDescriptor:sd error:error];
  sd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"plant_shadow_fs"];
  _plantShadowPipe = [device newRenderPipelineStateWithDescriptor:sd error:error];
  _atlas = FoliageAtlas(device, lib, error);
  if (!_plantPipe || !_cityShadowPipe || !_plantShadowPipe || !_atlas) return nil;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthOn = [device newDepthStencilStateWithDescriptor:dd];

  for (int k = 0; k < kGroups; k++) {
    NSData *mesh = k < PropKindCount ? PropMesh((PropKind)k) : PlantMesh(PlantPlane, (k - PropKindCount) / 2, (k - PropKindCount) % 2, NO);
    _meshes[k] = SceneBuffer(device, mesh);
    _meshVertices[k] = mesh.length / sizeof(MeshVertex);
  }
  _treeUniforms.wind = 0.3f;
  return self;
}

- (NSUInteger)instanceCount {
  return _instanceTotal;
}

- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values {
  int type = (int)MIN(MAX([values index:@"street"], 0), 2);
  double side = [values index:@"sidewalk"] == 0 ? -1 : 1;
  double x = side * (kStreets[type].halfWidth - kStreets[type].walkFromFacade);
  return (WalkPoint){simd_make_double3(x, kSidewalkY, metres), simd_make_double3(0, 0, 1)};
}

- (void)adjustLighting:(FrameUniforms *)u values:(SceneValues *)values {
  u->fogDensity *= 0.85f;  // city air: the street's far end stays visible
  u->aoStrength = 1;
  _uniforms.wetness = u->wetness;
  u->shadowSoftness = 0.012f;  // the sun's disk (0.5°) widened by the haze
}

#pragma mark Layout

- (void)readSettings:(SceneValues *)values {
  Layout *L = &_layout;
  L->streetType = (int)MIN(MAX([values index:@"street"], 0), 2);
  L->street = kStreets[L->streetType];
  L->curbX = L->street.halfWidth - L->street.sidewalk;
  L->storeys = (int)lround([values number:@"storeys"]);
  L->shops = (float)[values number:@"shops"];
  L->trees = (float)[values number:@"trees"];
  L->cars = (float)[values number:@"cars"];
  L->tone = (float)[values number:@"tone"];
  L->terraces = [values flag:@"terraces"];
  L->seed = (uint32_t)[values number:@"seed"];
  _uniforms.halfWidth = L->street.halfWidth;
  _uniforms.curbX = L->curbX;
  _uniforms.crossWidth = L->street.crossWidth;
  _uniforms.centerLine = L->street.centerLine ? 1 : 0;
  _uniforms.facadeTone = L->tone;
  _uniforms.lampX = L->curbX + 0.4f;
  _uniforms.shops = L->shops;
  _uniforms.roofHeight = ParisLevelBase(2 + L->storeys, L->storeys, kTypeHaussmann) + 2.0f;  // the cornice, and the mansard set back
  _uniforms.treeX = L->street.trees ? L->curbX + 0.8f : 0;
  _uniforms.treeCover = L->trees * 0.85f;
  _uniforms.parking = L->cars <= 0 ? 0 : L->streetType == kRue ? 1 : 2;
  [_blocks removeAllObjects];
}

static void AddProp(NSMutableData *group, double x, double y, double z, double originZ, double yaw, simd_float4 tint, double height, double width,
                    double bright) {
  PlantInstance p;
  p.posYaw = simd_make_float4((float)x, (float)y, (float)(z - originZ), (float)yaw);
  p.shape = simd_make_float4((float)width, (float)height, (float)bright, (float)fmod(z * 1.37, 6.28));
  p.tint = tint;
  [group appendBytes:&p length:sizeof p];
}

/// A car's paint, as common as on a real street: mostly white, grey, silver and black.
static simd_float3 CarPaint(Rng *r) {
  static const struct {
    uint32_t hex;
    float share;
  } paints[] = {{0xe8e8e4, 0.2f}, {0xa8abae, 0.18f}, {0x5f6366, 0.16f}, {0x18191b, 0.16f}, {0x22304a, 0.08f}, {0x8a1a1a, 0.06f},
                {0xc8bea8, 0.05f}, {0x2f3b30, 0.04f}, {0x7a96b0, 0.04f}, {0xd8a020, 0.03f}};
  double x = Rand(r);
  for (size_t i = 0; i < sizeof paints / sizeof paints[0]; i++) {
    if ((x -= paints[i].share) < 0) return Hex(paints[i].hex);
  }
  return Hex(paints[0].hex);
}

// Props and street trees for the blocks around the camera.
- (void)rebuildPropsAround:(double)camZ {
  const Layout *L = &_layout;
  NSMutableData *groups[kGroups];
  for (int k = 0; k < kGroups; k++) groups[k] = [NSMutableData data];
  double zMin = camZ - 330, zMax = camZ + 40;
  float hw = L->street.halfWidth, curb = L->curbX, cross = L->street.crossWidth;
  simd_float4 none = {1, 1, 1, 0};

  for (int64_t block = (int64_t)floor(zMin / kBlockLength); block <= (int64_t)floor(zMax / kBlockLength); block++) {
    double bz = block * (double)kBlockLength;
    for (int side = -1; side <= 1; side += 2) {
      Rng r = RngFor(L->seed, block, side, 21);
      // Plane trees with their grates.
      if (L->street.trees) {
        for (double z = cross + 5; z < kBlockLength - 4; z += 9) {
          if (Rand(&r) > L->trees) continue;
          double tz = bz + z, tx = side * (curb + 0.8);
          int variant = (int)(Rand(&r) * kPlantVariants) % kPlantVariants;
          BOOL lite = fabs(tz - camZ) > 45;
          simd_float3 leaves = Hex(0x5b7d34) * (float)Range(&r, 0.85, 1.1);
          AddProp(groups[PropKindCount + variant * 2 + lite], tx, kSidewalkY - 0.1, tz, _originZ, Rand(&r) * 6.28, simd_make_float4(leaves, 0),
                  Range(&r, 15, 21), 0.95, Range(&r, 0.9, 1.1));
          AddProp(groups[PropGrate], tx, kSidewalkY, tz, _originZ, 0, none, 1, 1, 1);
        }
      }
      // Parked cars along the curb (on a rue, on the left side only), now and then a few scooters.
      if (L->cars > 0 && (L->streetType != kRue || side < 0)) {
        double z = cross + 7;
        while (z < kBlockLength - 6) {
          if (Rand(&r) >= L->cars) {
            z += Range(&r, 3, 9);
            continue;
          }
          double pick = Rand(&r);
          PropKind kind = pick < 0.34 ? PropCarHatch : pick < 0.54 ? PropCarSedan : pick < 0.7 ? PropCarSUV : pick < 0.82 ? PropCarVan
                        : pick < 0.91 ? PropCarMicro : PropScooter;
          if (kind == PropScooter) {  // parked side by side, at an angle to the curb
            int count = 2 + (int)(Rand(&r) * 3);
            for (int k = 0; k < count; k++) {
              AddProp(groups[PropScooter], side * (curb - 0.9), 0, bz + z + 0.45 + k * 0.85, _originZ, side * (M_PI_2 - 0.45) + Range(&r, -0.12, 0.12),
                      simd_make_float4(CarPaint(&r), 0), 1, 1, 1);
            }
            z += count * 0.85 + Range(&r, 0.6, 1.4);
            continue;
          }
          double len = PropLength(kind);
          AddProp(groups[kind], side * (curb - 1.05), 0, bz + z + len / 2, _originZ, (Rand(&r) < 0.8 ? 0 : M_PI) + Range(&r, -0.02, 0.02),
                  simd_make_float4(CarPaint(&r), 0), 1, 1, 1);
          z += len + Range(&r, 0.5, 1.8);
        }
      }
      // Café terraces: tables with two chairs side by side facing the street.
      if (L->terraces && L->street.terraceRows > 0) {
        Lot lots[kMaxLots];
        int n = LotsOfBlock(L, block, side, lots);
        for (int i = 0; i < n; i++) {
          for (int b = 0; b < lots[i].bays; b++) {
            if (ParisBayKind(lots[i].building, b, lots[i].bays, L->shops) != kBayCafe) continue;
            double zc = bz + lots[i].f0 + (b + 0.5) * lots[i].bayWidth;
            for (int row = 0; row < L->street.terraceRows; row++) {
              double a = -1.15 - row * 1.2;  // side space: toward the street
              AddProp(groups[PropTable], side * (hw + a), kSidewalkY, zc, _originZ, 0, none, 1, 1, 1);
              for (int c = -1; c <= 1; c += 2) {
                AddProp(groups[PropChair], side * (hw + a + 0.45), kSidewalkY, zc + c * 0.36, _originZ, side * M_PI_2 + Range(&r, -0.25, 0.25), none, 1, 1,
                        Range(&r, 0.85, 1.1));
              }
            }
          }
        }
      }
      // Bollards at the corners; a Morris column on boulevards.
      for (int j = 0; j < 3; j++) {
        AddProp(groups[PropBollard], side * (curb + 0.25), kSidewalkY, bz + cross + 0.7 + j * 1.5, _originZ, 0, none, 1, 1, 1);
        AddProp(groups[PropBollard], side * (curb + 0.25), kSidewalkY, bz + kBlockLength - 0.7 - j * 1.5, _originZ, 0, none, 1, 1, 1);
      }
      if (L->street.column && (block & 1) == (side > 0)) {
        AddProp(groups[PropColumn], side * (curb + 0.9), kSidewalkY, bz + cross + 9.5, _originZ, Rand(&r) * 6.28, none, 1, 1, 1);
      }
      // Street furniture, at least a metre from the walking line (the sidewalk's middle on a
      // rue is too narrow for most of it). The pedestrian lights at the crossing face across.
      BOOL rue = L->streetType == kRue;
      AddProp(groups[PropCrossingLight], side * (curb + 0.3), kSidewalkY, bz + cross + 0.4, _originZ, side * M_PI_2, none, 1, 1, 1);
      if (rue) {
        if (Rand(&r) < 0.7) AddProp(groups[PropSignOneWay], side * (curb + 0.15), kSidewalkY, bz + cross + 1.5, _originZ, 0, none, 1, 1, 1);
      } else {
        if (L->cars > 0 && Rand(&r) < 0.6) AddProp(groups[PropSignNoParking], side * (curb + 0.3), kSidewalkY, bz + cross + 6.8, _originZ, 0, none, 1, 1, 1);
        // Bike racks along the curb between two trees, most with a bicycle.
        if (((block + side) & 1) == 0) {
          for (int k = 0; k < 4; k++) {
            double z = bz + cross + 16.2 + k * 1.1;
            AddProp(groups[PropBikeRack], side * (curb + 0.5), kSidewalkY, z, _originZ, M_PI_2, none, 1, 1, 1);
            if (Rand(&r) < 0.65) {
              AddProp(groups[PropBicycle], side * (curb + 0.5 + (Rand(&r) < 0.5 ? -0.12 : 0.12)), kSidewalkY, z + Range(&r, -0.15, 0.15), _originZ,
                      (Rand(&r) < 0.5 ? 0 : M_PI) + Range(&r, -0.06, 0.06), simd_make_float4(CarPaint(&r), 0), 1, 1, 1);
            }
          }
        }
        // A bench between trees, its back to the road; litter bins by the lamps (below).
        if (Rand(&r) < 0.55) AddProp(groups[PropBench], side * (curb + 1.0), kSidewalkY, bz + cross + 27.5, _originZ, -side * M_PI_2, none, 1, 1, 1);
      }
      // Café terraces' heaters and menu boards against the facade.
      if (!rue && L->terraces && L->street.terraceRows > 0) {
        Lot lots[kMaxLots];
        int n = LotsOfBlock(L, block, side, lots);
        for (int i = 0; i < n; i++) {
          for (int b = 0; b < lots[i].bays; b++) {
            if (ParisBayKind(lots[i].building, b, lots[i].bays, L->shops) != kBayCafe) continue;
            int unit = ParisShopUnit(lots[i].building, b, lots[i].bays);
            double z0 = bz + lots[i].f0 + b * lots[i].bayWidth;
            if (b == unit / 16) {
              AddProp(groups[PropMenuBoard], side * (hw - 0.45), kSidewalkY, z0 + 0.35, _originZ, Range(&r, -0.2, 0.2), none, 1, 1, 1);
            } else if (Rand(&r) < 0.6) {
              AddProp(groups[PropHeater], side * (hw - 0.45), kSidewalkY, z0, _originZ, 0, none, 1, 1, 1);
            }
          }
        }
      }
    }
  }
  // Lamps on both sides, every kLampSpacing (the right side half a spacing on), not in cross streets.
  for (int side = -1; side <= 1; side += 2) {
    double offset = side > 0 ? kLampSpacing / 2 : 0;
    for (int64_t k = (int64_t)floor((zMin - offset) / kLampSpacing); k <= (int64_t)floor((zMax - offset) / kLampSpacing); k++) {
      double z = k * kLampSpacing + offset;
      double local = z - floor(z / kBlockLength) * kBlockLength;
      if (local < cross + 0.5) continue;
      AddProp(groups[PropLamp], side * _uniforms.lampX, kSidewalkY, z, _originZ, side * M_PI_2, none, 1, 1, 1);
      if (L->streetType != kRue && ((k & 1) == 0)) AddProp(groups[PropBin], side * _uniforms.lampX, kSidewalkY, z + 0.65, _originZ, 0, none, 1, 1, 1);
    }
  }

  NSMutableData *all = [NSMutableData data];
  for (int k = 0; k < kGroups; k++) {
    _groupBase[k] = all.length / sizeof(PlantInstance);
    _groupCount[k] = groups[k].length / sizeof(PlantInstance);
    [all appendData:groups[k]];
  }
  _instances = SceneBuffer(_device, all);
  _instanceTotal = _groupBase[kGroups - 1] + _groupCount[kGroups - 1];
}

- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values {
  _uniforms.paving = (float)[values index:@"paving"];
  BOOL relayout = values.layoutGeneration != _builtLayout;
  if (relayout) [self readSettings:values];
  int64_t tile = (int64_t)floor(frame->distance / 24.0);
  if (relayout || frame->originZ != _originZ || tile != _builtTile) {
    _originZ = frame->originZ;
    _builtTile = tile;
    _builtLayout = values.layoutGeneration;
    [self rebuildPropsAround:frame->distance];
    // Blocks in view are built once and kept while they stay in view.
    int64_t b0 = (int64_t)floor((frame->distance - 430) / kBlockLength), b1 = (int64_t)floor((frame->distance + 40) / kBlockLength);
    for (NSNumber *key in _blocks.allKeys) {
      if (key.longLongValue < b0 || key.longLongValue > b1) [_blocks removeObjectForKey:key];
    }
    for (int64_t b = b0; b <= b1; b++) {
      if (_blocks[@(b)]) continue;
      _blocks[@(b)] = [[CityBlock alloc] initWithMesh:BlockMesh(&_layout, b) device:_device];
    }
    [self rebuildLotTableFrom:b0 to:b1];
  }
}

/// The street facades of blocks b0…b1 for the shaders (ParisLot).
- (void)rebuildLotTableFrom:(int64_t)b0 to:(int64_t)b1 {
  int count = (int)MIN(b1 - b0 + 1, kLotSlots);
  NSMutableData *table = [NSMutableData dataWithLength:sizeof(ParisLot) * kLotSlots * 2 * kLotsPerSide];
  ParisLot *t = table.mutableBytes;
  for (int i = 0; i < kLotSlots * 2 * kLotsPerSide; i++) t[i] = (ParisLot){.f0 = -1, .f1 = -1};
  for (int slot = 0; slot < count; slot++) {
    for (int side = 0; side < 2; side++) {
      Lot lots[kMaxLots];
      int n = MIN(LotsOfBlock(&_layout, b0 + slot, side ? 1 : -1, lots), kLotsPerSide);
      for (int i = 0; i < n; i++) {
        unsigned int lit = 0, cool = 0, building = lots[i].building;
        for (int b = 0; b < lots[i].bays; b++) {
          int kind = ParisBayKind(building, b, lots[i].bays, _layout.shops);
          if (kind != kBayShop && kind != kBayCafe) continue;
          int shop = ParisShopType(building, ParisShopUnit(building, b, lots[i].bays) / 16);
          if (shop != kShopClosed) lit |= 1u << b;
          if (shop == kShopPharmacy || shop == kShopAgency) cool |= 1u << b;
        }
        t[(slot * 2 + side) * kLotsPerSide + i] = (ParisLot){.f0 = lots[i].f0, .f1 = lots[i].f1, .bayWidth = lots[i].bayWidth,
          .code = ParisFacadeCode(lots[i].storeys, lots[i].bays, 0, lots[i].type), .building = (float)building, .height = lots[i].height,
          .litShops = (float)lit, .coolShops = (float)cool};
      }
    }
  }
  _lots = SceneBuffer(_device, table);
  _uniforms.lotBlock0 = (float)b0;
  _uniforms.lotBlocks = (float)count;
}

#pragma mark Drawing

/// Whether block `key`'s box lies outside a shadow cascade (its light matrix): left, right,
/// above or below it (depth is clamped, so not along the light).
- (BOOL)block:(int64_t)key outside:(simd_float4x4)light {
  float far = _layout.street.halfWidth + kDepth + kFlankLength, z0 = (float)(key * (double)kBlockLength - _originZ);
  simd_float2 lo = {INFINITY, INFINITY}, hi = {-INFINITY, -INFINITY};
  for (int i = 0; i < 8; i++) {
    simd_float4 c = simd_mul(light, simd_make_float4(i & 1 ? far : -far, i & 2 ? _uniforms.roofHeight + 8 : 0, z0 + (i & 4 ? kBlockLength : 0), 1));
    lo = simd_min(lo, c.xy / c.w);
    hi = simd_max(hi, c.xy / c.w);
  }
  return hi.x < -1 || lo.x > 1 || hi.y < -1 || lo.y > 1;
}

/// The blocks, nearest first (they hide the rest): every group with the current pipeline
/// (shadows: `light`, the cascade's matrix, culls), or each group with its own.
- (void)drawCity:(id<MTLRenderCommandEncoder>)re grouped:(BOOL)grouped light:(const simd_float4x4 *)light {
  [re setVertexBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  [re setFragmentBuffer:_lots offset:0 atIndex:kBufferLots];
  NSArray<NSNumber *> *keys = [[_blocks.allKeys sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator].allObjects;
  for (int g = 0; g < (grouped ? kCityGroups : 1); g++) {
    if (grouped) [re setRenderPipelineState:_cityPipes[g]];
    for (NSNumber *key in keys) {
      if (light && [self block:key.longLongValue outside:*light]) continue;
      CityBlock *block = _blocks[key];
      simd_float3 offset = {0, 0, (float)(key.longLongValue * (double)kBlockLength - _originZ)};
      [re setVertexBytes:&offset length:sizeof offset atIndex:kBufferInstances];
      [re setVertexBuffer:block.buffer offset:0 atIndex:kBufferVertices];
      NSUInteger start = grouped ? block.groupStart[g] : 0, count = grouped ? block.groupCount[g] : block.vertices;
      if (count) [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:start vertexCount:count];
    }
  }
}

- (void)drawProps:(id<MTLRenderCommandEncoder>)re shadowCasters:(BOOL)casters {
  if (!_instances) return;
  [re setFragmentTexture:_atlas atIndex:kTextureScene];
  [re setVertexBuffer:_instances offset:0 atIndex:kBufferInstances];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferParis];
  [re setFragmentBuffer:_lots offset:0 atIndex:kBufferLots];
  for (int k = 0; k < kGroups; k++) {
    if (!_groupCount[k] || (casters && k == PropGrate)) continue;
    PlantUniforms *f = k >= PropKindCount ? &_treeUniforms : &_propUniforms;
    [re setVertexBytes:f length:sizeof *f atIndex:kBufferScene];
    [re setFragmentBytes:f length:sizeof *f atIndex:kBufferScene];
    // Shadows don't need every leaf: trees cast them with their lighter mesh.
    int mesh = casters && k >= PropKindCount && (k - PropKindCount) % 2 == 0 ? k + 1 : k;
    [re setVertexBuffer:_meshes[mesh] offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_meshVertices[mesh] instanceCount:_groupCount[k] baseInstance:_groupBase[k]];
  }
}

- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setRenderPipelineState:_cityShadowPipe];
  [self drawCity:re grouped:NO light:&frame->uniforms.viewProj];
  [re setRenderPipelineState:_plantShadowPipe];
  [self drawProps:re shadowCasters:YES];
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setDepthStencilState:_depthOn];
  [re setCullMode:MTLCullModeNone];
  [re setRenderPipelineState:_plantPipe];
  [self drawProps:re shadowCasters:NO];
  [self drawCity:re grouped:YES light:NULL];
}

@end
