#import "CorridorScene.h"

#import "Plants.h"
#import "IndoorEnvironment.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"

#pragma mark - Settings

static const uint32_t kWallPaint[5] = {0xebe7df, 0xbfb6aa, 0x98a68c, 0x2f3d5a, 0xb46a50};  // white, warm grey, sage, navy, terracotta
enum { kWindowsNone, kWindowsLeft, kWindowsRight };

typedef struct {
  float halfWidth, height, spacing, doors;
  int style, windows;
  BOOL decor;
  uint32_t seed;
} Layout;

/// Trim colour (frames, skirting, rails, portal) per style.
static simd_float3 TrimColor(int style) {
  return Hex(style == kStyleHotel ? 0x5a3e2b : style == kStyleOffice ? 0xc9c8c3 : 0xe4e0d6);
}

#pragma mark - Features along a wall

typedef enum { kFeatureDoor, kFeatureWindow, kFeaturePicture, kFeatureSconce } FeatureKind;

typedef struct {
  float z0, z1;
  FeatureKind kind;
  unsigned int seed;
} Feature;

enum { kMaxFeatures = 48 };

/// Doors (or windows, on the window side), then pictures and sconces in the gaps; sorted by z.
static int Features(const Layout *L, int64_t segment, int side, Feature *out) {
  Rng r = RngFor(L->seed, segment, side, 31);
  unsigned int base = SceneHash(L->seed, (unsigned int)(segment + 1000000) * 2 + (side > 0));
  int n = 0;
  BOOL windows = (L->windows == kWindowsLeft && side < 0) || (L->windows == kWindowsRight && side > 0);
  if (windows) {
    for (float z = 1.4f; z + 1.4f < kSegmentLength - 0.4f && n < kMaxFeatures; z += 2.7f) {
      out[n] = (Feature){z, z + 1.4f, kFeatureWindow, SceneHash(base, (unsigned int)n)};
      n++;
    }
    return n;
  }
  float z = 0.9f + (float)Range(&r, 0.3, 2.0);
  while (z + 1.2f < kSegmentLength - 0.5f && n < kMaxFeatures / 2) {
    if (Rand(&r) < L->doors) {
      out[n] = (Feature){z, z + 0.95f, kFeatureDoor, SceneHash(base, (unsigned int)n)};
      n++;
      z += 0.95f + (float)Range(&r, 1.4, 4.2);
    } else {
      z += (float)Range(&r, 1.5, 3.0);
    }
  }
  // Pictures (or a sconce) in the wider gaps between doors.
  int doors = n;
  float start = 0.6f;
  for (int i = 0; i <= doors && n < kMaxFeatures; i++) {
    float end = i < doors ? out[i].z0 - 0.15f : kSegmentLength - 0.3f;
    float gap = end - start;
    if (L->decor && gap > 1.8f && Rand(&r) < 0.65) {
      float w = fminf(gap - 0.7f, (float)Range(&r, 0.6, 1.15)), c = start + gap / 2;
      out[n] = (Feature){c - w / 2, c + w / 2, kFeaturePicture, SceneHash(base, (unsigned int)(100 + n))};
      n++;
    } else if (L->style == kStyleHotel && gap > 1.0f) {
      float c = start + gap / 2;
      out[n++] = (Feature){c - 0.08f, c + 0.08f, kFeatureSconce, 0};
    }
    if (i < doors) start = out[i].z1 + 0.15f;
  }
  // Sort by z (insertion; few items).
  for (int i = 1; i < n; i++) {
    for (int j = i; j > 0 && out[j].z0 < out[j - 1].z0; j--) {
      Feature t = out[j];
      out[j] = out[j - 1];
      out[j - 1] = t;
    }
  }
  return n;
}

#pragma mark - Segment meshes

/// Wall geometry is written in "wall space": d = metres into the wall (negative: into the
/// corridor), y up, z along the segment.
typedef struct {
  __unsafe_unretained MeshBuilder *m;
  float side, halfWidth, height;
} Wall;

static simd_float3 W(const Wall *w, float d, float y, float z) {
  return (simd_float3){w->side * (w->halfWidth + d), y, z};
}

static simd_float3 Inward(const Wall *w) {
  return (simd_float3){-w->side, 0, 0};
}

