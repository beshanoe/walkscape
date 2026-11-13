// The scenes this process has: each scene class adds itself when its code is loaded
//
//   + (void)load { [SceneRegistry registerScene:self]; }
//
// so the host names no scene and a scene is one folder under src/scenes/ (see Scene.h, "Adding a
// scene"). Code loaded later (a bundle) registers the same way, as long as it is loaded before the
// first SceneRenderer is made: the renderer reads the list once.

#import <Foundation/Foundation.h>

#import "Scene.h"

NS_ASSUME_NONNULL_BEGIN

@interface SceneRegistry : NSObject

/// Adds a scene (any thread; meant for +load). A second scene with an identifier already taken
/// is left out, with a log line.
+ (void)registerScene:(Class<WalkScene>)scene;
/// Every scene in menu order: alphabetical by identifier (the scene's folder name).
@property(class, nonatomic, readonly) NSArray<Class<WalkScene>> *scenes;
+ (nullable Class<WalkScene>)sceneWithIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
