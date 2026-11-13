// The medieval street's layout and meshes, per segment (kTownSegment metres): a plan (lots,
// bridge, stalls, lanterns, washing lines; deterministic for a seed and segment), and the mesh
// built from it in street space (MedievalScene.h), z from the segment's start.

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#import "MedievalScene.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
  float halfWidth;  // facades at s = ±halfWidth
  int storeys;      // typical
  float market;     // share of houses with a stall in front, 0 … 1
  float bridges;    // chance of a bridge or arch per segment
  float laundry;    // washing lines, 0 … 1
  float ivy;        // 0 … 1
  uint32_t seed;
} TownLayout;

/// A lantern: where its light comes from (street space, z from the segment's start), how strong.
typedef struct {
  simd_float3 p;
  float power;
} TownLight;

/// The typical eaves height for `layout` (canyon light).
float TownRoofHeight(const TownLayout *layout);

/// Segment `segment`'s mesh: opaque triangles first (`opaqueVertices` of them), then foliage cards
/// (alpha to coverage).
NSData *TownSegmentMesh(const TownLayout *layout, int64_t segment, NSUInteger *opaqueVertices);

/// The segment's lanterns (at most `max`); returns how many.
int TownSegmentLights(const TownLayout *layout, int64_t segment, TownLight *out, int max);

NS_ASSUME_NONNULL_END
