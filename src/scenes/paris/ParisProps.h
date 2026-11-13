// Street props for the Paris scene, built at start (MeshVertex triangles, metres, standing on
// y = 0, facing +z). Drawn with the kit's plant pipeline (Plants.h materials): plain
// colours, lamp glass that lights up at night, paint taken from the instance's tint, glass.

#pragma once

#ifndef __METAL_VERSION__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum {
  PropLamp,
  PropCarHatch,  // parked cars: generic shapes, no particular make
  PropCarSedan,
  PropCarSUV,
  PropCarVan,
  PropCarMicro,
  PropScooter,
  PropBicycle,
  PropTable,
  PropChair,
  PropColumn,  // Morris column (advertising)
  PropGrate,   // iron grate around a street tree
  PropBollard,
  PropSignNoParking,
  PropSignOneWay,
  PropCrossingLight,
  PropBikeRack,
  PropBench,
  PropBin,
  PropHeater,
  PropMenuBoard,
  PropKindCount,
} PropKind;

/// The length of a parked vehicle (m), for spacing them along the curb.
float PropLength(PropKind kind);

NSData *PropMesh(PropKind kind);

NS_ASSUME_NONNULL_END
#endif
