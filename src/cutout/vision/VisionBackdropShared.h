// Types shared by VisionBackdropEngine.m and VisionBackdrop.metal. The engine pastes this file
// above VisionBackdrop.metal, so it compiles both as C and as Metal: simd types only.

#pragma once

#include <simd/simd.h>

/// The low-resolution grid (statistics, linear models) is the camera's size / kVBScale.
#define kVBScale 4

typedef struct {
  vector_uint2 size;       // camera (luma) size
  vector_uint2 low;        // the low-resolution grid's size
  vector_float4 roi;       // the part of the frame Vision's mask covers: x0, y0, x1, y1 (0…1, top-left origin)
  vector_float2 bgScale;   // camera uv → background uv (aspect fill): uv * bgScale + bgOffset
  vector_float2 bgOffset;
  float camVideoRange;     // 1: '420v' (16…235), 0: '420f'
  float bgVideoRange;
  float eps;               // guided filter regularisation (variance units, YUV 0…1)
  float temporal;          // how much of last frame's mask stays where nothing moved (0…1)
  float bandRadius;        // how far the edge may move from Vision's (luma pixels)
  float explainedFrom;     // R² (colours explaining the mask) where the colour model starts to count
  float explainedTo;       // … and where it decides alpha alone
  float contrastFrom;      // the same for how far apart the person's and the old background's colours are
  float contrastTo;
  float edgeSharpen;       // the composite's alpha: the colour model's, this much steeper around 0.5
  int radius;              // guided filter radius (low-resolution pixels)
  int refine;              // 0: Vision's mask as it is (for comparisons)
  int hasPrevious;         // last frame's state is valid
  int writeMatte;          // also write the matte
} VBParams;
