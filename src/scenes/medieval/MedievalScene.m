#import "MedievalScene.h"

#import "MedievalTown.h"
#import "OutdoorEnvironment.h"
#import "Plants.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"

static const double kViewBehind = 330;  // metres of street drawn behind the walker (in view)
static const double kViewAhead = 16;     // … and ahead (shadows, motion)

@interface TownSegment : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NSUInteger opaque, cards;
@end

@implementation TownSegment
@end

@implementation MedievalScene {
  id<MTLDevice> _device;
  id<MTLRenderPipelineState> _townPipe, _cardPipe, _shadowPipe;
  id<MTLDepthStencilState> _depthOn;
  id<MTLTexture> _atlas;
  NSMutableDictionary<NSNumber *, TownSegment *> *_segments;
  id<MTLBuffer> _lights;

  double _originZ;
  int64_t _builtTile;
  uint64_t _builtLayout;
  TownLayout _layout;
  TownUniforms _uniforms;
}

+ (void)load {
  [SceneRegistry registerScene:self];
}

+ (NSString *)identifier {
  return @"medieval";
}

+ (NSString *)title {
  return @"Medieval street";
}

+ (Class)environment {
  return OutdoorEnvironment.class;
}

+ (NSArray<SceneParameter *> *)parameters {
  NSString *street = @"Street";
  return @[
    [OutdoorEnvironment lightingParameter:@[ @"Foggy", @"Bright overcast", @"Cloudy", @"After rain", @"Sunny", @"Morning sun", @"Golden hour", @"Dusk",
                                            @"Night", @"Rainy night" ]
                                  default:@"Foggy"],
    [SceneParameter sliderWithKey:@"mist" title:@"Mist" section:@"Lighting" minimum:0 maximum:1 step:0.05 value:0.6 format:@"%.2f"],
    [[SceneParameter sliderWithKey:@"width" title:@"Street width" section:street minimum:4.5 maximum:8 step:0.1 value:5.6 format:@"%.1f m"] relayout],
    [[SceneParameter sliderWithKey:@"storeys" title:@"Storeys" section:street minimum:3 maximum:7 step:1 value:5 format:@"%.0f"] relayout],
    [[SceneParameter sliderWithKey:@"bends" title:@"Bends" section:street minimum:0 maximum:1.5 step:0.05 value:1 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"market" title:@"Market stalls" section:street minimum:0 maximum:1 step:0.05 value:0.7 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"bridges" title:@"Arches and bridges" section:street minimum:0 maximum:1 step:0.05 value:0.9 format:@"%.2f"]
        relayout],
    [[SceneParameter sliderWithKey:@"laundry" title:@"Washing lines" section:street minimum:0 maximum:1 step:0.05 value:0.75 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"ivy" title:@"Ivy" section:street minimum:0 maximum:1 step:0.05 value:0.8 format:@"%.2f"] relayout],
    [SceneParameter sliderWithKey:@"weathering" title:@"Weathering" section:street minimum:0 maximum:1 step:0.05 value:0.8 format:@"%.2f"],
    [SceneParameter toggleWithKey:@"lanterns" title:@"Lanterns lit by day" section:street value:YES],
    [SceneParameter seedWithKey:@"seed" title:@"New Street" section:street value:11],
  ];
}

