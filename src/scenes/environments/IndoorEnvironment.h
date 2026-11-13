// The indoor environment: light fixtures (FrameUniforms.lampColor, as bright as `night` says;
// the scene places them and lights its surfaces from them), bounce light as the ambient, and the
// sun only as daylight through windows. No sky: the scene encloses the view. What shiny floors
// reflect comes from skyZenith (the ceiling) and skyHorizon (the walls).
// Presets: Bright, Warm evening, Fluorescent, Sunlight through windows, Night.

#import "Environment.h"

NS_ASSUME_NONNULL_BEGIN

@interface IndoorEnvironment : SceneEnvironment
@end

NS_ASSUME_NONNULL_END
