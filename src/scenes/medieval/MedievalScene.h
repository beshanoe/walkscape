// Medieval street: a narrow market street between tall stone houses, endless, the same for a
// given seed. Corbelled upper storeys, arched windows, carved panels, stone arches and bridges
// across the street, washing lines, market stalls under canvas, wall lanterns, ivy; mist.
// The top half is shared with Medieval.metal (compiled into its Metal source); keep it C-and-Metal.
//
// Layout, in street space: s across (0 the street's middle, facades at s = ±halfWidth), y up, z
// along (absolute). The street bends: world x = s + MedievalPathX(z) (a shear, applied by
// town_vs; its periods divide the 512 m origin snap, so it reads the same with world z). It is
// cut into segments of kTownSegment metres, each with its own lots (one house each) on both
// sides, maybe a bridge, stalls, lanterns and washing lines (MedievalTown.m), cached as meshes.

#pragma once

#ifndef __METAL_VERSION__
#import "Scene.h"
#endif

#define kTownSegment 48.0f
#define kLightBucket 6.0f   // the light table: lanterns by z, in buckets of 6 m …
#define kLightBuckets 72    // … covering 432 m
#define kLightsPerBucket 2
#define kLightReach 6.0f    // a lantern's light ends here (m)

// Town mesh materials (MeshVertex.material).
#define kTownPlain 0    // vertex colour, matte
#define kTownStone 1    // ashlar; colour = (building seed, course height, tone 0…1), uv = metres (along, up)
#define kTownCobble 2   // the street; uv = (s, z), z wrapped
#define kTownWood 3     // planks and beams; colour = wood, uv = metres (along the grain, across)
#define kTownCloth 4    // awnings, washing; colour = cloth, uv = metres; uv.y < 0: hangs (sways) |uv.y| below its line
#define kTownWindow 5   // glass or shutters in an opening; colour = (seed, arched, shutters), uv = 0…1 in the opening (y to the springing)
#define kTownRoof 6     // tiles; uv = metres (along the eave, up the slope)
#define kTownIron 7     // brackets, railings, lantern frames
#define kTownFlame 8    // a lantern's glass, lit; colour = how bright
#define kTownJar 9      // glass jar; colour = its contents
#define kTownRelief 10  // a carved panel; colour = (seed, …), uv = 0…1
#define kTownDoor 11    // a plank door; colour = (seed, arched), uv = 0…1 (y to the springing)
#define kTownRecess 12  // the dark inside of a shop arch or doorway; uv = metres
#define kTownWicker 13  // baskets; colour = wicker
#define kTownArch 14    // a bridge's face: ashlar with voussoirs around the arch; colour = (span half-width, springing, seed), uv = (s, y)
#define kTownProduce 15 // fruit, vegetables, bread; colour = colour, matte with a sheen
#define kTownSign 17    // a painted shop sign; colour = (seed, …), uv = 0…1
#define kTownTimber 16  // a half-timbered storey: plaster between oak posts, rails, braces; colour = (post pitch, first post's z, storey height), uv = (z, metres above the storey's floor)
#define kTownCard 20    // + atlas cell: foliage cards (ivy); colour.x = occlusion

typedef struct {
  vector_float3 stoneA;   // the stone's two tones (linear albedo)
  float halfWidth;
  vector_float3 stoneB;
  float roofHeight;       // typical height of the eaves seen from the street (canyon light)
  vector_float3 moss;     // moss and algae colour
  float bends;            // MedievalPathX's amplitude (0 straight … 1.5)
  float lightBase;        // the light table's first bucket (absolute z / kLightBucket)
  float lightPower;       // the lanterns' light (0 … 1, night)
  float flame;            // the lanterns' glass, lit (0 off … 1)
  float weathering;       // stains, moss, dirt (0 … 1)
  float damp;             // the cobbles' wetness (at least the weather's)
  float time;
  float pad0, pad1;
} TownUniforms;

// Buffer slots: TownUniforms at kBufferScene, the light table (float4: x, y, z relative to the
// origin, power; power 0 = none) at kBufferTownLights.
#define kBufferTownLights 4

/// The street's line: the shear's x at z (absolute, or relative to a 512 m-snapped origin).
static inline float MedievalPathX(float z, float bends) {
  const float k = 6.2831853f / 512.0f;
  return bends * (6.0f * sin(z * k) + 3.0f * sin(z * 2.0f * k + 1.3f) + 1.1f * sin(z * 4.0f * k + 0.4f));
}

/// Its slope dx/dz.
static inline float MedievalPathSlope(float z, float bends) {
  const float k = 6.2831853f / 512.0f;
  return bends * k * (6.0f * cos(z * k) + 6.0f * cos(z * 2.0f * k + 1.3f) + 4.4f * cos(z * 4.0f * k + 0.4f));
}

#ifndef __METAL_VERSION__
NS_ASSUME_NONNULL_BEGIN
@interface MedievalScene : NSObject <WalkScene>
@end
NS_ASSUME_NONNULL_END
#endif
