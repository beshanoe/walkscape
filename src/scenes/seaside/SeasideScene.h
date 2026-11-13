// Seaside promenade: a paved promenade along the coast, the sea on one side behind a stone
// balustrade with lamp posts, wind-bent pines on the land side, mostly open sky (CoastEnvironment).
// Endless, the same for a given seed. The top half is shared with Seaside.metal (compiled into
// its Metal source); keep it C-and-Metal.
//
// Cross-section, in metres seaward from the sea wall's face (s; negative: the promenade and
// inland): the balustrade from kBalustradeIn to kBalustradeOut on the wall's top, the paving
// inland to −promenadeWidth, then the pine park. The promenade is kPromenadeY above the sea
// (y = 0); below the wall the beach slopes into the water (SeasideSandY), the still water line at
// kShoreS. The coast follows SeasidePathX(z): gentle bends, the walk along it.

#pragma once

#ifndef __METAL_VERSION__
#import "Scene.h"
#endif

#define kPromenadeY 2.4f        // the promenade above the sea
#define kBalustradeIn (-0.36f)  // the balustrade's land-side face (s)
#define kBalustradeOut (-0.02f) // … its sea side
#define kBalustradeS (-0.19f)   // … its middle
#define kPlinthTop 0.16f        // above the promenade
#define kCopingBottom 0.75f
#define kCopingTop 0.88f        // a little low for a railing, so that a webcam sees the sea over it
#define kPierTop 0.96f
#define kBayLength 2.75f        // pier to pier
#define kBaysPerLamp 8          // a lamp on every 8th pier
#define kPromenadeLampSpacing (kBayLength * kBaysPerLamp)  // 22 m: the strip tiles' length too
#define kBalustersPerBay 9
#define kPierHalf 0.22f         // a pier's half length along the coast
#define kLampPierHalf 0.3f
#define kLanternS (kBalustradeS - 0.587f)  // the lamps' lanterns hang over the paving (LampPostMesh)
#define kLanternY (kPierTop + 0.06f + 2.79f)  // … this high above it
#define kWallFoot 0.3f          // the sand starts here (the wall's batter)
#define kBeachTop 1.0f          // … this high above the sea
#define kBeachSlope 0.06f       // above the water
#define kShoreS (kWallFoot + kBeachTop / kBeachSlope)  // the still water line
#define kSeaWaves 40
#define kSeaBigWaves 16         // the longest, which move the sea grid's vertices

// Strip tile materials (MeshVertex.material).
#define kStripPaving 0  // uv = (s, z in the tile), colour.x = the tile's index
#define kStripStone 1   // plinth, coping, piers; uv = metres
#define kStripWall 2    // the sea wall; uv = (z in the tile, y)
#define kStripSand 3    // uv = (s, z in the tile)
#define kStripCurb 4    // granite at the promenade's land edge
#define kStripScreen 5  // distant balusters as a cut-out pattern; uv = (z in the tile, height above the plinth)

// Props drawn with the kit's plant pipeline (Plants.h materials), and:
#define kMaterialStone 7  // limestone (balusters)

// Buffer slots in the seaside's passes (kBufferScene holds PlantUniforms for plant_vs).
#define kBufferSeaside 4
#define kBufferWaves 5

/// The coast's line: x of the sea wall's face at absolute z.
static inline float SeasidePathX(float z) {
  return 13.0f * sin(z * (1.0f / 170.0f)) + 4.0f * sin(z * (1.0f / 63.0f) + 1.7f);
}

/// The sand's height above the sea s metres seaward of the wall's face (under water beyond kShoreS).
static inline float SeasideSandY(float s) {
  float y = s < kShoreS ? kBeachTop - (s - kWallFoot) * kBeachSlope : -(s - kShoreS) * 0.035f;
  return y < -7.0f ? -7.0f : y;
}

/// The park's ground inland of the promenade, `inland` metres from its edge, at (x, absolute z).
static inline float SeasideParkY(float inland, float x, float z) {
  float roll = 0.35f * sin(x * 0.11f + 0.7f) * sin(z * 0.07f) + 0.2f * sin(x * 0.23f - z * 0.13f);
  float k = inland < 8.0f ? (inland > 0.0f ? inland / 8.0f : 0.0f) : 1.0f;
  return kPromenadeY - 0.16f + inland * 0.02f + roll * k;
}

typedef struct {
  vector_float3 deepColor;  // the sea's own colour (light scattered back out of deep water)
  vector_float2 eye;        // the camera's xz (world): the waves' phases are relative to it
  float seaSign;            // −1: the sea on the left of the picture (x < SeasidePathX), +1 on the right
  float promenadeWidth;     // the paving, from the balustrade inland (m)
  float surf;               // the breakers' height (m)
  float surfPeriod;         // seconds between breakers
  float whitecaps;          // 0 … 1
  float balusterFarZ;       // absolute z: balusters from here on are instances, before it kStripScreen
} SeasideUniforms;

/// The sea's waves this frame (SeasideScene.m builds them from the wind: a spectrum of wind sea
/// down to ripples, and a swell).
typedef struct {
  vector_float4 wave[kSeaWaves];  // kx, kz (rad/m), amplitude (m), phase at the eye (rad); longest first
  float steep[kSeaWaves];         // Gerstner steepness (sharper crests)
} SeaWaves;

#ifndef __METAL_VERSION__
NS_ASSUME_NONNULL_BEGIN
@interface SeasideScene : NSObject <WalkScene>
@end
NS_ASSUME_NONNULL_END
#endif