/// A wall-plane quad at depth d (faces the corridor; uv = metres along z, up).
static void WallQuad(const Wall *w, float d, float z0, float z1, float y0, float y1) {
  w->m.material = kHallWall;
  [w->m quadA:W(w, d, y0, z0) b:W(w, d, y0, z1) c:W(w, d, y1, z1) d:W(w, d, y1, z0) normal:Inward(w) color:(simd_float3){0, 0, 0}
          uvA:(simd_float2){z0, y0} uvB:(simd_float2){z1, y0} uvC:(simd_float2){z1, y1} uvD:(simd_float2){z0, y1}];
}

static void WallBox(const Wall *w, float d0, float d1, float y0, float y1, float z0, float z1, simd_float3 color) {
  simd_float3 p = W(w, d0, y0, z0), q = W(w, d1, y1, z1);
  w->m.material = kHallPlain;
  [w->m boxFrom:simd_min(p, q) to:simd_max(p, q) color:color];
}

/// The sides of an opening z0…z1, y0…y1, from the wall plane to depth `depth`.
static void Reveal(const Wall *w, float depth, float z0, float z1, float y0, float y1, BOOL bottom) {
  MeshBuilder *m = w->m;
  m.material = kHallWall;
  simd_float3 none = {0, 0, 0};
  [m quadA:W(w, 0, y0, z0) b:W(w, depth, y0, z0) c:W(w, depth, y1, z0) d:W(w, 0, y1, z0) normal:(simd_float3){0, 0, 1} color:none
       uvA:(simd_float2){z0, y0} uvB:(simd_float2){z0 + depth, y0} uvC:(simd_float2){z0 + depth, y1} uvD:(simd_float2){z0, y1}];
  [m quadA:W(w, 0, y0, z1) b:W(w, depth, y0, z1) c:W(w, depth, y1, z1) d:W(w, 0, y1, z1) normal:(simd_float3){0, 0, -1} color:none
       uvA:(simd_float2){z1, y0} uvB:(simd_float2){z1 + depth, y0} uvC:(simd_float2){z1 + depth, y1} uvD:(simd_float2){z1, y1}];
  [m quadA:W(w, 0, y1, z0) b:W(w, 0, y1, z1) c:W(w, depth, y1, z1) d:W(w, depth, y1, z0) normal:(simd_float3){0, -1, 0} color:none
       uvA:(simd_float2){z0, y1} uvB:(simd_float2){z1, y1} uvC:(simd_float2){z1, y1 + depth} uvD:(simd_float2){z0, y1 + depth}];
  if (bottom) {
    [m quadA:W(w, 0, y0, z0) b:W(w, 0, y0, z1) c:W(w, depth, y0, z1) d:W(w, depth, y0, z0) normal:(simd_float3){0, 1, 0} color:none
         uvA:(simd_float2){z0, y0} uvB:(simd_float2){z1, y0} uvC:(simd_float2){z1, y0 + depth} uvD:(simd_float2){z0, y0 + depth}];
  }
}

