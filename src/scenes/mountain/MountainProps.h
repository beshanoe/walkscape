// The mountain trail's own meshes, built at start (MeshVertex triangles, drawn with the kit's
// plant pipeline: Plants.h materials; mtn_prop_fs gives kMaterialRock the terrain's limestone).
// Plants and stones have unit height (the instance scales them); the sign and the cross are in
// metres.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

enum { kMountainFlowers = 4, kMountainStones = 3 };

/// A clump of flowers on thin stems with a few leaves: kind 0 yellow, 1 white, 2 violet, 3 pink.
NSData *MountainFlowerMesh(int kind);
/// A lump of limestone, faceted: 0 blocky, 1 a slab, 2 a pointed block.
NSData *MountainStoneMesh(int kind);
/// Dwarf mountain pine: a low, wide bush of needle tufts on creeping branches.
NSData *MountainDwarfPineMesh(int kind);
/// A cairn: flat stones piled into a cone.
NSData *MountainCairnMesh(void);
/// A trail signpost (metres): a wooden post with two pointed plates and a red-white-red waymark.
NSData *MountainSignMesh(void);
/// A summit cross (metres): 3.2 m of weathered timber, stayed by a pile of stones.
NSData *MountainCrossMesh(void);

NS_ASSUME_NONNULL_END
