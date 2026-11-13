// Furniture more than one scene stands on its ground (MeshVertex triangles, metres, standing on
// y = 0, facing +z), drawn with the plant pipeline (Plants.h materials). A prop moves here from
// a scene when a second scene wants it: scenes never import each other.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A park bench: iron ends, wooden slats, 2 m wide.
NSData *BenchMesh(void);

NS_ASSUME_NONNULL_END
