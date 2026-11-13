// Paris street: Haussmann buildings along a straight street, endless, the same for a given seed.
// The top half is shared with Paris.metal (compiled into its Metal source); keep it C-and-Metal.
//
// Layout: the street runs along z, centred on x = 0, facades at x = ±halfWidth. It is cut into
// blocks of kBlockLength metres; each block starts with a cross street, then lots (one building
// each) on both sides. The walker is on one sidewalk, kSidewalkY above the road.

#pragma once

#ifndef __METAL_VERSION__
#import "Scene.h"
#endif

#define kBlockLength 160.0f
#define kSidewalkY 0.15f
#define kLampSpacing 24.0f
#define kLampHeight 4.4f

// City mesh materials (MeshVertex.material).
#define kCityPlain 0     // vertex colour
#define kCityFacade 1    // stone facade around the openings; colour = (bay width, ParisFacadeCode, building), uv = metres
#define kCityTrim 2      // stone cornices, balconies, party walls; colour = stone
#define kCityZinc 3      // mansard roofs, dormer sides
#define kCityRailing 4   // wrought-iron railing, cut out; uv = metres along, 0…1 up
#define kCityAwning 5    // cloth; colour = cloth
#define kCityDormer 6    // dormer window
#define kCityRoad 7
#define kCitySidewalk 8
#define kCityCurb 9
#define kCityWindow 10   // the glass (or door) set back in an opening; colour and uv as kCityFacade
#define kCityReveal 11   // the sides of an opening; colour = stone, uv = (metres along, 0 at the facade … 1 inside)
#define kCityShutter 12  // shutters; colour = paint, uv = metres across and up
#define kCityGlow 13     // lit signs (pharmacy cross, tobacconist's sign); colour = light

// city_fs specialisations (function constant 0), by material.
#define kCityGroupGround 0  // road, sidewalk, curb
#define kCityGroupWalls 1   // everything else
#define kCityGroupGlass 2   // windows, dormers
#define kCityGroups 3

static inline int ParisMaterialGroup(int material) {
  if (material == kCityRoad || material == kCitySidewalk || material == kCityCurb) return kCityGroupGround;
  return material == kCityWindow || material == kCityDormer ? kCityGroupGlass : kCityGroupWalls;
}

typedef struct {
  float halfWidth;   // facade x
  float curbX;       // the curb: road from −curbX to curbX
  float crossWidth;  // cross street width (at the start of each block)
  float paving;      // 0 asphalt, 1 cobbles
  float centerLine;  // 1: dashed centre line
  float facadeTone;  // 0 cream … 1 grey
  float lampX;       // lamps at x = ±lampX, every kLampSpacing (the right side shifted by half)
  float shops;       // share of shop buildings (ParisBayKind)
  float roofHeight;  // typical height of the rooflines seen from the street (canyon lighting)
  float lotBlock0;   // the lot table's first block
  float lotBlocks;   // … and how many blocks it holds
  float treeX;       // street trees' line, |x| (0: none)
  float treeCover;   // how much of the line their crowns fill, 0…1
  float parking;     // parking lanes: 0 none, 1 on the left (x < 0), 2 both sides
  float wetness;     // FrameUniforms.wetness, for functions that only see these
} ParisUniforms;

// Fragment buffer slots: ParisUniforms in the props' pass (kBufferScene holds PlantUniforms
// there), and the lot table (both passes).
#define kBufferParis 4
#define kBufferLots 5

// The lot table: the street facades of the blocks in view, so that reflections and light from
// shop windows can find the building at a point. [block − lotBlock0][side: 0 left, 1 right][lot].
#define kLotSlots 6
#define kLotsPerSide 16
typedef struct {
  float f0, f1;    // the street facade along the block (z); unused entries: f0 = f1 = -1
  float bayWidth;
  float code;      // ParisFacadeCode
  float building;
  float height;
  float litShops;   // bit b: bay b is a shop lit at night
  float coolShops;  // … whose light is cool white (pharmacy, agency)
} ParisLot;

// Hashes for window kinds, lit rooms, shop colours (SceneShared.h).
#define ParisHash SceneHash
#define ParisHashF SceneHashF

