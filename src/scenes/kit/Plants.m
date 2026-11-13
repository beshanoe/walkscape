#import "Plants.h"

#import <Metal/Metal.h>

#import "SceneUtil.h"

static const simd_float3 kUp = {0, 1, 0};

/// Rotates `v` about unit `axis` by `angle`.
static simd_float3 Rotate(simd_float3 v, simd_float3 axis, float angle) {
  float c = cosf(angle), s = sinf(angle);
  return v * c + simd_cross(axis, v) * s + axis * simd_dot(axis, v) * (1 - c);
}

/// `count` leaf cards in an ellipsoid crown, mostly near its surface, facing outward with some
/// scatter. The lighting normal points away from the crown's centre (lit as one rounded mass);
/// cards deep inside are darker (vertex colour x).
static void CrownCards(MeshBuilder *m, simd_float3 center, simd_float3 radii, int count, float size, float hang) {
  for (int i = 0; i < count; i++) {
    simd_float3 dir = [m randomDirection];
    float r = powf((float)[m random], 0.45f);
    simd_float3 p = center + dir * radii * r;
    simd_float3 out = simd_normalize(dir / radii);
    simd_float3 face = simd_normalize(out + [m randomDirection] * 0.75f);
    // The twig end of the texture (v = 0) toward the crown, leaves outward, then a random twist.
    simd_float3 along = out + kUp * (0.4f - hang);
    along = simd_normalize(along - face * simd_dot(along, face));
    along = Rotate(along, face, (float)[m randomFrom:-0.7 to:0.7]);
    simd_float3 across = simd_cross(face, along);
    float s = size * (float)[m randomFrom:0.75 to:1.25];
    float ao = (0.45f + 0.55f * r) * (0.82f + 0.18f * out.y);
    simd_float3 lit = simd_normalize(out + kUp * 0.25f);
    [m cardAt:p - along * s * 0.45f along:along across:across length:s width:s v0:0 v1:1 normal:lit color:(simd_float3){ao, (float)[m random], 0}];
  }
}

/// A branch from `from` toward `to`, bark.
static void Branch(MeshBuilder *m, simd_float3 from, simd_float3 to, float r0, float r1, simd_float3 color) {
  float material = m.material;
  m.material = kMaterialBark;
  [m tubeFrom:from to:to r0:r0 r1:r1 segments:5 color:color toColor:color vScale:20];
  m.material = material;
}

#pragma mark - Conifers

static void Spruce(MeshBuilder *m, BOOL lite) {
  m.material = kMaterialBark;
  [m tubeFrom:(simd_float3){0, -0.02f, 0} to:(simd_float3){0, 1, 0} r0:0.014f r1:0.0015f segments:8 color:Hex(0x433a33) toColor:Hex(0x544a40) vScale:30];
  m.material = kMaterialCard + kCellSpruce;
  int whorls = lite ? 11 : 19;
  for (int w = 0; w < whorls; w++) {
    float t = (w + (float)[m random] * 0.5f) / whorls;  // 0 bottom … 1 top
    float y = 0.2f + t * 0.78f;
    float reach = 0.025f + 0.17f * powf(1 - t, 0.9f);
    int branches = lite ? 5 : 7;
    float phase = (float)[m random] * 6.283f;
    for (int b = 0; b < branches; b++) {
      float theta = phase + b * 6.283f / branches + (float)[m randomFrom:-0.25 to:0.25];
      simd_float3 d = {cosf(theta), 0, sinf(theta)};
      float droop = -0.1f - 0.2f * (1 - t) + (float)[m randomFrom:-0.08 to:0.08];
      float len = reach * (float)[m randomFrom:0.85 to:1.15];
      float ao = 0.45f + 0.55f * t;
      simd_float3 lit = simd_normalize(d * 0.75f + kUp * 0.65f);
      // The branch in one or two sprays, each twisted a little about the branch: no flat fans.
      int sprays = lite || len < 0.06f ? 1 : 2;
      simd_float3 at = (simd_float3){0, y, 0} + d * 0.003f;
      for (int k = 0; k < sprays; k++) {
        float segment = len / sprays * (k ? 1.05f : 1.2f);
        simd_float3 along = simd_normalize(d + kUp * (droop - 0.12f * k));
        simd_float3 across = Rotate(simd_normalize(simd_cross(kUp, d)), along, (float)[m randomFrom:-0.6 to:0.6]);
        float width = fmaxf(segment * (k ? 1.0f : 0.8f), 0.03f) * (lite ? 1.15f : 1.0f);
        [m cardAt:at along:along across:across length:segment width:width v0:0 v1:1 normal:lit
            color:(simd_float3){ao * (0.85f + 0.3f * k), (float)[m random], 0}];
        at += along * segment * 0.8f;
      }
    }
  }
  // The leader at the top.
  simd_float3 a = simd_normalize((simd_float3){1, 0, 0.3f});
  for (int i = 0; i < 2; i++) {
    simd_float3 across = i ? simd_cross(kUp, a) : a;
    [m cardAt:(simd_float3){0, 0.9f, 0} along:kUp across:across length:0.1f width:0.035f v0:0.2f v1:1 normal:kUp color:(simd_float3){1, 0.5f, 0}];
  }
}

