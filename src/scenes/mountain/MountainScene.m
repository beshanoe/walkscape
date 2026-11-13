#import "MountainScene.h"

#import "AlpineEnvironment.h"
#import "CoastSky.h"
#import "MountainProps.h"
#import "Plants.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"

#pragma mark - The trail (the walker's copy, in double: MountainScene.h has the shaders')

static double PathX(double z) {
  return kMtnPathA1 * sin(z / kMtnPathL1) + kMtnPathA2 * sin(z / kMtnPathL2 + 1.3) + kMtnPathA3 * sin(z / kMtnPathL3 + 0.7);
}

static double PathSlope(double z) {
  return kMtnPathA1 / kMtnPathL1 * cos(z / kMtnPathL1) + kMtnPathA2 / kMtnPathL2 * cos(z / kMtnPathL2 + 1.3) +
         kMtnPathA3 / kMtnPathL3 * cos(z / kMtnPathL3 + 0.7);
}

static double TrailY(double z) {
  return kMtnRiseA1 * sin(z / kMtnRiseL1) + kMtnRiseA2 * sin(z / kMtnRiseL2 + 2.1);
}

#pragma mark - Levels

enum { kVertices = kMtnGrid + 1, kBlocks = kMtnGrid / kMtnBlock, kReadLevels = 4 };

/// A level's place: the absolute x, z of its vertex (0, 0).
typedef struct {
  double x, z;
  BOOL valid;
} LevelPlace;

static double LevelCell(int level) {
  return kMtnCell0 * (double)(1 << level);
}

/// How far off centre a level sits: toward the valley and behind the walker, where the camera
/// looks (the fine levels less to the side: the slope above the trail is in the picture too).
/// The fractions keep every level inside the next one whatever the snapping does.
static double LevelSideShift(int level) {
  return 0.29 - 0.19 * pow(0.5, level);
}

static const double kLevelBackShift = 0.3;

#pragma mark - Instances

/// What stands on the ground, one mesh each (drawn in this order: front to back matters little
/// for things this small). MountainProps.h builds the scene's own meshes.
typedef enum {
  kGroupGrass,      // kit grass tufts, 3 variants
  kGroupGrassEnd = kGroupGrass + kPlantVariants - 1,
  kGroupFlower,     // flower clumps: yellow, white, violet, pink
  kGroupFlowerEnd = kGroupFlower + kMountainFlowers - 1,
  kGroupStone,      // limestone lumps, 3 shapes
  kGroupStoneEnd = kGroupStone + kMountainStones - 1,
  kGroupPine,       // dwarf pine, 2 shapes
  kGroupPineEnd = kGroupPine + 1,
  kGroupSpruce,     // spruces far below (the kit's lighter mesh), 3 variants
  kGroupSpruceEnd = kGroupSpruce + kPlantVariants - 1,
  kGroupCairn,
  kGroupSign,
  kGroupCross,
  kGroups,
} Group;

@implementation MountainScene {
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _terrainPipe, _propPipe, _propShadowPipe;
  id<MTLComputePipelineState> _heightBake, _surfaceBake, _shadowBake;
  id<MTLDepthStencilState> _depthOn;
  id<MTLTexture> _heights, _surface, _mask, _sunShadow, _atlas, _clouds;
  id<MTLBuffer> _blockIndices;
  NSUInteger _blockIndexCount;

  LevelPlace _levels[kMtnLevels];
  float *_read[kReadLevels];      // the fine levels' heights, for standing things on the ground
  LevelPlace _readPlace[kReadLevels];
  simd_float3 _bakedSun;
  BOOL _shadowsBaked;

  id<MTLBuffer> _meshes[kGroups];
  NSUInteger _meshVertices[kGroups];
  id<MTLBuffer> _instances;
  NSUInteger _groupBase[kGroups], _groupCount[kGroups], _instanceTotal;
  int64_t _builtTile;
  BOOL _placed;

  double _originZ;
  uint64_t _builtLayout;
  MountainUniforms _uniforms;
  PlantUniforms _plantUniforms, _propUniforms;

  // Settings (read when the layout generation changes; the weather's each frame).
  MountainShape _shape;
  double _grass, _flowers, _stones;
  BOOL _relief;
}

+ (void)load {
  [SceneRegistry registerScene:self];
}

+ (NSString *)identifier {
  return @"mountain";
}

+ (NSString *)title {
  return @"Mountain trail";
}

