// Corridor: an endless indoor corridor (hotel, office or old building), the same for a given seed.
// Lives in the indoor environment: ceiling fixtures every `lightSpacing` metres light it (the
// shader sums the nearest ones), daylight comes in through windows on one side when it has them.
// The top half is shared with Corridor.metal (compiled into its Metal source); keep it C-and-Metal.
//
// Layout: the corridor runs along z, centred on x = 0, floor at y = 0. It is cut into segments of
// kSegmentLength metres, each starting with a fire-door portal (pilasters and a header with an
// exit sign); doors, windows and pictures are placed per segment and wall.

#pragma once

#ifndef __METAL_VERSION__
#import "Scene.h"
#endif

#define kSegmentLength 32.0f
#define kDoorHeight 2.1f
#define kWindowSill 0.9f
#define kWindowHead 2.3f

// Corridor mesh materials (MeshVertex.material).
#define kHallPlain 0     // vertex colour (trim, frames, handles)
#define kHallWall 1      // painted wall; uv = metres (along, up)
#define kHallFloor 2
#define kHallCeiling 3
#define kHallDoor 4      // door leaf; uv 0…1; colour.x = door seed
#define kHallWindow 5    // window: frame and glass; uv 0…1
#define kHallPainting 6  // uv 0…1; colour.x = painting seed
#define kHallSign 7      // exit sign, lit
#define kHallShadowOnly 8  // casts the sun's shadow, not drawn (a thick slab above the ceiling)

enum { kStyleHotel, kStyleOffice, kStyleOld };
enum { kFloorCarpet, kFloorWood, kFloorStone };

typedef struct {
  vector_float4 wall;   // paint colour (linear RGB)
  float halfWidth;
  float height;
  float style;          // kStyle…
  float floorType;      // kFloor…
  float lightSpacing;   // fixtures at z = (k + 0.5) × spacing, x = 0
  float lightY;         // the fixtures' height
} CorridorUniforms;

#ifndef __METAL_VERSION__
NS_ASSUME_NONNULL_BEGIN
@interface CorridorScene : NSObject <WalkScene>
@end
NS_ASSUME_NONNULL_END
#endif