/// One wall of a segment: plain wall between the features, doors and windows set into it,
/// skirting, rails, crown moulding, pictures.
static void BuildWall(const Wall *w, const Layout *L, const Feature *features, int n) {
  MeshBuilder *m = w->m;
  float H = w->height;
  simd_float3 trim = TrimColor(L->style);
  float z = 0.35f;  // after the portal
  float gapStart = z;
  for (int i = 0; i <= n; i++) {
    const Feature *f = i < n ? &features[i] : NULL;
    if (f && (f->kind == kFeaturePicture || f->kind == kFeatureSconce)) continue;
    float end = f ? f->z0 : kSegmentLength;
    WallQuad(w, 0, z, end, 0, H);
    // Skirting and rails along the stretch of wall before this opening (under windows too).
    float railEnd = f && f->kind == kFeatureDoor ? end - 0.08f : end;
    WallBox(w, -0.015f, 0, 0, 0.1f, gapStart, railEnd, trim);
    if (L->style != kStyleOffice && !(f && f->kind == kFeatureWindow)) WallBox(w, -0.02f, 0, 0.88f, 0.94f, gapStart, railEnd, trim);
    if (!f) break;
    if (f->kind == kFeatureDoor) {
      WallQuad(w, 0, f->z0, f->z1, kDoorHeight, H);
      Reveal(w, 0.12f, f->z0, f->z1, 0, kDoorHeight, NO);
      m.material = kHallDoor;
      [m quadA:W(w, 0.12f, 0, f->z0) b:W(w, 0.12f, 0, f->z1) c:W(w, 0.12f, kDoorHeight, f->z1) d:W(w, 0.12f, kDoorHeight, f->z0) normal:Inward(w)
           color:(simd_float3){(float)(f->seed & 0xFFFF), 0, 0} uvA:(simd_float2){0, 0} uvB:(simd_float2){1, 0} uvC:(simd_float2){1, 1}
             uvD:(simd_float2){0, 1}];
      // Architrave, handle and a number plate.
      WallBox(w, -0.02f, 0, 0, kDoorHeight + 0.08f, f->z0 - 0.08f, f->z0, trim);
      WallBox(w, -0.02f, 0, 0, kDoorHeight + 0.08f, f->z1, f->z1 + 0.08f, trim);
      WallBox(w, -0.02f, 0, kDoorHeight, kDoorHeight + 0.08f, f->z0 - 0.08f, f->z1 + 0.08f, trim);
      float hz = (f->seed & 1) ? f->z0 + 0.08f : f->z1 - 0.14f;
      WallBox(w, 0.06f, 0.12f, 1.0f, 1.04f, hz, hz + 0.06f, Hex(0xb0a88e));
      WallBox(w, 0.11f, 0.12f, 1.5f, 1.62f, (f->z0 + f->z1) / 2 - 0.07f, (f->z0 + f->z1) / 2 + 0.07f, Hex(0xc8b88a));
    } else if (f->kind == kFeatureWindow) {
      WallQuad(w, 0, f->z0, f->z1, 0, kWindowSill);
      WallQuad(w, 0, f->z0, f->z1, kWindowHead, H);
      Reveal(w, 0.25f, f->z0, f->z1, kWindowSill, kWindowHead, YES);
      m.material = kHallWindow;
      [m quadA:W(w, 0.25f, kWindowSill, f->z0) b:W(w, 0.25f, kWindowSill, f->z1) c:W(w, 0.25f, kWindowHead, f->z1)
               d:W(w, 0.25f, kWindowHead, f->z0) normal:Inward(w) color:(simd_float3){0, 0, 0} uvA:(simd_float2){0, 0}
             uvB:(simd_float2){1, 0} uvC:(simd_float2){1, 1} uvD:(simd_float2){0, 1}];
      WallBox(w, -0.05f, 0.02f, kWindowSill - 0.04f, kWindowSill, f->z0 - 0.05f, f->z1 + 0.05f, trim);  // sill board
    }
    z = f->z1;
    gapStart = f->kind == kFeatureDoor ? f->z1 + 0.08f : f->z0;
  }
  if (L->style != kStyleOffice) WallBox(w, -0.07f, 0, H - 0.09f, H, 0.35f, kSegmentLength, trim);  // crown moulding
  // Pictures: a frame and the painting.
  for (int i = 0; i < n; i++) {
    const Feature *f = &features[i];
    if (f->kind != kFeaturePicture) continue;
    float h = (f->z1 - f->z0) * (0.65f + 0.25f * SceneHashF(f->seed, 1u)), y0 = 1.55f - h / 2;
    WallBox(w, -0.035f, 0, y0 - 0.05f, y0 + h + 0.05f, f->z0 - 0.05f, f->z1 + 0.05f, Hex(L->style == kStyleOffice ? 0x2a2a2a : 0x8a6a3a));
    m.material = kHallPainting;
    [m quadA:W(w, -0.036f, y0, f->z0) b:W(w, -0.036f, y0, f->z1) c:W(w, -0.036f, y0 + h, f->z1) d:W(w, -0.036f, y0 + h, f->z0) normal:Inward(w)
         color:(simd_float3){(float)(f->seed & 0xFFFF), 0, 0} uvA:(simd_float2){0, 0} uvB:(simd_float2){1, 0} uvC:(simd_float2){1, 1}
           uvD:(simd_float2){0, 1}];
  }
}