+ (NSArray<NSString *> *)shaderSources {
  // The kit's foliage atlas (ivy).
  return @[ @"Plants.h", @"Plants.metal", @"MedievalScene.h", @"Medieval.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _segments = [NSMutableDictionary dictionary];
  _builtTile = INT64_MIN;
  _builtLayout = UINT64_MAX;
  _originZ = NAN;

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, YES);
  pd.vertexFunction = [lib newFunctionWithName:@"town_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"town_fs"];
  _townPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  pd.alphaToCoverageEnabled = YES;
  _cardPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
  sd.depthAttachmentPixelFormat = kShadowFormat;
  sd.vertexFunction = [lib newFunctionWithName:@"town_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"town_shadow_fs"];
  _shadowPipe = [device newRenderPipelineStateWithDescriptor:sd error:error];
  _atlas = FoliageAtlas(device, lib, error);
  if (!_townPipe || !_cardPipe || !_shadowPipe || !_atlas) return nil;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthOn = [device newDepthStencilStateWithDescriptor:dd];
  _lights = [device newBufferWithLength:sizeof(simd_float4) * kLightBuckets * kLightsPerBucket options:MTLResourceStorageModeShared];
  return self;
}

- (NSUInteger)instanceCount {
  return 0;
}

- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values {
  float bends = (float)[values number:@"bends"];
  double z = metres;
  return (WalkPoint){simd_make_double3(MedievalPathX((float)fmod(z, 512.0), bends), 0, z),
                     simd_make_double3(MedievalPathSlope((float)fmod(z, 512.0), bends), 0, 1)};
}

- (void)adjustLighting:(FrameUniforms *)u values:(SceneValues *)values {
  // Mist hangs in the lanes: denser than the weather alone, thinning a little with height, a
  // neutral, slightly warm white.
  float mist = (float)[values number:@"mist"];
  if (simd_reduce_max(u->sunColor) > 1) mist *= 0.35f;  // sunshine burns most of it off
  u->fogDensity = fmaxf(u->fogDensity * 0.75f, mist * 0.03f);
  u->fogFalloff = fminf(u->fogFalloff, 0.02f);
  float grey = simd_dot(u->fogColor, simd_make_float3(0.2126f, 0.7152f, 0.0722f));
  u->fogColor = simd_mix(u->fogColor, grey * simd_make_float3(1.02f, 1.0f, 0.95f), simd_make_float3(0.6f, 0.6f, 0.6f) * fminf(mist * 1.5f, 1));
  // An overcast sky is bright over the lane, and the stone keeps its colour.
  if (u->cloudCover >= 0.9f && u->night <= 0) {
    u->skyZenith *= 1.22f;
    u->skyHorizon *= 1.22f;
    u->cloudColor *= 1.22f;
    u->fogColor *= 1.12f;
  }
  u->exposure *= 1.3f;  // the deep lane gets a fraction of the sky's light; exposed for the stone
  float sky = simd_dot(u->skyAmbient, simd_make_float3(0.2126f, 0.7152f, 0.0722f));
  if (u->night <= 0 && sky > 0) u->exposure *= fminf(fmaxf(1.0f / sky, 1), 1.8f);  // under a clear sky, as much as under cloud
  u->saturation = fmaxf(u->saturation, 1.0f);
  u->contrast = fmaxf(u->contrast, 1.06f);
  u->aoStrength = 1;
  u->aoRadius = 0.5f;
  u->shadowSoftness = 0.012f;
  BOOL dayLit = [values flag:@"lanterns"];
  _uniforms.flame = fmaxf(u->night, dayLit ? 0.45f : 0);
  _uniforms.lightPower = fmaxf(u->night, dayLit ? 0.12f : 0);
  _uniforms.damp = fmaxf(u->wetness, 0.08f);
}

#pragma mark Layout

- (void)readSettings:(SceneValues *)values {
  TownLayout *L = &_layout;
  L->halfWidth = (float)[values number:@"width"] / 2;
  L->storeys = (int)lround([values number:@"storeys"]);
  L->market = (float)[values number:@"market"];
  L->bridges = (float)[values number:@"bridges"];
  L->laundry = (float)[values number:@"laundry"];
  L->ivy = (float)[values number:@"ivy"];
  L->seed = (uint32_t)[values number:@"seed"];
  [_segments removeAllObjects];
}

/// The light table around the walker: lanterns by absolute z, kLightsPerBucket per bucket.
- (void)rebuildLightsAround:(double)distance {
  const TownLayout *L = &_layout;
  int64_t base = (int64_t)floor((distance - kViewBehind - 12) / kLightBucket);
  _uniforms.lightBase = (float)base;
  simd_float4 *table = _lights.contents;
  memset(table, 0, _lights.length);
  int64_t s0 = (int64_t)floor(base * kLightBucket / kTownSegment), s1 = (int64_t)floor((base + kLightBuckets) * kLightBucket / kTownSegment);
  for (int64_t s = s0; s <= s1; s++) {
    TownLight lights[64];
    int n = TownSegmentLights(L, s, lights, 64);
    for (int i = 0; i < n; i++) {
      double z = s * (double)kTownSegment + lights[i].p.z;
      int64_t b = (int64_t)floor(z / kLightBucket) - base;
      if (b < 0 || b >= kLightBuckets) continue;
      simd_float4 *slot = &table[b * kLightsPerBucket];
      int k = 0;
      while (k < kLightsPerBucket && slot[k].w > 0) k++;
      if (k == kLightsPerBucket) continue;
      float x = lights[i].p.x + MedievalPathX((float)fmod(z, 512.0), _uniforms.bends);
      slot[k] = simd_make_float4(x, lights[i].p.y, (float)(z - _originZ), lights[i].power);
    }
  }
}

- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values {
  _uniforms.stoneA = Hex(0x98927c);
  _uniforms.stoneB = Hex(0x7c806c);
  _uniforms.moss = Hex(0x5a6226);
  _uniforms.weathering = (float)[values number:@"weathering"];
  _uniforms.time = frame->uniforms.time;
  BOOL relayout = values.layoutGeneration != _builtLayout;
  if (relayout) {
    [self readSettings:values];
    _uniforms.halfWidth = _layout.halfWidth;
    _uniforms.roofHeight = TownRoofHeight(&_layout);
    _uniforms.bends = (float)[values number:@"bends"];
  }
  int64_t tile = (int64_t)floor(frame->distance / 12.0);
  if (relayout || frame->originZ != _originZ || tile != _builtTile) {
    _originZ = frame->originZ;
    _builtTile = tile;
    _builtLayout = values.layoutGeneration;
    [self rebuildLightsAround:frame->distance];
    int64_t s0 = (int64_t)floor((frame->distance - kViewBehind) / kTownSegment), s1 = (int64_t)floor((frame->distance + kViewAhead) / kTownSegment);
    for (NSNumber *key in _segments.allKeys) {
      if (key.longLongValue < s0 || key.longLongValue > s1) [_segments removeObjectForKey:key];
    }
    for (int64_t s = s0; s <= s1; s++) {
      if (_segments[@(s)]) continue;
      NSUInteger opaque = 0;
      NSData *mesh = TownSegmentMesh(&_layout, s, &opaque);
      TownSegment *segment = [TownSegment new];
      segment.buffer = SceneBuffer(_device, mesh);
      segment.opaque = opaque;
      segment.cards = mesh.length / sizeof(MeshVertex) - opaque;
      _segments[@(s)] = segment;
    }
  }
}

#pragma mark Drawing

- (void)bindTown:(id<MTLRenderCommandEncoder>)re {
  [re setVertexBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  [re setFragmentBuffer:_lights offset:0 atIndex:kBufferTownLights];
  [re setFragmentTexture:_atlas atIndex:kTextureScene];
}

/// Segments nearest first; `cards`: the foliage ranges, else the opaque ones.
- (void)drawSegments:(id<MTLRenderCommandEncoder>)re cards:(BOOL)cards {
  NSArray<NSNumber *> *keys = [_segments.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSNumber *key in keys.reverseObjectEnumerator) {
    TownSegment *segment = _segments[key];
    NSUInteger count = cards ? segment.cards : segment.opaque;
    if (!count) continue;
    simd_float3 offset = {0, 0, (float)(key.longLongValue * (double)kTownSegment - _originZ)};
    [re setVertexBytes:&offset length:sizeof offset atIndex:kBufferInstances];
    [re setVertexBuffer:segment.buffer offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:cards ? segment.opaque : 0 vertexCount:count];
  }
}

- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setRenderPipelineState:_shadowPipe];
  [self bindTown:re];
  [self drawSegments:re cards:NO];
  [self drawSegments:re cards:YES];
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setDepthStencilState:_depthOn];
  [re setCullMode:MTLCullModeNone];
  [self bindTown:re];
  [re setRenderPipelineState:_townPipe];
  [self drawSegments:re cards:NO];
  [re setRenderPipelineState:_cardPipe];
  [self drawSegments:re cards:YES];
}

@end