// Building types. Haussmann: ashlar stone, an entresol, balconies along the second and top
// floors, folding metal shutters. Old (pre-Haussmann): plastered, lower floors, narrower bays,
// small-paned windows with sills and wooden shutters. `oldShare` depends on the street.
#define kTypeHaussmann 0
#define kTypeOld 1

static inline int ParisBuildingType(unsigned int building, float oldShare) {
  return ParisHashF(building, 41u) < oldShare ? kTypeOld : kTypeHaussmann;
}

// Ground-floor bays: what each one is. A building's ground floor is all shops (one in three of
// them cafés) or all wall, apart from its carriage door. `shops`: share of shop buildings (0…1).
#define kBayWall 0
#define kBayShop 1
#define kBayCafe 2
#define kBayDoor 3

// Shops: a shop building's ground floor is cut into units of one to three bays (not across the
// carriage door), each a kind of shop with its own sign, front and interior.
#define kShopCafe 0
#define kShopRestaurant 1
#define kShopBakery 2
#define kShopPharmacy 3
#define kShopFashion 4
#define kShopGrocer 5
#define kShopBooks 6
#define kShopFlorist 7
#define kShopAgency 8  // estate agent, optician, dry cleaner, hairdresser
#define kShopClosed 9  // roller shutter down
#define kShopTypes 10

static inline int ParisDoorBay(unsigned int building, int bays) {
  return (int)(ParisHash(building, 77u) % (unsigned int)bays);
}

/// The unit bay `bay` belongs to, as first bay × 16 + bays.
static inline int ParisShopUnit(unsigned int building, int bay, int bays) {
  int door = ParisDoorBay(building, bays), i = 0;
  while (i < bays) {
    if (i == door) {
      if (bay == i) return i * 16 + 1;
      i++;
      continue;
    }
    int end = i + 1 + (int)(ParisHash(building, 90u + (unsigned int)i) % 3u);
    if (door > i && door < end) end = door;
    if (end > bays) end = bays;
    if (bay >= i && bay < end) return i * 16 + (end - i);
    i = end;
  }
  return bay * 16 + 1;
}

/// The kind of shop of the unit starting at `first` (a cut corner is unit 15).
static inline int ParisShopType(unsigned int building, int first) {
  float r = ParisHashF(building, 100u + (unsigned int)first);
  if (first == 15) return r < 0.6f ? kShopCafe : r < 0.75f ? kShopRestaurant : r < 0.85f ? kShopPharmacy : kShopBakery;
  const float cumulative[kShopTypes] = {0.2f, 0.3f, 0.38f, 0.44f, 0.58f, 0.66f, 0.72f, 0.77f, 0.88f, 1.0f};
  for (int t = 0; t < kShopTypes; t++) {
    if (r < cumulative[t]) return t;
  }
  return kShopClosed;
}

/// Which sign word (Paris.metal: kSignWords) a shop unit has: one of its type's words.
static inline int ParisSignWord(unsigned int building, int first, int type) {
  const int count[kShopTypes] = {5, 4, 3, 1, 3, 4, 3, 2, 4, 0};
  int start = 0;
  for (int t = 0; t < type && t < kShopTypes; t++) start += count[t];
  return type >= kShopClosed ? -1 : start + (int)(ParisHash(building, 110u + (unsigned int)first) % (unsigned int)count[type]);
}

static inline int ParisBayKind(unsigned int building, int bay, int bays, float shops) {
  if (bay == ParisDoorBay(building, bays)) return kBayDoor;
  if (ParisHashF(building, 5u) >= shops) return kBayWall;
  int type = ParisShopType(building, ParisShopUnit(building, bay, bays) / 16);
  return type == kShopCafe || type == kShopRestaurant ? kBayCafe : kBayShop;
}

/// The ground floor of a cut corner (pan coupé): usually a café's door.
static inline int ParisCornerKind(unsigned int building, float shops) {
  if (ParisHashF(building, 5u) >= shops + 0.2f) return kBayWall;
  int type = ParisShopType(building, 15);
  return type == kShopCafe || type == kShopRestaurant ? kBayCafe : kBayShop;
}