/// Segment `segment`'s mesh in segment coordinates (z from its start): floor, ceiling, both walls,
/// the portal with its exit sign.
static NSData *SegmentMesh(const Layout *L, int64_t segment) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:(uint32_t)segment];
  float hw = L->halfWidth, H = L->height;
  simd_float3 none = {0, 0, 0};
  m.material = kHallFloor;
  [m quadA:(simd_float3){-hw - 0.3f, 0, 0} b:(simd_float3){hw + 0.3f, 0, 0} c:(simd_float3){hw + 0.3f, 0, kSegmentLength}
         d:(simd_float3){-hw - 0.3f, 0, kSegmentLength} normal:(simd_float3){0, 1, 0} color:none uvA:(simd_float2){0, 0} uvB:(simd_float2){1, 0}
       uvC:(simd_float2){1, 1} uvD:(simd_float2){0, 1}];
  m.material = kHallCeiling;
  [m quadA:(simd_float3){-hw - 0.3f, H, 0} b:(simd_float3){hw + 0.3f, H, 0} c:(simd_float3){hw + 0.3f, H, kSegmentLength}
         d:(simd_float3){-hw - 0.3f, H, kSegmentLength} normal:(simd_float3){0, -1, 0} color:none uvA:(simd_float2){0, 0} uvB:(simd_float2){1, 0}
       uvC:(simd_float2){1, 1} uvD:(simd_float2){0, 1}];
  for (int side = -1; side <= 1; side += 2) {
    Wall w = {m, (float)side, hw, H};
    Feature features[kMaxFeatures];
    int n = Features(L, segment, side, features);
    BuildWall(&w, L, features, n);
  }
  // A thick slab above the ceiling, for the shadow map only: a thin ceiling lets the shadow
  // lookup's offset slip past it, leaking sun along the top of the walls.
  m.material = kHallShadowOnly;
  [m boxFrom:(simd_float3){-hw - 0.6f, H, 0} to:(simd_float3){hw + 0.6f, H + 0.5f, kSegmentLength} color:none];
  // The portal (fire-door frame) across the corridor, an exit sign under its header.
  simd_float3 trim = L->style == kStyleHotel ? Hex(0xd8d2c6) : TrimColor(L->style);
  m.material = kHallPlain;
  [m boxFrom:(simd_float3){-hw, 0, 0} to:(simd_float3){-hw + 0.18f, H, 0.35f} color:trim];
  [m boxFrom:(simd_float3){hw - 0.18f, 0, 0} to:(simd_float3){hw, H, 0.35f} color:trim];
  [m boxFrom:(simd_float3){-hw, H - 0.32f, 0} to:(simd_float3){hw, H, 0.35f} color:trim];
  m.material = kHallSign;
  [m boxFrom:(simd_float3){-0.17f, H - 0.55f, 0.36f} to:(simd_float3){0.17f, H - 0.37f, 0.4f} color:none];
  return m.data;
}

#pragma mark - Props

/// Hanging globe light (old building): a rod and a lit globe, the globe's centre 0.75 m below.
static NSData *PendantMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:401];
  m.material = 0;
  [m tubeFrom:(simd_float3){0, 0, 0} to:(simd_float3){0, -0.6f, 0} r0:0.012f r1:0.012f segments:6 color:Hex(0x6a5a3a) toColor:Hex(0x6a5a3a) vScale:1];
  m.material = kMaterialLamp;
  [m icosahedronAt:(simd_float3){0, -0.75f, 0} radius:(simd_float3){0.16f, 0.16f, 0.16f} color:Hex(0xf2ead8) jitter:0];
  return m.data;
}

/// Wall sconce (hotel): a small lit shade on a bracket; faces +x (yawed onto the wall).
static NSData *SconceMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:402];
  m.material = 0;
  [m boxFrom:(simd_float3){-0.02f, 1.62f, -0.04f} to:(simd_float3){0.1f, 1.66f, 0.04f} color:Hex(0x8a7a5a)];
  m.material = kMaterialLamp;
  [m tubeFrom:(simd_float3){0.12f, 1.64f, 0} to:(simd_float3){0.12f, 1.84f, 0} r0:0.08f r1:0.06f segments:10 color:Hex(0xf0e2c4) toColor:Hex(0xf0e2c4) vScale:1];
  return m.data;
}