static void Pine(MeshBuilder *m, BOOL lite) {
  m.material = kMaterialBark;
  [m tubeFrom:(simd_float3){0, -0.02f, 0} to:(simd_float3){0, 0.55f, 0} r0:0.016f r1:0.009f segments:8 color:Hex(0x4a4038) toColor:Hex(0x5e4a3c) vScale:30];
  simd_float3 lean = {(float)[m randomFrom:-0.03 to:0.03], 1, (float)[m randomFrom:-0.03 to:0.03]};
  simd_float3 top = lean * 0.97f;
  [m tubeFrom:(simd_float3){0, 0.55f, 0} to:top r0:0.009f r1:0.003f segments:7 color:Hex(0x5e4a3c) toColor:Hex(0x8a6250) vScale:30];
  m.material = kMaterialCard + kCellPine;
  int branches = lite ? 5 : 8;
  for (int b = 0; b < branches; b++) {
    float y = 0.62f + 0.3f * b / branches + (float)[m randomFrom:-0.02 to:0.02];
    float theta = b * 2.4f + (float)[m random];
    simd_float3 d = {cosf(theta), 0, sinf(theta)};
    float reach = 0.07f + 0.1f * (1 - (y - 0.62f) / 0.35f) * (float)[m randomFrom:0.7 to:1.2];
    simd_float3 from = lean * y, end = from + d * reach + kUp * (float)[m randomFrom:0.03 to:0.1];
    Branch(m, from, end, 0.004f, 0.0018f, Hex(0x7a5440));
    CrownCards(m, end, (simd_float3){0.065f, 0.042f, 0.065f}, lite ? 10 : 24, lite ? 0.05f : 0.038f, 0.2f);
  }
  CrownCards(m, top, (simd_float3){0.055f, 0.04f, 0.055f}, lite ? 8 : 18, lite ? 0.048f : 0.036f, 0.2f);
}

#pragma mark - Broadleaf trees