+ (NSArray<SceneParameter *> *)parameters {
  NSString *mountain = @"Mountains", *trail = @"Trail";
  return @[
    [AlpineEnvironment lightingParameter:AlpineEnvironment.presetNames default:@"Clear day"],
    [[SceneParameter choiceWithKey:@"valley" title:@"Valley on the" section:mountain choices:@[ @"Left", @"Right" ] value:0] relayout],
    [[SceneParameter sliderWithKey:@"peaks" title:@"Peaks" section:mountain minimum:0.6 maximum:1.4 step:0.05 value:1 format:@"%.2f×"] relayout],
    [SceneParameter sliderWithKey:@"snow" title:@"Snow" section:mountain minimum:0 maximum:1 step:0.05 value:0.3 format:@"%.2f"],
    [SceneParameter seedWithKey:@"seed" title:@"New Mountains" section:mountain value:3],
    [[SceneParameter sliderWithKey:@"width" title:@"Trail width" section:trail minimum:0.7 maximum:1.8 step:0.05 value:1 format:@"%.2f×"]
        relayout],
    [[SceneParameter sliderWithKey:@"stones" title:@"Stones" section:trail minimum:0 maximum:1 step:0.05 value:0.6 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"grass" title:@"Grass" section:trail minimum:0 maximum:1 step:0.05 value:0.7 format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"flowers" title:@"Flowers" section:trail minimum:0 maximum:1 step:0.05 value:0.6 format:@"%.2f"] relayout],
    [SceneParameter sliderWithKey:@"wind" title:@"Wind" section:trail minimum:0 maximum:1 step:0.05 value:0.4 format:@"%.2f"],
  ];
}

+ (Class)environment {
  return AlpineEnvironment.class;
}

+ (NSArray<NSString *> *)shaderSources {
  return @[ @"Plants.h", @"Plants.metal", @"CoastSky.h", @"CoastSky.metal", @"MountainScene.h", @"MountainTerrain.metal", @"Mountain.metal" ];
}

+ (simd_float2)depthRange {
  return simd_make_float2(0.3f, kMtnFar);
}

- (id<MTLTexture>)levelArray:(MTLPixelFormat)format shared:(BOOL)shared {
  MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:kVertices height:kVertices mipmapped:NO];
  td.textureType = MTLTextureType2DArray;
  td.arrayLength = kMtnLevels;
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  td.storageMode = shared ? MTLStorageModeShared : MTLStorageModePrivate;
  return [_device newTextureWithDescriptor:td];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _queue = [device newCommandQueue];
  _builtLayout = UINT64_MAX;
  _builtTile = INT64_MIN;
  _originZ = NAN;
  _relief = getenv("WALKSCAPE_MOUNTAIN_RELIEF") != NULL;  // plain grey terrain, to judge its shape

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, NO);
  pd.vertexFunction = [lib newFunctionWithName:@"mtn_terrain_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"mtn_terrain_fs"];
  _terrainPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  pd.alphaToCoverageEnabled = YES;  // leaf cards
  pd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"mtn_prop_fs"];
  _propPipe = _terrainPipe ? [device newRenderPipelineStateWithDescriptor:pd error:error] : nil;
  MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
  sd.depthAttachmentPixelFormat = kShadowFormat;
  sd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"plant_shadow_fs"];
  _propShadowPipe = _propPipe ? [device newRenderPipelineStateWithDescriptor:sd error:error] : nil;
  if (!_propShadowPipe) return nil;
  NSArray<NSString *> *kernels = @[ @"mtn_bake_height", @"mtn_bake_surface", @"mtn_bake_shadow" ];
  NSMutableArray<id<MTLComputePipelineState>> *bakes = [NSMutableArray array];
  for (NSString *name in kernels) {
    id<MTLFunction> fn = [lib newFunctionWithName:name];
    id<MTLComputePipelineState> pipe = fn ? [device newComputePipelineStateWithFunction:fn error:error] : nil;
    if (!pipe) {
      if (!fn && error) *error = SceneError(@"No %@ in the library", name);
      return nil;
    }
    [bakes addObject:pipe];
  }
  _heightBake = bakes[0];
  _surfaceBake = bakes[1];
  _shadowBake = bakes[2];
  _atlas = FoliageAtlas(device, lib, error);
  _clouds = _atlas ? CoastCloudNoise(device, lib, error) : nil;
  if (!_clouds) return nil;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthOn = [device newDepthStencilStateWithDescriptor:dd];

  _heights = [self levelArray:MTLPixelFormatR32Float shared:YES];
  _surface = [self levelArray:MTLPixelFormatRGBA8Unorm shared:NO];
  _mask = [self levelArray:MTLPixelFormatRGBA8Unorm shared:NO];
  _sunShadow = [self levelArray:MTLPixelFormatR8Unorm shared:NO];
  if (!_heights || !_surface || !_mask || !_sunShadow) {
    if (error) *error = SceneError(@"No memory for the terrain");
    return nil;
  }
  for (int i = 0; i < kReadLevels; i++) _read[i] = calloc((size_t)kVertices * kVertices, sizeof(float));

  // One block of cells, drawn for every visible block of every level.
  NSMutableData *idx = [NSMutableData dataWithLength:sizeof(uint16_t) * kMtnBlock * kMtnBlock * 6];
  uint16_t *pi = idx.mutableBytes;
  for (int j = 0; j < kMtnBlock; j++) {
    for (int i = 0; i < kMtnBlock; i++) {
      uint16_t a = (uint16_t)(j * (kMtnBlock + 1) + i), b = a + 1, c = a + (kMtnBlock + 1), d = c + 1;
      uint16_t q[6] = {a, c, b, b, c, d};
      memcpy(pi, q, sizeof q);
      pi += 6;
    }
  }
  _blockIndices = SceneBuffer(device, idx);
  _blockIndexCount = (NSUInteger)kMtnBlock * kMtnBlock * 6;

  NSArray<NSData *> *meshes = [self buildMeshes];
  for (int g = 0; g < kGroups; g++) {
    _meshes[g] = SceneBuffer(device, meshes[g]);
    _meshVertices[g] = meshes[g].length / sizeof(MeshVertex);
  }
  return self;
}

