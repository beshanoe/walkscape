// Mountain trail: a path contouring a steep grass slope high above a valley, a range of pale
// rock towers across it (the Dolomites), endless and the same for a given seed. The top half is
// shared with the shaders (compiled into their Metal source); keep it C-and-Metal.
//
// The ground is one height function, MountainTerrain.metal's mtnTerrain(x, z): it exists only in
// Metal. The scene bakes it into nested levels around the walker (a geometry clipmap: every level
// kMtnGrid cells square, each twice as coarse as the one inside it, 0.25 m cells out to 128 m
// ones), and reads the fine levels back to stand plants and stones on it. Only the trail's own
// line (MountainPathX, MountainTrailY) is known to both sides: the terrain is built around it.
//
// Coordinates: z along the walk, the camera looks back along −z. y = 0 is the trail's mean
// height (think 2,300 m above the sea); the valley floor lies about 620 m below, the summits up
// to 900 m above. `side` is −1 with the valley on the left of the picture (−x), +1 on the right;
// v = side · x is "metres toward the valley".

#pragma once

#ifndef __METAL_VERSION__
#import "Scene.h"
#define MtnSin sinf
#define MtnCos cosf
#else
#define MtnSin sin
#define MtnCos cos
#endif

// ---- the clipmap ----

#define kMtnLevels 10        // level L has cells of kMtnCell0 · 2^L metres
#define kMtnGrid 512         // cells per side; kMtnGrid + 1 vertices and texels
#define kMtnBlock 64         // a level is drawn in blocks of this many cells (culled one by one)
#define kMtnCell0 0.25f
#define kMtnOverlap 4        // cells of a level that the next coarser one still draws under its rim
#define kMtnShadowLevel 3    // the finest level with a baked sun shadow (finer ones use its)
#define kMtnSnap 32          // a level follows the walker in steps of this many cells
#define kMtnFar 60000.0f     // the far plane (m)
#define kMtnEarthRadius 6371000.0f

// Slots after the host's and the coast sky's (kTextureShadow 0, kTextureScene 1, kTextureClouds 2).
#define kTextureHeights 3    // R32Float array: height
#define kTextureSurface 4    // RGBA8 array: normal x, z; ambient occlusion; curvature
#define kTextureMask 5       // RGBA8 array: bedrock, scree, gully, spare
#define kTextureSunShadow 6  // R8 array: how much sun gets past the terrain
#define kBufferMountain 4

// ---- the trail (both sides; the walker's copy in double is in MountainScene.m) ----

#define kMtnPathA1 38.0f
#define kMtnPathL1 170.0f
#define kMtnPathA2 22.0f
#define kMtnPathL2 97.0f
#define kMtnPathA3 6.0f
#define kMtnPathL3 53.0f
#define kMtnRiseA1 16.0f
#define kMtnRiseL1 330.0f
#define kMtnRiseA2 5.0f
#define kMtnRiseL2 127.0f

/// The trail's x at z (tightest turn ≈ 175 m radius).
static inline float MountainPathX(float z) {
  return kMtnPathA1 * MtnSin(z / kMtnPathL1) + kMtnPathA2 * MtnSin(z / kMtnPathL2 + 1.3f) + kMtnPathA3 * MtnSin(z / kMtnPathL3 + 0.7f);
}

static inline float MountainPathSlope(float z) {
  return kMtnPathA1 / kMtnPathL1 * MtnCos(z / kMtnPathL1) + kMtnPathA2 / kMtnPathL2 * MtnCos(z / kMtnPathL2 + 1.3f) +
         kMtnPathA3 / kMtnPathL3 * MtnCos(z / kMtnPathL3 + 0.7f);
}

/// The trail's height at z (at most 9 % steep).
static inline float MountainTrailY(float z) {
  return kMtnRiseA1 * MtnSin(z / kMtnRiseL1) + kMtnRiseA2 * MtnSin(z / kMtnRiseL2 + 2.1f);
}

// ---- uniforms ----

/// What the height function depends on.
typedef struct {
  float side;       // −1: the valley on the left (−x), +1: on the right
  float peaks;      // the towers' height, 1 = as designed
  float seed;       // a whole number
  float trailHalf;  // half the tread's width (m)
} MountainShape;

/// One bake of one level (mtn_bake_height, mtn_bake_surface).
typedef struct {
  MountainShape shape;
  vector_float2 origin;  // absolute x, z of vertex (0, 0)
  float cell;
  int level;
} MountainBake;

/// What the drawing shaders read at kBufferMountain (and mtn_bake_shadow).
typedef struct {
  vector_float4 levels[kMtnLevels];  // x, z of vertex (0, 0) relative to the floating origin; cell (m); unused
  MountainShape shape;
  vector_float3 bakedSun;  // the sun the shadows were baked for
  float wrapZ;        // the floating origin's z modulo 4096 m (detail noise repeats every 4096 m)
  float snow;         // 0 none … 1 snow down to the trail
  float flowers;      // 0 … 1
  float wind;         // 0 … 1: waves over the grass
  float mist;         // 0 … 1: a sea of mist in the valley
  float mistTop;      // its top (m)
  float debug;        // 1: plain grey relief (the shape alone)
} MountainUniforms;

/// A block of a level to draw (terrain_vs's instance).
typedef struct {
  vector_float4 block;  // the block's first cell (x, z), the level, unused
} MountainBlock;

#ifndef __METAL_VERSION__
NS_ASSUME_NONNULL_BEGIN
@interface MountainScene : NSObject <WalkScene>
@end
NS_ASSUME_NONNULL_END
#endif