/// A deciduous tree: trunk to `trunkTop`, main branches to `blobs` crown parts.
static void Deciduous(MeshBuilder *m, BOOL lite, BOOL bare, float trunkTop, float r0, simd_float3 bark0, simd_float3 bark1, int blobs,
                      float crownLow, float crownHigh, float spread, float blobRadius, int cardsPerBlob, float cardSize, int cell,
                      float hang, BOOL birch) {
  m.material = birch ? kMaterialBirch : kMaterialBark;
  simd_float3 bend = {(float)[m randomFrom:-0.02 to:0.02], 0, (float)[m randomFrom:-0.02 to:0.02]};
  simd_float3 top = (simd_float3){0, trunkTop, 0} + bend;
  [m tubeFrom:(simd_float3){0, -0.03f, 0} to:(simd_float3){0, 0.06f, 0} r0:r0 * 1.3f r1:r0 segments:8 color:bark0 * 0.8f toColor:bark0 vScale:30];
  [m tubeFrom:(simd_float3){0, 0.06f, 0} to:top r0:r0 r1:r0 * 0.6f segments:8 color:bark0 toColor:bark1 vScale:30];
  float phase = (float)[m random] * 6.283f;
  for (int i = 0; i < blobs; i++) {
    float theta = phase + i * 6.283f / blobs + (float)[m randomFrom:-0.4 to:0.4];
    float k = (float)i / MAX(blobs - 1, 1);
    float rad = spread * (float)[m randomFrom:0.45 to:1.0];
    simd_float3 c = {cosf(theta) * rad, crownLow + (crownHigh - crownLow) * (0.25f + 0.75f * (float)[m random]), sinf(theta) * rad};
    if (i == 0) c = (simd_float3){bend.x, crownHigh, bend.z};  // the top
    simd_float3 from = top - kUp * (float)[m randomFrom:0.0 to:0.12] * (1 - k);
    m.material = birch ? kMaterialBirch : kMaterialBark;
    [m tubeFrom:from to:c r0:r0 * 0.45f r1:r0 * 0.15f segments:5 color:bark1 toColor:bark1 vScale:30];
    if (bare) {  // winter: twigs where the leaves were
      for (int t = 0; t < 4; t++) {
        simd_float3 tip = c + [m randomDirection] * blobRadius * 0.9f + kUp * blobRadius * 0.3f;
        [m tubeFrom:c to:tip r0:r0 * 0.12f r1:r0 * 0.03f segments:4 color:bark1 toColor:bark1 vScale:30];
      }
      continue;
    }
    m.material = kMaterialCard + cell;
    float br = blobRadius * (float)[m randomFrom:0.8 to:1.15];
    CrownCards(m, c, (simd_float3){br, br * 0.8f, br}, lite ? cardsPerBlob / 2 : cardsPerBlob, cardSize * (lite ? 1.4f : 1), hang);
  }
}

#pragma mark - Undergrowth and props

static void Bush(MeshBuilder *m, BOOL bare) {
  for (int i = 0; i < 4; i++) {
    simd_float3 c = {(float)[m randomFrom:-0.35 to:0.35], (float)[m randomFrom:0.35 to:0.6], (float)[m randomFrom:-0.35 to:0.35]};
    if (bare) {
      for (int t = 0; t < 5; t++) Branch(m, (simd_float3){0, 0, 0}, c + [m randomDirection] * 0.35f, 0.02f, 0.006f, Hex(0x4a3b30));
      continue;
    }
    m.material = kMaterialCard + kCellLeaves;
    float r = (float)[m randomFrom:0.32 to:0.48];
    CrownCards(m, c, (simd_float3){r, r * 0.8f, r}, 26, 0.32f, 0.3f);
  }
}

static void Fern(MeshBuilder *m) {
  m.material = kMaterialCard + kCellFern;
  int fronds = 9;
  float phase = (float)[m random] * 6.283f;
  for (int i = 0; i < fronds; i++) {
    float theta = phase + i * 6.283f / fronds + (float)[m randomFrom:-0.2 to:0.2];
    simd_float3 d = {cosf(theta), 0, sinf(theta)};
    float rise = (float)[m randomFrom:0.9 to:1.6];
    float len = (float)[m randomFrom:0.45 to:0.6];
    simd_float3 a1 = simd_normalize(d + kUp * rise), a2 = simd_normalize(d + kUp * (rise - 1.2f));
    simd_float3 across = simd_normalize(simd_cross(kUp, d));
    simd_float3 lit = simd_normalize(d * 0.4f + kUp);
    simd_float3 mid = a1 * len;
    float ao = (float)[m randomFrom:0.75 to:1.0];
    [m cardAt:(simd_float3){0, 0, 0} along:a1 across:across length:len width:0.42f v0:0 v1:0.5f normal:lit color:(simd_float3){ao * 0.8f, (float)[m random], 0}];
    [m cardAt:mid along:a2 across:across length:len width:0.42f v0:0.5f v1:1 normal:lit color:(simd_float3){ao, (float)[m random], 0}];
  }
}

