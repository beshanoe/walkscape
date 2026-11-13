// Forest road: a meandering path through an endless forest, the same for a given seed.
// Its trees and undergrowth are the kit's plants (Plants.h). The top half is shared with
// Forest.metal (compiled into its Metal source); keep it C-and-Metal.

#pragma once

#ifndef __METAL_VERSION__
#import "Scene.h"
#endif

// Path: x(z) = A1 sin(z/L1) + A2 sin(z/L2 + 1.3). Tightest turn ≈ 290 m radius.
// What the ground's shaders read at kBufferScene (the plants read PlantUniforms there).
typedef struct {
  vector_float4 path;    // A1, L1, A2, L2
  vector_float4 floorA;  // forest floor colours (linear RGB): moss/grass …
  vector_float4 floorB;  // … and leaf litter / needles
  float roadHalfWidth;
  float pathType;        // 0 forest road (two ruts), 1 trail, 2 gravel
  float hills;           // terrain height multiplier
  float snow;            // 0 or 1 (winter)
} ForestUniforms;

#ifndef __METAL_VERSION__
NS_ASSUME_NONNULL_BEGIN
@interface ForestScene : NSObject <WalkScene>
@end
NS_ASSUME_NONNULL_END
#endif
