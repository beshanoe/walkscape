// The seaside promenade's props, built at start (MeshVertex triangles, drawn with the kit's
// plant pipeline: Plants.h materials and SeasideScene.h's kMaterialStone).

#pragma once

#ifndef __METAL_VERSION__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

enum { kPineVariants = 3 };

/// A stone baluster (metres): standing on the plinth at y = 0, up to the coping's underside.
/// `lite`: fewer sides and rings (distant ones).
NSData *BalusterMesh(BOOL lite);

/// A cast-iron lamp post (metres) standing on a pier at y = 0: a fluted shaft, a shepherd's-crook
/// arm reaching toward +x, a lantern hanging from it. Paint takes the instance's tint.
NSData *LampPostMesh(void);

/// A wind-bent pine, unit height, leaning and reaching toward +x (away from the sea): variant 0
/// an umbrella pine (a flat, wide crown), 1 a maritime pine (a long leaning trunk, a small crown),
/// 2 an Aleppo pine (twisted, an open, ragged crown). `lite`: fewer, larger needle cards.
NSData *WindPineMesh(int variant, BOOL lite);

NS_ASSUME_NONNULL_END
#endif