/// A plant pot (the plant is a forest bush on top).
static NSData *PotMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:403];
  m.material = 0;
  [m tubeFrom:(simd_float3){0, 0, 0} to:(simd_float3){0, 0.48f, 0} r0:0.17f r1:0.23f segments:12 color:Hex(0x9a5a3e) toColor:Hex(0xa8644a) vScale:1];
  [m tubeFrom:(simd_float3){0, 0.46f, 0} to:(simd_float3){0, 0.47f, 0} r0:0.22f r1:0.001f segments:12 color:Hex(0x3a2a1e) toColor:Hex(0x3a2a1e) vScale:1];
  return m.data;
}

enum { kPropPendant, kPropSconce, kPropPot, kPropPlant, kPropKinds };

#pragma mark - Scene

@interface CorridorSegment : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NSUInteger vertices;
@end

@implementation CorridorSegment
@end

@implementation CorridorScene {
  id<MTLDevice> _device;
  id<MTLRenderPipelineState> _hallPipe, _hallShadowPipe, _plantPipe, _plantShadowPipe;
  id<MTLDepthStencilState> _depthOn;
  id<MTLTexture> _atlas;
  id<MTLBuffer> _meshes[kPropKinds];
  NSUInteger _meshVertices[kPropKinds];
  NSMutableDictionary<NSNumber *, CorridorSegment *> *_segments;
  id<MTLBuffer> _instances;
  NSUInteger _groupBase[kPropKinds], _groupCount[kPropKinds], _instanceTotal;

  double _originZ;
  int64_t _builtTile;
  uint64_t _builtLayout;
  Layout _layout;
  CorridorUniforms _uniforms;
  PlantUniforms _plantUniforms;
}

+ (void)load {
  [SceneRegistry registerScene:self];
}

+ (NSString *)identifier {
  return @"corridor";
}

+ (NSString *)title {
  return @"Corridor";
}

+ (Class)environment {
  return IndoorEnvironment.class;
}

+ (NSArray<SceneParameter *> *)parameters {
  NSString *hall = @"Corridor";
  return @[
    [IndoorEnvironment lightingParameter:IndoorEnvironment.presetNames default:@"Warm evening"],
    [[SceneParameter choiceWithKey:@"style" title:@"Style" section:hall choices:@[ @"Hotel", @"Office", @"Old building" ] value:0] relayout],
    [SceneParameter choiceWithKey:@"walls" title:@"Walls" section:hall choices:@[ @"White", @"Warm grey", @"Sage", @"Navy", @"Terracotta" ]
                            value:1],
    [SceneParameter choiceWithKey:@"floor" title:@"Floor" section:hall choices:@[ @"Carpet", @"Wood", @"Polished stone" ] value:0],
    [[SceneParameter choiceWithKey:@"windows" title:@"Windows" section:hall choices:@[ @"None", @"On the left", @"On the right" ] value:0]
        relayout],
    [[SceneParameter sliderWithKey:@"width" title:@"Width" section:hall minimum:1.8 maximum:4.5 step:0.1 value:2.4 format:@"%.1f m"] relayout],
    [[SceneParameter sliderWithKey:@"height" title:@"Ceiling height" section:hall minimum:2.4 maximum:4.5 step:0.1 value:2.8 format:@"%.1f m"]
        relayout],
    [[SceneParameter sliderWithKey:@"doors" title:@"Doors" section:hall minimum:0 maximum:1 step:0.05 value:0.7 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"spacing" title:@"Light spacing" section:hall minimum:2 maximum:6 step:0.1 value:3.2 format:@"%.1f m"] relayout],
    [[SceneParameter toggleWithKey:@"decor" title:@"Pictures and plants" section:hall value:YES] relayout],
    [SceneParameter seedWithKey:@"seed" title:@"New Corridor" section:hall value:5],
  ];
}