static void Grass(MeshBuilder *m) {
  m.material = kMaterialCard + kCellGrass;
  float phase = (float)[m random] * 3.14f;
  for (int i = 0; i < 3; i++) {
    float theta = phase + i * 1.047f;
    simd_float3 across = {cosf(theta), 0, sinf(theta)};
    simd_float3 lean = simd_normalize(kUp + simd_cross(across, kUp) * (float)[m randomFrom:-0.25 to:0.25]);
    [m cardAt:(simd_float3){0, -0.05f, 0} along:lean across:across length:1.05f width:1.1f v0:0 v1:1 normal:kUp color:(simd_float3){0.9f, (float)[m random], 0}];
  }
}

static void Rock(MeshBuilder *m, int variant) {
  m.material = kMaterialRock;
  // A subdivided icosahedron, displaced by a hash of each vertex's direction (shared vertices stay shared).
  const float t = (1.0f + sqrtf(5.0f)) / 2.0f;
  simd_float3 v[12] = {{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0}, {0, -1, t}, {0, 1, t},
                       {0, -1, -t}, {0, 1, -t}, {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}};
  static const int f[20][3] = {{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11}, {1, 5, 9}, {5, 11, 4},
                               {11, 10, 2}, {10, 7, 6}, {7, 1, 8}, {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8},
                               {3, 8, 9}, {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1}};
  simd_float3 (^shape)(simd_float3) = ^simd_float3(simd_float3 dir) {
    dir = simd_normalize(dir);
    float h = sinf(dir.x * 5.1f + variant) * 0.12f + sinf(dir.z * 4.3f - dir.y * 3.1f + variant * 2) * 0.1f + sinf(dir.y * 9.0f + dir.x * 7.0f) * 0.05f;
    simd_float3 p = dir * (1 + h);
    return (simd_float3){p.x * 0.55f, p.y * 0.38f + 0.3f, p.z * 0.5f};
  };
  simd_float3 color = Hex(variant == 1 ? 0x837f74 : 0x6f6c66);
  for (int i = 0; i < 20; i++) {
    simd_float3 a = v[f[i][0]], b = v[f[i][1]], c = v[f[i][2]];
    simd_float3 ab = (a + b) / 2, bc = (b + c) / 2, ca = (c + a) / 2;
    simd_float3 tris[4][3] = {{a, ab, ca}, {ab, b, bc}, {ca, bc, c}, {ab, bc, ca}};
    for (int k = 0; k < 4; k++) {
      for (int j = 0; j < 3; j++) {
        simd_float3 p = shape(tris[k][j]);
        simd_float3 n = simd_normalize((simd_float3){p.x / 0.3f, (p.y - 0.3f) / 0.2f, p.z / 0.27f});
        [m vertex:p normal:n color:color uv:(simd_float2){p.x, p.z}];
      }
    }
  }
}

static void Log(MeshBuilder *m) {
  m.material = kMaterialBark;
  float len = (float)[m randomFrom:3.5 to:5.0];
  [m tubeFrom:(simd_float3){-len, 0.45f, 0} to:(simd_float3){len, 0.42f, 0} r0:0.5f r1:0.45f segments:10 color:Hex(0x4a3c30) toColor:Hex(0x544233) vScale:2];
  m.material = 0;
  for (int e = 0; e < 2; e++) {  // cut ends
    float x = e ? len : -len, r = e ? 0.45f : 0.5f, y = e ? 0.42f : 0.45f;
    simd_float3 n = {e ? 1.0f : -1.0f, 0, 0};
    for (int i = 0; i < 10; i++) {
      float a0 = 6.283f * i / 10, a1 = 6.283f * (i + 1) / 10;
      [m vertex:(simd_float3){x, y, 0} normal:n color:Hex(0x9a7a55) uv:(simd_float2){0, 0}];
      [m vertex:(simd_float3){x, y + r * cosf(a0), r * sinf(a0)} normal:n color:Hex(0x7a5f45) uv:(simd_float2){0, 0}];
      [m vertex:(simd_float3){x, y + r * cosf(a1), r * sinf(a1)} normal:n color:Hex(0x7a5f45) uv:(simd_float2){0, 0}];
    }
  }
}

