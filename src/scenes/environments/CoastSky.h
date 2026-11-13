// The coast's sky (CoastSky.metal): constants shared by CoastEnvironment.m, the shader and the
// scenes that mirror the sky (they list CoastSky.h and CoastSky.metal in their shader sources and
// bind the cloud noise, CoastCloudNoise(), at kTextureClouds). Compiles as C and as Metal.

#pragma once

#define kCloudNoiseSize 512
#define kCloudTile 9000.0f   // metres the cloud noise texture spans (it repeats)
#define kTextureClouds 2     // fragment texture slot of the cloud noise (after kTextureShadow, kTextureScene)
#define kEarthRadius 6371000.0f