- (void)dealloc {
  for (int i = 0; i < kReadLevels; i++) free(_read[i]);
}

- (NSArray<NSData *> *)buildMeshes {
  NSMutableArray<NSData *> *m = [NSMutableArray array];
  for (int g = 0; g < kGroups; g++) [m addObject:[NSData data]];
  for (int v = 0; v < kPlantVariants; v++) {
    m[kGroupGrass + v] = PlantMesh(PlantGrass, v, NO, NO);
    m[kGroupSpruce + v] = PlantMesh(PlantSpruce, v, YES, NO);
  }
  for (int k = 0; k < kMountainFlowers; k++) m[kGroupFlower + k] = MountainFlowerMesh(k);
  for (int k = 0; k < kMountainStones; k++) m[kGroupStone + k] = MountainStoneMesh(k);
  for (int k = 0; k < 2; k++) m[kGroupPine + k] = MountainDwarfPineMesh(k);
  m[kGroupCairn] = MountainCairnMesh();
  m[kGroupSign] = MountainSignMesh();
  m[kGroupCross] = MountainCrossMesh();
  return m;
}

- (NSUInteger)instanceCount {
  return _instanceTotal;
}

- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values {
  return (WalkPoint){simd_make_double3(PathX(metres), TrailY(metres), metres), simd_make_double3(PathSlope(metres), 0, 1)};
}

#pragma mark Settings

- (void)readSettings:(SceneValues *)values {
  _shape.side = [values index:@"valley"] == 1 ? 1 : -1;
  _shape.peaks = (float)[values number:@"peaks"];
  _shape.seed = (float)((uint32_t)[values number:@"seed"] % 4096);
  _shape.trailHalf = (float)(0.3 * [values number:@"width"]);
  _grass = [values number:@"grass"];
  _flowers = [values number:@"flowers"];
  _stones = [values number:@"stones"];
  for (int l = 0; l < kMtnLevels; l++) _levels[l].valid = NO;
  for (int l = 0; l < kReadLevels; l++) _readPlace[l].valid = NO;
  _placed = NO;
}

- (void)adjustLighting:(FrameUniforms *)u values:(SceneValues *)values {
  if ([values index:@"valley"] == 1) {  // the valley on the right: the sun and the wind mirrored
    u->sunDir.x = -u->sunDir.x;
    u->windDir.x = -u->windDir.x;
  }
  u->focusDistance = 1.2f;
}

#pragma mark Baking

