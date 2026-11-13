// The plant pipeline, for every scene: instanced meshes (trees, undergrowth, and props such as
// lamps, benches, cars) drawn by plant_vs / plant_fs (Plants.metal), and the plant meshes
// themselves, built procedurally at start (MeshVertex triangles, unit height: base at y = 0, top
// at y = 1). Trunks and branches are bark tubes; foliage is cards textured from the baked atlas
// (kMaterialCard + cell). The top half is shared with Plants.metal (compiled into the Metal
// source of the scenes that list it); keep it C-and-Metal.

#pragma once

#ifndef __METAL_VERSION__
#include <simd/simd.h>
#endif

// What plant_vs / plant_fs read at kBufferScene.
typedef struct {
  float wind;  // 0 calm … 1 breezy
  float snow;  // 0 or 1 (winter)
  float moss;  // moss on trunks and rocks, 0…1 (0 in a city)
} PlantUniforms;

// One plant or prop (tree, bush, fern, grass tuft, rock, log; a lamp, a car). Plant meshes have
// unit height: the instance scales y by `shape.y` and x/z by `shape.x * shape.y`.
typedef struct {
  vector_float4 posYaw;  // x, y, z (relative to origin), yaw
  vector_float4 shape;   // width scale, height (m), brightness, wind phase
  vector_float4 tint;    // foliage colour (linear RGB), w: snow cover 0…1
} PlantInstance;

// MeshVertex.material: 0 plain (vertex colour), 1 bark, 2 birch bark, 3 rock, 4 lamp glass (lit
// at night), 5 paint (the instance's tint, glossy), 6 glass; 10 + n: a foliage card using cell n
// of the baked atlas (vertex colour: x ambient occlusion, y random). A scene with its own
// fragment function around plantSurface can add materials from 7 up (the seaside's stone).
#define kMaterialBark 1
#define kMaterialBirch 2
#define kMaterialRock 3
#define kMaterialLamp 4
#define kMaterialPaint 5
#define kMaterialGlass 6
#define kMaterialCard 10

// The foliage atlas: 4 × 2 cells of kAtlasCell pixels, baked at launch by bake_foliage.
#define kAtlasCell 512
#define kAtlasColumns 4
#define kAtlasRows 2
enum { kCellLeaves = 0, kCellBirchLeaves = 1, kCellSpruce = 2, kCellPine = 3, kCellFern = 4, kCellGrass = 5, kCellPlaneLeaves = 6 };

#ifndef __METAL_VERSION__
#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum {
  PlantSpruce,
  PlantPine,
  PlantOak,
  PlantBeech,
  PlantBirch,
  PlantBush,
  PlantFern,
  PlantGrass,
  PlantRock,
  PlantLog,
  PlantStump,
  PlantPlane,  // London plane, for city streets: a tall clean trunk, big leaves
  PlantKindCount,
} PlantKind;

enum { kPlantVariants = 3 };

/// Whether winter leaves `kind` bare (deciduous).
static inline BOOL PlantIsDeciduous(PlantKind kind) {
  return kind == PlantOak || kind == PlantBeech || kind == PlantBirch || kind == PlantBush || kind == PlantPlane;
}

/// The mesh for one variant. `lite`: fewer, larger cards (distant trees). `bare`: branches only
/// (deciduous trees in winter).
NSData *PlantMesh(PlantKind kind, int variant, BOOL lite, BOOL bare);

@class MeshBuilder;
/// `count` foliage cards (the builder's material: kMaterialCard + cell) in an ellipsoid crown
/// around `center`, mostly near its surface and facing outward, lit as one rounded mass, darker
/// inside; `hang` tilts them down. For a scene's own trees (the seaside's pines).
void PlantCrown(MeshBuilder *m, simd_float3 center, simd_float3 radii, int count, float size, float hang);

@protocol MTLDevice, MTLLibrary, MTLTexture;
/// The foliage atlas, drawn by Plants.metal's bake_foliage (in `library`) and mipmapped; bind it
/// at fragment texture kTextureScene for plant_fs.
id<MTLTexture> _Nullable FoliageAtlas(id<MTLDevice> device, id<MTLLibrary> library, NSError **error);

NS_ASSUME_NONNULL_END
#endif