// Levels: 0 ground floor (4.0 m), 1 entresol (2.6 m), then `storeys` floors (3.4 m, 3.1 m,
// 3.0 m …, the last 2.9 m) under the main cornice; the mansard sits on top. Old buildings: a
// 3.6 m ground floor, then 2.8 m floors.
static inline float ParisLevelHeight(int level, int storeys, int type) {
  if (type == kTypeOld) return level == 0 ? 3.6f : 2.8f;
  if (level == 0) return 4.0f;
  if (level == 1) return 2.6f;
  int f = level - 2;
  if (f == 0) return 3.4f;
  if (f == storeys - 1) return 2.9f;
  return f == 1 ? 3.1f : 3.0f;
}

static inline float ParisLevelBase(int level, int storeys, int type) {
  float y = 0;
  for (int i = 0; i < level; i++) y += ParisLevelHeight(i, storeys, type);
  return y;
}

/// Window width in a bay of width `bw`.
static inline float ParisWindowWidth(float bw, int type) {
  float w = bw * (type == kTypeOld ? 0.42f : 0.46f), most = type == kTypeOld ? 1.1f : 1.35f;
  return w < most ? w : most;
}

/// The opening in one bay of one level: lo, hi from the bay's centre and the level's floor
/// (metres), and how far it is set into the wall. `kind`: the ground floor's bay kind.
typedef struct {
  vector_float2 lo, hi;
  float depth;
} ParisOpening;

static inline ParisOpening ParisOpeningIn(int level, int kind, int type, float bw, float h) {
  float ww = ParisWindowWidth(bw, type);
  ParisOpening o;
  o.depth = 0.3f;
  int old = type == kTypeOld;
  if (level >= 2 || (old && level == 1)) {
    o.lo = (vector_float2){-ww * 0.5f, old ? 0.85f : 0.04f};
    o.hi = (vector_float2){ww * 0.5f, h - (old ? 0.5f : 0.6f)};
  } else if (level == 1) {
    o.lo = (vector_float2){-ww * 0.5f, 0.35f};
    o.hi = (vector_float2){ww * 0.5f, h - 0.35f};
  } else if (kind == kBayShop || kind == kBayCafe) {
    o.lo = (vector_float2){-bw * 0.43f, 0.12f};
    o.hi = (vector_float2){bw * 0.43f, old ? 2.75f : 3.15f};
    o.depth = 0.15f;
  } else if (kind == kBayDoor) {
    o.lo = (vector_float2){old ? -0.7f : -0.95f, 0.0f};
    o.hi = (vector_float2){old ? 0.7f : 0.95f, old ? 2.9f : 3.85f};
    o.depth = 0.35f;
  } else {
    o.lo = (vector_float2){-ww * 0.5f, old ? 0.9f : 1.0f};
    o.hi = (vector_float2){ww * 0.5f, old ? 2.8f : 3.4f};
  }
  return o;
}

// Shutters: Haussmann buildings have folding metal ones (persiennes) that fold into the window's
// reveal, old ones wooden shutters that open flat against the wall. Some are closed.
#define kShutterNone 0
#define kShutterOpen 1
#define kShutterClosed 2

static inline int ParisShutter(unsigned int building, int level, int bay, int type) {
  if (level == 0) return kShutterNone;
  float has = ParisHashF(building, 42u);
  if (type == kTypeHaussmann && (level < 2 || has > 0.6f)) return kShutterNone;
  if (type == kTypeOld && has > 0.85f) return kShutterNone;
  float closed = type == kTypeOld ? 0.22f : 0.12f;
  return ParisHashF(building * 31u + (unsigned int)level, (unsigned int)bay + 700u) < closed ? kShutterClosed : kShutterOpen;
}

/// How weathered a building's facade is: 0 just cleaned … 1 sooty.
static inline float ParisAge(unsigned int building) {
  return ParisHashF(building, 43u);
}

// Facade vertex colour (kCityFacade, kCityWindow): x bay width, y the code below, z building.
static inline float ParisFacadeCode(int storeys, int bays, int corner, int type) {
  return (float)(storeys + 16 * bays + 256 * corner + 512 * type);
}

#ifndef __METAL_VERSION__
NS_ASSUME_NONNULL_BEGIN
@interface ParisScene : NSObject <WalkScene>
@end
NS_ASSUME_NONNULL_END
#endif