/// Moves the levels after the walker and bakes those that moved (and the sun's shadow on all of
/// them when the sun has moved). Returns whether the fine levels changed.
- (BOOL)updateLevelsAround:(simd_double3)eye sun:(simd_float3)sun {
  BOOL dirty[kMtnLevels] = {NO}, any = NO, fine = NO;
  for (int l = 0; l < kMtnLevels; l++) {
    double cell = LevelCell(l), extent = cell * kMtnGrid, snap = cell * kMtnSnap;
    double wantX = eye.x + _shape.side * LevelSideShift(l) * extent - extent / 2;
    double wantZ = eye.z - kLevelBackShift * extent - extent / 2;
    LevelPlace *p = &_levels[l];
    // A level stays until the walker is three quarters of a step off: no flapping at a boundary.
    if (p->valid && fabs(wantX - p->x) < 0.75 * snap && fabs(wantZ - p->z) < 0.75 * snap) continue;
    p->x = round(wantX / snap) * snap;
    p->z = round(wantZ / snap) * snap;
    p->valid = YES;
    dirty[l] = any = YES;
    if (l < kReadLevels) fine = YES;
  }
  for (int l = 0; l < kMtnLevels; l++) {
    _uniforms.levels[l] = simd_make_float4((float)_levels[l].x, (float)(_levels[l].z - _originZ), (float)LevelCell(l), 0);
  }
  BOOL sunMoved = !_shadowsBaked || simd_distance(sun, _bakedSun) > 1e-4f;
  if (!any && !sunMoved) return NO;
  _bakedSun = sun;
  _shadowsBaked = YES;
  _uniforms.bakedSun = sun;

  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
  MTLSize threads = MTLSizeMake(kVertices, kVertices, 1), group = MTLSizeMake(16, 16, 1);
  for (int pass = 0; pass < 2; pass++) {  // every height first: the shadows read coarser levels
    [ce setComputePipelineState:pass == 0 ? _heightBake : _surfaceBake];
    [ce setTexture:_heights atIndex:0];
    [ce setTexture:pass == 0 ? _mask : _surface atIndex:1];
    for (int l = 0; l < kMtnLevels; l++) {
      if (!dirty[l]) continue;
      MountainBake b = {.shape = _shape, .origin = simd_make_float2((float)_levels[l].x, (float)_levels[l].z), .cell = (float)LevelCell(l), .level = l};
      [ce setBytes:&b length:sizeof b atIndex:0];
      [ce dispatchThreads:threads threadsPerThreadgroup:group];
    }
  }
  [ce setComputePipelineState:_shadowBake];
  [ce setTexture:_heights atIndex:0];
  [ce setTexture:_sunShadow atIndex:1];
  [ce setBytes:&_uniforms length:sizeof _uniforms atIndex:0];
  for (int l = kMtnShadowLevel; l < kMtnLevels; l++) {
    if (!dirty[l] && !sunMoved) continue;
    int level = l;
    [ce setBytes:&level length:sizeof level atIndex:1];
    [ce dispatchThreads:threads threadsPerThreadgroup:group];
  }
  [ce endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  for (int l = 0; l < kReadLevels; l++) {
    if (!dirty[l]) continue;
    [_heights getBytes:_read[l] bytesPerRow:kVertices * sizeof(float) bytesPerImage:(NSUInteger)kVertices * kVertices * sizeof(float)
            fromRegion:MTLRegionMake2D(0, 0, kVertices, kVertices) mipmapLevel:0 slice:(NSUInteger)l];
    _readPlace[l] = _levels[l];
  }
  return fine;
}

/// The ground's height at absolute (x, z) from the finest baked level that has it; NO outside them.
- (BOOL)height:(double *)height atX:(double)x z:(double)z {
  for (int l = 0; l < kReadLevels; l++) {
    if (!_readPlace[l].valid) continue;
    double cell = LevelCell(l);
    double gx = (x - _readPlace[l].x) / cell, gz = (z - _readPlace[l].z) / cell;
    if (gx < 0 || gz < 0 || gx > kMtnGrid - 1e-6 || gz > kMtnGrid - 1e-6) continue;
    int i = (int)gx, j = (int)gz;
    double fx = gx - i, fz = gz - j;
    const float *h = _read[l] + (size_t)j * kVertices + i;
    *height = (h[0] * (1 - fx) + h[1] * fx) * (1 - fz) + (h[kVertices] * (1 - fx) + h[kVertices + 1] * fx) * fz;
    return YES;
  }
  return NO;
}

#pragma mark Placement

static void Put(NSMutableData *__unsafe_unretained *groups, int group, double x, double y, double z, double originZ, double yaw, double width, double height,
                double bright, simd_float4 tint) {
  PlantInstance p;
  p.posYaw = simd_make_float4((float)x, (float)y, (float)(z - originZ), (float)yaw);
  p.shape = simd_make_float4((float)width, (float)height, (float)bright, (float)(yaw * 3.1));
  p.tint = tint;
  [groups[group] appendBytes:&p length:sizeof p];
}

/// How steep the ground is at (x, z): the rise over a metre, or 0 where it isn't known.
- (double)steepnessAtX:(double)x z:(double)z {
  double a, b, c;
  if (![self height:&a atX:x z:z] || ![self height:&b atX:x + 1 z:z] || ![self height:&c atX:x z:z + 1]) return 0;
  return hypot(b - a, c - a);
}

// Everything is placed in 4 m tiles (deterministic per tile and seed): grass, flowers and loose
// stones near the trail behind the walker; boulders, dwarf pine further out; spruces far below;
// a cairn, a signpost or a summit cross now and then.
- (void)placeAroundZ:(double)camZ {
  NSMutableArray<NSMutableData *> *keep = [NSMutableArray array];
  NSMutableData *__unsafe_unretained groups[kGroups];
  for (int g = 0; g < kGroups; g++) {
    NSMutableData *d = [NSMutableData data];
    [keep addObject:d];
    groups[g] = d;
  }
  uint32_t seed = (uint32_t)_shape.seed;
  double side = _shape.side, hw = _shape.trailHalf, oz = _originZ;
  const double tile = 4.0;
  int64_t tz0 = (int64_t)floor((camZ - 150) / tile), tz1 = (int64_t)floor((camZ + 6) / tile);
  for (int64_t tz = tz0; tz <= tz1; tz++) {
    double zc = (tz + 0.5) * tile, behind = camZ - zc;
    double px = PathX(zc);
    // The verge: tufts, flowers and stones within a few metres of the tread.
    if (behind < 46) {
      Rng r = RngFor(seed, tz, 0, 11);
      double fadeNear = fmin(fmax((46 - behind) / 16, 0), 1);
      int tufts = (int)lround(900 * _grass * fadeNear * fmin(fmax((26 - behind) / 14, 0.25), 1)), blooms = (int)lround(26 * _flowers * fadeNear), stones = (int)lround(22 * _stones * fadeNear);
      for (int i = 0; i < tufts + blooms + stones; i++) {
        double z = (tz + Rand(&r)) * tile;
        double reach = i < tufts + blooms ? 7.0 : 1.6;
        double off = (Rand(&r) < 0.5 ? -1 : 1) * (hw + 0.08 + reach * pow(Rand(&r), 1.7));
        double x = PathX(z) + off * sqrt(1 + PathSlope(z) * PathSlope(z)), y;
        double pick = Rand(&r), size = Rand(&r), yaw = Rand(&r) * 2 * M_PI;
        if (![self height:&y atX:x z:z]) continue;
        if (i < tufts) {
          float g = (float)(0.8 + 0.4 * pick);
          simd_float3 c = simd_mix(Hex(0x6e6a30), Hex(0x4a5c24), (simd_float3){(float)pick, (float)pick, (float)pick}) * g * 0.75f;
          Put(groups, kGroupGrass + (int)(pick * kPlantVariants) % kPlantVariants, x, y - 0.02, z, oz, yaw, 1.2 + 0.9 * size, 0.07 + 0.2 * size * size, 1,
              simd_make_float4(c, 0));
        } else if (i < tufts + blooms) {
          // Mostly yellow, some white, violet and pink; drifts of one kind per tile.
          double kindPick = fmod(pick + 0.6 * SceneHashF((uint32_t)tz, seed), 1.0);
          int kind = kindPick < 0.5 ? 0 : kindPick < 0.7 ? 1 : kindPick < 0.87 ? 2 : 3;
          Put(groups, kGroupFlower + kind, x, y - 0.01, z, oz, yaw, 1, 0.12 + 0.14 * size, 1, simd_make_float4(1, 1, 1, 0));
        } else {
          double h = 0.04 + 0.16 * size * size;
          Put(groups, kGroupStone + (int)(pick * kMountainStones) % kMountainStones, x, y - h * 0.3, z, oz, yaw, 1.0 + 0.8 * Rand(&r), h, 1.4 + 0.3 * pick,
              simd_make_float4(1, 1, 1, 0));
        }
      }
      // Loose stones on the tread itself, off its middle.
      int loose = (int)lround(9 * _stones * fadeNear);
      for (int i = 0; i < loose; i++) {
        double z = (tz + Rand(&r)) * tile, across = (Rand(&r) * 2 - 1);
        across = copysign(0.35 + 0.65 * fabs(across), across) * hw;
        double x = PathX(z) + across, y, size = Rand(&r), pick = Rand(&r);
        if (![self height:&y atX:x z:z]) continue;
        double h = 0.025 + 0.07 * size * size;
        Put(groups, kGroupStone + (int)(pick * kMountainStones) % kMountainStones, x, y - h * 0.35, z, oz, pick * 6.28, 1.1 + 0.7 * Rand(&r), h, 1.45 + 0.3 * pick,
            simd_make_float4(1, 1, 1, 0));
      }
    }
    // The slope: boulders, dwarf pine in patches below the trail, in 4 m × 16 m cells.
    for (int cx = -9; cx <= 9; cx++) {
      Rng r = RngFor(seed, tz, cx, 12);
      double x = px + (cx + Rand(&r)) * 16.0, z = (tz + Rand(&r)) * tile, y;
      double off = (x - px) * side;  // metres toward the valley
      double pick = Rand(&r), size = Rand(&r), yaw = Rand(&r) * 2 * M_PI;
      if (fabs(x - PathX(z)) < hw + 1.6 || ![self height:&y atX:x z:z]) continue;
      double patch = SceneHashF((uint32_t)(tz / 6), (uint32_t)(cx / 2 + 64) ^ seed);
      if (pick < 0.08) {  // a boulder, sunk into the turf
        double h = 0.25 + 1.3 * size * size * size;
        Put(groups, kGroupStone + (int)(Rand(&r) * kMountainStones) % kMountainStones, x, y - h * 0.3, z, oz, yaw, 1.0 + 0.9 * Rand(&r), h, 1.25 + 0.3 * Rand(&r),
            simd_make_float4(1, 1, 1, 0));
      } else if (pick < 0.08 + 0.5 * (patch > 0.6) && off > 14 && [self steepnessAtX:x z:z] < 0.95) {
        double h = 0.8 + 1.3 * size;
        Put(groups, kGroupPine + (int)(Rand(&r) * 2) % 2, x, y - 0.1, z, oz, yaw, 1.0 + 0.5 * Rand(&r), h, 0.85 + 0.3 * Rand(&r), simd_make_float4(Hex(0x35562c), 0));
      }
    }
  }
  // Spruces and larches below the tree line, as far down and back as the fine levels reach.
  for (int64_t tz = (int64_t)floor((camZ - 760) / 24.0); tz <= (int64_t)floor((camZ + 40) / 24.0); tz++) {
    double px = PathX((tz + 0.5) * 24.0);
    for (int cx = 7; cx < 26; cx++) {
      Rng r = RngFor(seed, tz, cx, 14);
      for (int i = 0; i < 3; i++) {
        double off = (cx + Rand(&r)) * 24.0, z = (tz + Rand(&r)) * 24.0, y;
        double x = px + side * off, pick = Rand(&r), size = Rand(&r), keep = Rand(&r);
        if (![self height:&y atX:x z:z]) continue;
        // Thin at the tree line, a closed wood 80 m further down; none on rock faces.
        if (keep > (-232 - y) / 70.0 || [self steepnessAtX:x z:z] > 1.25) continue;
        BOOL larch = pick > 0.78;
        simd_float3 c = (larch ? Hex(0x58783a) : Hex(0x2f4c2e)) * (float)(0.8 + 0.4 * size);
        Put(groups, kGroupSpruce + (int)(pick * 31) % kPlantVariants, x, y - 0.3, z, oz, pick * 6.28, 1.0 + 0.3 * size, 13 + 12 * size, 1, simd_make_float4(c, 0));
      }
    }
  }
  // A cross on the crest above the trail every kilometre or so, where the crest is highest.
  for (int64_t k = (int64_t)floor((camZ - 700) / 1100.0); k <= (int64_t)floor((camZ + 40) / 1100.0); k++) {
    Rng r = RngFor(seed, k, 0, 15);
    double z = (k + 0.3 + 0.4 * Rand(&r)) * 1100.0, best = -INFINITY, bestX = 0, y;
    for (double up = 24; up <= 220; up += 4) {
      double x = PathX(z) - side * up;
      if ([self height:&y atX:x z:z] && y > best + 0.3) {
        best = y;
        bestX = x;
      }
    }
    if (isfinite(best)) Put(groups, kGroupCross, bestX, best - 0.3, z, oz, 0.3, 1, 1, 1, simd_make_float4(1, 1, 1, 0));
  }
  // Waymarks: a cairn every 60–90 m beside the trail, a signpost every 700 m, a cross on the crest.
  for (int64_t k = (int64_t)floor((camZ - 150) / 70.0); k <= (int64_t)floor((camZ + 6) / 70.0); k++) {
    Rng r = RngFor(seed, k, 0, 13);
    double z = (k + 0.2 + 0.6 * Rand(&r)) * 70.0, y;
    BOOL sign = k % 10 == 3;
    double x = PathX(z) + (sign ? -side : (Rand(&r) < 0.5 ? -1 : 1)) * (hw + (sign ? 0.9 : 0.7 + 0.5 * Rand(&r)));
    if (![self height:&y atX:x z:z]) continue;
    if (sign) Put(groups, kGroupSign, x, y - 0.25, z, oz, atan2(PathSlope(z), 1) + (side < 0 ? M_PI : 0) + 0.25, 1, 1, 1, simd_make_float4(1, 1, 1, 0));
    else Put(groups, kGroupCairn, x, y - 0.06, z, oz, Rand(&r) * 6.28, 1, 0.45 + 0.4 * Rand(&r), 1, simd_make_float4(1, 1, 1, 0));
  }

  NSMutableData *all = [NSMutableData data];
  for (int g = 0; g < kGroups; g++) {
    _groupBase[g] = all.length / sizeof(PlantInstance);
    _groupCount[g] = _meshes[g] ? groups[g].length / sizeof(PlantInstance) : 0;
    if (_groupCount[g]) [all appendData:groups[g]];
  }
  _instances = SceneBuffer(_device, all);
  _instanceTotal = all.length / sizeof(PlantInstance);
}

- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values {
  BOOL relayout = values.layoutGeneration != _builtLayout;
  if (relayout) {
    [self readSettings:values];
    _builtLayout = values.layoutGeneration;
  }
  BOOL moved = frame->originZ != _originZ;
  _originZ = frame->originZ;
  float wind = (float)[values number:@"wind"];
  _uniforms.shape = _shape;
  _uniforms.wrapZ = (float)fmod(frame->originZ, 4096.0);
  _uniforms.snow = (float)[values number:@"snow"];
  _uniforms.flowers = (float)_flowers;
  _uniforms.wind = wind;
  _uniforms.mist = [[values choice:@"lighting"] isEqualToString:@"Valley mist"] ? 1 : 0;
  _uniforms.mistTop = -190;
  _uniforms.debug = _relief ? 1 : 0;
  _plantUniforms = (PlantUniforms){.wind = wind, .snow = 0, .moss = 0};
  _propUniforms = (PlantUniforms){.wind = 0, .snow = 0, .moss = 1};

  BOOL fine = [self updateLevelsAround:frame->eye sun:frame->uniforms.sunDir];
  int64_t tile = (int64_t)floor(frame->distance / 4.0);
  if (fine || moved || tile != _builtTile || !_placed) {
    _builtTile = tile;
    _placed = YES;
    [self placeAroundZ:frame->distance];
  }
}

#pragma mark Drawing

/// The blocks of `level` the camera can see, and that the finer level doesn't cover.
- (NSUInteger)visibleBlocks:(MountainBlock *)out level:(int)level frame:(const SceneFrame *)frame {
  const FrameUniforms *u = &frame->uniforms;
  simd_float4 lev = _uniforms.levels[level];
  simd_float2 eye = u->camPos.xz;
  // The widest the view reaches to either side, from its four corners; no culling if a corner
  // looks sideways or back (a steep tilt).
  simd_float2 ahead = simd_normalize(u->camForward.xz);
  simd_float2 right = simd_make_float2(-ahead.y, ahead.x);
  float spread = 0;
  BOOL wide = NO;
  for (int c = 0; c < 4; c++) {
    simd_float4 p = simd_mul(u->invViewProj, simd_make_float4(c & 1 ? 1 : -1, c & 2 ? 1 : -1, 0.5f, 1));
    simd_float3 dir = p.xyz / p.w - u->camPos;
    float along = simd_dot(dir.xz, ahead), across = fabsf(simd_dot(dir.xz, right));
    if (along <= across * 0.2f) wide = YES;
    else spread = fmaxf(spread, across / along);
  }
  spread = spread * 1.06f + 0.03f;
  simd_float2 left = simd_normalize(ahead * spread + right), rightN = simd_normalize(ahead * spread - right);  // inward normals of the wedge
  simd_float2 holeLo = {INFINITY, INFINITY}, holeHi = {-INFINITY, -INFINITY};
  if (level > 0) {
    simd_float4 fine = _uniforms.levels[level - 1];
    holeLo = fine.xy + kMtnOverlap * fine.z;
    holeHi = fine.xy + (kMtnGrid - kMtnOverlap) * fine.z;
  }
  float size = kMtnBlock * lev.z, margin = lev.z + 2;
  NSUInteger n = 0;
  for (int j = 0; j < kBlocks; j++) {
    for (int i = 0; i < kBlocks; i++) {
      simd_float2 lo = lev.xy + simd_make_float2(i, j) * size, hi = lo + size;
      if (lo.x >= holeLo.x && lo.y >= holeLo.y && hi.x <= holeHi.x && hi.y <= holeHi.y) continue;
      if (!wide) {
        BOOL outL = YES, outR = YES, behind = YES;
        for (int c = 0; c < 4; c++) {
          simd_float2 q = simd_make_float2(c & 1 ? hi.x : lo.x, c & 2 ? hi.y : lo.y) - eye;
          if (simd_dot(q, left) > -margin) outL = NO;
          if (simd_dot(q, rightN) > -margin) outR = NO;
          if (simd_dot(q, ahead) > -margin) behind = NO;
        }
        if (outL || outR || behind) continue;
      }
      out[n++].block = simd_make_float4(i * kMtnBlock, j * kMtnBlock, level, 0);
    }
  }
  return n;
}

- (void)bind:(id<MTLRenderCommandEncoder>)re {
  [re setVertexBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferMountain];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferMountain];
  [re setFragmentTexture:_atlas atIndex:kTextureScene];
  [re setFragmentTexture:_clouds atIndex:kTextureClouds];
  [re setFragmentTexture:_surface atIndex:kTextureSurface];
  [re setFragmentTexture:_mask atIndex:kTextureMask];
  [re setFragmentTexture:_sunShadow atIndex:kTextureSunShadow];
  [re setVertexTexture:_heights atIndex:0];
}