+ (NSArray<NSString *> *)shaderSources {
  // The kit's plant shaders draw the plants and light fittings.
  return @[ @"Plants.h", @"Plants.metal", @"CorridorScene.h", @"Corridor.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _segments = [NSMutableDictionary dictionary];
  _builtTile = INT64_MIN;
  _builtLayout = UINT64_MAX;
  _originZ = NAN;

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, NO);
  pd.vertexFunction = [lib newFunctionWithName:@"hall_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"hall_fs"];
  _hallPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  pd.alphaToCoverageEnabled = YES;  // the plants' leaves
  pd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"plant_fs"];
  _plantPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
  sd.depthAttachmentPixelFormat = kShadowFormat;
  sd.vertexFunction = [lib newFunctionWithName:@"hall_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"hall_shadow_fs"];
  _hallShadowPipe = [device newRenderPipelineStateWithDescriptor:sd error:error];
  sd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"plant_shadow_fs"];
  _plantShadowPipe = [device newRenderPipelineStateWithDescriptor:sd error:error];
  _atlas = FoliageAtlas(device, lib, error);
  if (!_hallPipe || !_plantPipe || !_hallShadowPipe || !_plantShadowPipe || !_atlas) return nil;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthOn = [device newDepthStencilStateWithDescriptor:dd];

  NSData *meshes[kPropKinds] = {PendantMesh(), SconceMesh(), PotMesh(), PlantMesh(PlantBush, 1, NO, NO)};
  for (int k = 0; k < kPropKinds; k++) {
    _meshes[k] = SceneBuffer(device, meshes[k]);
    _meshVertices[k] = meshes[k].length / sizeof(MeshVertex);
  }
  _plantUniforms.wind = 0;
  return self;
}

- (NSUInteger)instanceCount {
  return _instanceTotal;
}

- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values {
  return (WalkPoint){simd_make_double3(0, 0, metres), simd_make_double3(0, 0, 1)};
}

- (void)adjustLighting:(FrameUniforms *)u values:(SceneValues *)values {
  NSInteger windows = [values index:@"windows"];
  if (windows == kWindowsNone && simd_reduce_max(u->sunColor) > 0) {  // no daylight without windows: lights on
    u->sunColor = simd_make_float3(0, 0, 0);
    u->shadowStrength = 0;
    u->night = fmaxf(u->night, 0.8f);
  } else if (windows == kWindowsLeft) {
    u->sunDir.x = -u->sunDir.x;  // the presets' daylight comes from the right
  }
}

#pragma mark Layout

- (void)readSettings:(SceneValues *)values {
  Layout *L = &_layout;
  L->style = (int)MIN(MAX([values index:@"style"], 0), 2);
  L->windows = (int)MIN(MAX([values index:@"windows"], 0), 2);
  L->halfWidth = (float)[values number:@"width"] / 2;
  L->height = (float)[values number:@"height"];
  L->doors = (float)[values number:@"doors"];
  L->spacing = (float)[values number:@"spacing"];
  L->decor = [values flag:@"decor"];
  L->seed = (uint32_t)[values number:@"seed"];
  _uniforms.halfWidth = L->halfWidth;
  _uniforms.height = L->height;
  _uniforms.style = L->style;
  _uniforms.lightSpacing = L->spacing;
  _uniforms.lightY = L->style == kStyleOld ? L->height - 0.75f : L->height - 0.03f;
  [_segments removeAllObjects];
}

static void AddProp(NSMutableData *group, double x, double y, double z, double originZ, double yaw, double height, double width) {
  PlantInstance p;
  p.posYaw = simd_make_float4((float)x, (float)y, (float)(z - originZ), (float)yaw);
  p.shape = simd_make_float4((float)width, (float)height, 1, (float)fmod(z * 1.37, 6.28));
  p.tint = simd_make_float4(Hex(0x4c7a2c), 0);
  [group appendBytes:&p length:sizeof p];
}

- (void)rebuildPropsAround:(double)camZ {
  const Layout *L = &_layout;
  NSMutableData *groups[kPropKinds];
  for (int k = 0; k < kPropKinds; k++) groups[k] = [NSMutableData data];
  double zMin = camZ - 140, zMax = camZ + 30;
  if (L->style == kStyleOld) {  // a hanging globe at every fixture
    for (int64_t k = (int64_t)floor(zMin / L->spacing); k <= (int64_t)floor(zMax / L->spacing); k++) {
      AddProp(groups[kPropPendant], 0, L->height, (k + 0.5) * L->spacing, _originZ, 0, 1, 1);
    }
  }
  for (int64_t seg = (int64_t)floor(zMin / kSegmentLength); seg <= (int64_t)floor(zMax / kSegmentLength); seg++) {
    double bz = seg * (double)kSegmentLength;
    for (int side = -1; side <= 1; side += 2) {
      Feature f[kMaxFeatures];
      int n = Features(L, seg, side, f);
      for (int i = 0; i < n; i++) {
        if (f[i].kind == kFeatureSconce) {
          AddProp(groups[kPropSconce], side * L->halfWidth, 0, bz + (f[i].z0 + f[i].z1) / 2, _originZ, side > 0 ? M_PI : 0, 1, 1);
        }
      }
      // Plants by the portals.
      Rng r = RngFor(L->seed, seg, side, 41);
      if (L->decor && Rand(&r) < 0.6) {
        double x = side * (L->halfWidth - 0.38), z = bz + 0.85;
        AddProp(groups[kPropPot], x, 0, z, _originZ, 0, 1, 1);
        AddProp(groups[kPropPlant], x, 0.4, z, _originZ, Rand(&r) * 6.28, Range(&r, 0.8, 1.2), 0.55);
      }
    }
  }
  NSMutableData *all = [NSMutableData data];
  for (int k = 0; k < kPropKinds; k++) {
    _groupBase[k] = all.length / sizeof(PlantInstance);
    _groupCount[k] = groups[k].length / sizeof(PlantInstance);
    [all appendData:groups[k]];
  }
  _instances = SceneBuffer(_device, all);
  _instanceTotal = all.length / sizeof(PlantInstance);
}

- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values {
  _uniforms.wall = simd_make_float4(Hex(kWallPaint[MIN(MAX([values index:@"walls"], 0), 4)]), 0);
  _uniforms.floorType = (float)[values index:@"floor"];
  BOOL relayout = values.layoutGeneration != _builtLayout;
  if (relayout) [self readSettings:values];
  int64_t tile = (int64_t)floor(frame->distance / 16.0);
  if (relayout || frame->originZ != _originZ || tile != _builtTile) {
    _originZ = frame->originZ;
    _builtTile = tile;
    _builtLayout = values.layoutGeneration;
    [self rebuildPropsAround:frame->distance];
    int64_t s0 = (int64_t)floor((frame->distance - 260) / kSegmentLength), s1 = (int64_t)floor((frame->distance + 30) / kSegmentLength);
    for (NSNumber *key in _segments.allKeys) {
      if (key.longLongValue < s0 || key.longLongValue > s1) [_segments removeObjectForKey:key];
    }
    for (int64_t s = s0; s <= s1; s++) {
      if (_segments[@(s)]) continue;
      NSData *mesh = SegmentMesh(&_layout, s);
      CorridorSegment *segment = [CorridorSegment new];
      segment.buffer = SceneBuffer(_device, mesh);
      segment.vertices = mesh.length / sizeof(MeshVertex);
      _segments[@(s)] = segment;
    }
  }
}

#pragma mark Drawing

- (void)drawHall:(id<MTLRenderCommandEncoder>)re {
  [re setVertexBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  NSArray<NSNumber *> *keys = [_segments.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSNumber *key in keys.reverseObjectEnumerator) {  // nearest first
    CorridorSegment *segment = _segments[key];
    simd_float3 offset = {0, 0, (float)(key.longLongValue * (double)kSegmentLength - _originZ)};
    [re setVertexBytes:&offset length:sizeof offset atIndex:kBufferInstances];
    [re setVertexBuffer:segment.buffer offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:segment.vertices];
  }
}

- (void)drawProps:(id<MTLRenderCommandEncoder>)re {
  if (!_instanceTotal) return;
  [re setVertexBytes:&_plantUniforms length:sizeof _plantUniforms atIndex:kBufferScene];
  [re setFragmentBytes:&_plantUniforms length:sizeof _plantUniforms atIndex:kBufferScene];
  [re setFragmentTexture:_atlas atIndex:kTextureScene];
  [re setVertexBuffer:_instances offset:0 atIndex:kBufferInstances];
  for (int k = 0; k < kPropKinds; k++) {
    if (!_groupCount[k]) continue;
    [re setVertexBuffer:_meshes[k] offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_meshVertices[k] instanceCount:_groupCount[k] baseInstance:_groupBase[k]];
  }
}

- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setRenderPipelineState:_hallShadowPipe];
  [self drawHall:re];
  [re setRenderPipelineState:_plantShadowPipe];
  [self drawProps:re];
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setDepthStencilState:_depthOn];
  [re setCullMode:MTLCullModeNone];
  [re setRenderPipelineState:_plantPipe];
  [self drawProps:re];
  [re setRenderPipelineState:_hallPipe];
  [self drawHall:re];
}

@end
