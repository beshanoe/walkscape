// Types shared by the Objective-C scene code and the Metal shaders. The host puts this file at
// the top of every scene's Metal source, so it compiles both as C and as Metal Shading Language:
// use vector_float3 / matrix_float4x4 (same names, sizes and alignment in both), no C-only types.

#pragma once

#include <simd/simd.h>  // vector_float3 etc., in Metal too

// Buffer slots, the same in every pass.
enum {
  kBufferFrame = 0,      // FrameUniforms (set by the host)
  kBufferVertices = 1,   // mesh vertices / ground grid
  kBufferInstances = 2,  // per-instance data / grid offset
  kBufferScene = 3,      // the scene's own uniforms
};

// Fragment texture slots. The host binds the sun's shadow map (depth2d_array, one slice per
// cascade) before -encodeScene:; scenes put their own textures from kTextureScene up.
enum {
  kTextureShadow = 0,
  kTextureScene = 1,
};

#define kShadowCascades 2

/// A deterministic hash, the same in C and Metal (per-building, per-room, per-door choices).
static inline unsigned int SceneHash(unsigned int a, unsigned int b) {
  unsigned int h = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u) * 0x85EBCA77u;
  h ^= h >> 15;
  h *= 0x2C1B3C6Du;
  h ^= h >> 12;
  h *= 0x297A2D39u;
  h ^= h >> 15;
  return h;
}

/// SceneHash as 0…1.
static inline float SceneHashF(unsigned int a, unsigned int b) {
  return (float)(SceneHash(a, b) & 0xFFFFFFu) / 16777216.0f;
}

// A mesh vertex (MeshBuilder): position, normal, linear RGB colour, texture coordinates and a
// material number the scene's shader interprets (e.g. bark, leaves). Plain arrays: 48 bytes in both.
typedef struct {
  float p[3];
  float n[3];
  float c[3];
  float uv[2];
  float material;
} MeshVertex;

// Per-frame values every scene shader sees at buffer 0. The lighting part comes from the scene's
// environment's preset (Environment.h), adjusted by the scene.
typedef struct {
  matrix_float4x4 viewProj;
  matrix_float4x4 invViewProj;
  matrix_float4x4 shadowViewProj[kShadowCascades];  // world → the sun's clip space, per cascade
  vector_float3 camPos;      // relative to the floating origin (y is absolute height)
  vector_float3 camForward;  // view direction, unit
  vector_float3 sunDir;      // towards the sun (or moon), unit
  vector_float3 sunColor;    // direct light; zero when overcast
  vector_float3 skyAmbient;  // hemisphere light from above
  vector_float3 groundAmbient;  // … and from below
  vector_float3 skyZenith;
  vector_float3 skyHorizon;
  vector_float3 fogColor;
  vector_float3 cloudColor;
  vector_float3 whiteBalance;   // multiplies the image before tone mapping
  vector_float3 lampColor;      // street lamps, light fixtures (on as much as `night` says)
  vector_float4 shadowSplits;   // x, y: far view depth of cascades 0 and 1; z, w: their texel size (m)
  vector_float2 sunScreen;      // the sun in texture coordinates (0…1, y down), for light shafts
  float sunOnScreen;            // 0 when the sun is behind the camera or below the horizon
  float originZ;                // absolute z of world z = 0 (floating origin)
  float time;                   // seconds, wrapped
  float fogDensity;             // extinction per metre at height 0
  float fogFalloff;             // per metre of height
  float inscatter;              // sunlight the fog scatters toward the camera
  float cloudCover;             // 0 clear … 1 overcast
  float sunDisk;                // the sun's disk and glow in the sky, 0…1
  float shadowStrength;         // 0 (no shadows) … 1
  float wetness;                // 0 dry … 1 after rain
  float night;                  // 0 day … 1 street lamps and lit windows; indoors: fixtures' power
  float stars;
  float exposure;               // linear multiplier
  float saturation;
  float contrast;
  float bloom;
  float shafts;
  float grain;                  // noise standard deviation, display units (0…1)
  float vignette;
  float focusDistance;          // metres; the depth-aware blur is weakest near it
  float shadowPass;             // 1 while drawing the shadow map
  float frameIndex;             // for grain
  // Host passes a scene may turn on (adjustLighting:); zero = off, so other scenes stay as they were.
  float aoStrength;             // ambient occlusion on the light a scene marked as ambient (SceneColor.ambient)
  float aoRadius;               // metres
  float projScale;              // pixels per metre at 1 m view depth (full-size image)
  float motionBlur;             // shutter as a fraction of the frame interval
  matrix_float4x4 prevViewProj; // the previous frame's camera, in this frame's coordinates (motion blur)
  vector_float3 matchTint;      // display-space white balance toward the webcam's (1 = none)
  float matchLift;              // the webcam's black level, display units (0 = none)
  float matchGain;              // display-space gain toward the webcam's white level (1 = none)
  float lens;                   // 0 … 1: a webcam lens's barrel distortion and colour fringes
  float shadowSoftness;         // 0: the plain 4-tap filter; > 0: penumbrae that widen with the
                                // distance to the caster (sun's angular size, radians)
  // CoastEnvironment's sky and weather (zero elsewhere).
  vector_float3 skySun;         // the sunlight on the clouds and the distant sea (sunColor: what reaches the scene)
  vector_float2 windDir;        // where the wind blows (xz, unit)
  float wind;                   // m/s near the surface: waves, whitecaps, swaying trees, drifting clouds
  float cloudBase;              // the cloud layer's base above the sea (m)
  float cloudDepth;             // … and its thickness (m)
  float clearHorizon;           // 0 … 1: how much the clouds give way to clear sky toward the horizon
  float clearDistance;          // … from how far (m, toward the sun; twice that away from it)
  float cirrus;                 // high, thin streaks of cloud, 0 … 1
  float storm;                  // 0 … 1: heavy, ragged cloud bases, rain curtains
  float contrails;              // 0 … 1: aircraft trails high in a clear sky
  float cumulus;                // 0 … 1: clouds seen from near and below: heaped, narrowing upward, billowing sides
} FrameUniforms;