- (void)drawProps:(id<MTLRenderCommandEncoder>)re shadowCasters:(BOOL)casters {
  if (!_instances) return;
  [re setVertexBuffer:_instances offset:0 atIndex:kBufferInstances];
  for (int g = 0; g < kGroups; g++) {
    if (!_groupCount[g]) continue;
    if (casters && (g <= kGroupFlowerEnd || (g >= kGroupSpruce && g <= kGroupSpruceEnd))) continue;  // too small, or too far
    BOOL plant = g <= kGroupFlowerEnd || (g >= kGroupPine && g <= kGroupSpruceEnd);
    PlantUniforms *f = plant ? &_plantUniforms : &_propUniforms;
    [re setVertexBytes:f length:sizeof *f atIndex:kBufferScene];
    [re setFragmentBytes:f length:sizeof *f atIndex:kBufferScene];
    [re setVertexBuffer:_meshes[g] offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_meshVertices[g] instanceCount:_groupCount[g] baseInstance:_groupBase[g]];
  }
}

- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [self bind:re];
  [re setRenderPipelineState:_propShadowPipe];
  [self drawProps:re shadowCasters:YES];
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [self bind:re];
  [re setDepthStencilState:_depthOn];
  [re setCullMode:MTLCullModeNone];
  // What stands on the ground first (it is near), then the ground from the finest level out.
  [re setRenderPipelineState:_propPipe];
  [self drawProps:re shadowCasters:NO];
  [re setRenderPipelineState:_terrainPipe];
  [re setCullMode:MTLCullModeBack];
  [re setFrontFacingWinding:MTLWindingCounterClockwise];
  MountainBlock blocks[kBlocks * kBlocks];
  for (int l = 0; l < kMtnLevels; l++) {
    NSUInteger n = [self visibleBlocks:blocks level:l frame:frame];
    if (!n) continue;
    [re setVertexBytes:blocks length:n * sizeof(MountainBlock) atIndex:kBufferInstances];
    [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_blockIndexCount indexType:MTLIndexTypeUInt16 indexBuffer:_blockIndices
            indexBufferOffset:0 instanceCount:n];
  }
  [re setCullMode:MTLCullModeNone];
}

@end
