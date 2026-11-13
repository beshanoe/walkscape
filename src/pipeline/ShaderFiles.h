// The Metal sources compiled at runtime (Xcode 26 ships the offline compiler separately).
// build.sh embeds every .h and .metal of each src/ folder that has a .metal file into
// build/ShaderFiles.inc, looked up here by file name (names are unique: build.sh checks).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The text of an embedded shader file ("Common.metal", "SceneShared.h"), without its
/// "#pragma once" (the files are pasted into one source); nil if this build has no such file.
NSString *_Nullable ShaderFileText(NSString *name);

NS_ASSUME_NONNULL_END
