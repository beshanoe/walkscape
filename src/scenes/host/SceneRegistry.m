#import "SceneRegistry.h"

#import <os/lock.h>

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<Class<WalkScene>> *sScenes;  // sorted; guarded by sLock

@implementation SceneRegistry

+ (void)registerScene:(Class<WalkScene>)scene {
  NSString *identifier = [scene identifier];
  os_unfair_lock_lock(&sLock);
  if (!sScenes) sScenes = [NSMutableArray array];
  BOOL taken = NO;
  for (Class<WalkScene> other in sScenes) taken = taken || [[other identifier] isEqualToString:identifier];
  if (!taken) {
    [sScenes addObject:scene];
    [sScenes sortUsingComparator:^NSComparisonResult(Class<WalkScene> a, Class<WalkScene> b) {
      return [[a identifier] compare:[b identifier]];
    }];
  }
  os_unfair_lock_unlock(&sLock);
  if (taken) NSLog(@"Scene %@ left out: another scene is already called “%@”", NSStringFromClass(scene), identifier);
}

+ (NSArray<Class<WalkScene>> *)scenes {
  os_unfair_lock_lock(&sLock);
  NSArray<Class<WalkScene>> *scenes = [sScenes copy] ?: @[];
  os_unfair_lock_unlock(&sLock);
  return scenes;
}

+ (Class<WalkScene>)sceneWithIdentifier:(NSString *)identifier {
  for (Class<WalkScene> scene in self.scenes) {
    if ([[scene identifier] isEqualToString:identifier]) return scene;
  }
  return Nil;
}

@end
