// The high mountains: thin, clear air (far ridges turn blue, not grey), a deep blue zenith,
// fair-weather cumulus a little above the peaks, cirrus and contrails; the coast's sky
// (CoastSky.metal) with its own presets. Azimuths assume the valley on the left of the picture
// and the slope rising on the right: the sun stands behind the right shoulder, high at noon (the
// slope lit from above, the range's faces toward the camera and the trail lit, its far sides and
// gullies in shade), low in the morning and at dusk, when it lights only the range's walls.
// (From behind the left shoulder the range showed its shaded side: a grey curtain.) A scene with the valley on the right mirrors the sun (-adjustLighting:values:).
//
//   Clear day      a summer noon: hard light, small clouds, their shadows on the slopes
//   Morning        a low warm sun raking across the walls, long shadows, haze in the valley
//   Alpenglow      the sun at the horizon: the pale rock glows orange and pink, the valley in shade
//   Overcast       a grey deck just above the summits, soft light
//   Valley mist    after a cold night: the valley under a sea of mist, clear sky above
//   Night          a full moon, stars, the Milky Way

#import "CoastEnvironment.h"

NS_ASSUME_NONNULL_BEGIN

@interface AlpineEnvironment : CoastEnvironment
@end

NS_ASSUME_NONNULL_END