static void Stump(MeshBuilder *m) {
  m.material = kMaterialBark;
  [m tubeFrom:(simd_float3){0, -0.1f, 0} to:(simd_float3){0, 1, 0} r0:0.9f r1:0.7f segments:10 color:Hex(0x45382e) toColor:Hex(0x4f4034) vScale:2];
  m.material = 0;
  for (int i = 0; i < 10; i++) {
    float a0 = 6.283f * i / 10, a1 = 6.283f * (i + 1) / 10;
    [m vertex:(simd_float3){0, 1, 0} normal:kUp color:Hex(0xa08060) uv:(simd_float2){0, 0}];
    [m vertex:(simd_float3){0.7f * cosf(a1), 1, 0.7f * sinf(a1)} normal:kUp color:Hex(0x806548) uv:(simd_float2){0, 0}];
    [m vertex:(simd_float3){0.7f * cosf(a0), 1, 0.7f * sinf(a0)} normal:kUp color:Hex(0x806548) uv:(simd_float2){0, 0}];
  }
}

void PlantCrown(MeshBuilder *m, simd_float3 center, simd_float3 radii, int count, float size, float hang) {
  CrownCards(m, center, radii, count, size, hang);
}

NSData *PlantMesh(PlantKind kind, int variant, BOOL lite, BOOL bare) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:(uint32_t)(101 + kind * 31 + variant * 7)];
  switch (kind) {
    case PlantSpruce: Spruce(m, lite); break;
    case PlantPine: Pine(m, lite); break;
    case PlantOak:
      Deciduous(m, lite, bare, 0.5f, 0.02f, Hex(0x4d4036), Hex(0x564739), 7, 0.55f, 0.9f, 0.17f, 0.15f, 30, 0.1f, kCellLeaves, 0.25f, NO);
      break;
    case PlantBeech:
      Deciduous(m, lite, bare, 0.6f, 0.017f, Hex(0x7d7b72), Hex(0x8b887d), 7, 0.62f, 0.95f, 0.12f, 0.13f, 28, 0.1f, kCellLeaves, 0.2f, NO);
      break;
    case PlantBirch:
      Deciduous(m, lite, bare, 0.8f, 0.011f, Hex(0xd9d6cc), Hex(0xd0cdc2), 8, 0.45f, 0.96f, 0.09f, 0.085f, 24, 0.07f, kCellBirchLeaves, 0.55f, YES);
      break;
    case PlantBush: Bush(m, bare); break;
    case PlantFern: Fern(m); break;
    case PlantGrass: Grass(m); break;
    case PlantRock: Rock(m, variant); break;
    case PlantLog: Log(m); break;
    case PlantStump: Stump(m); break;
    case PlantPlane:
      Deciduous(m, lite, bare, 0.36f, 0.017f, Hex(0x8a846c), Hex(0x958e74), 10, 0.42f, 0.98f, 0.2f, 0.15f, 34, 0.112f, kCellPlaneLeaves, 0.15f, NO);
      break;
    case PlantKindCount: break;
  }
  return m.data;
}

id<MTLTexture> FoliageAtlas(id<MTLDevice> device, id<MTLLibrary> lib, NSError **error) {
  id<MTLComputePipelineState> bake = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bake_foliage"] error:error];
  if (!bake) return nil;
  MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:kAtlasCell * kAtlasColumns
                                                                                height:kAtlasCell * kAtlasRows
                                                                             mipmapped:YES];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  td.storageMode = MTLStorageModePrivate;
  id<MTLTexture> atlas = [device newTextureWithDescriptor:td];
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
  [ce setComputePipelineState:bake];
  [ce setTexture:atlas atIndex:0];
  [ce dispatchThreads:MTLSizeMake(atlas.width, atlas.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
  [ce endEncoding];
  id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
  [be generateMipmapsForTexture:atlas];
  [be endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  return atlas;
}
