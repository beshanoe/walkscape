#import "ForestScene.h"

#import "Plants.h"
#import "OutdoorEnvironment.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"

#pragma mark - Path and terrain (keep in sync with Forest.metal)

static const simd_float4 kPath = {10.0f, 80.0f, 3.0f, 41.0f};
static const double kTile = 24.0;

static double PathX(double z) {
  return kPath.x * sin(z / kPath.y) + kPath.z * sin(z / kPath.w + 1.3);
}

static double PathSlope(double z) {
  return kPath.x / kPath.y * cos(z / kPath.y) + kPath.z / kPath.w * cos(z / kPath.w + 1.3);
}

static double GroundHeight(double x, double z, double hills) {
  double h = 0.8 * sin(x * 0.043 + 1.1) * sin(z * 0.037) + 0.5 * sin(x * 0.091 + z * 0.063) + 0.3 * sin(z * 0.13 - x * 0.05);
  double d = fabs(x - PathX(z));
  double t = fmin(fmax((d - 5.0) / 13.0, 0.0), 1.0);
  return h * hills * t * t * (3 - 2 * t);
}

#pragma mark - Settings

enum { kTypeMixed, kTypeSpruce, kTypePine, kTypeBeech, kTypeBirch };
enum { kSpring, kSummer, kAutumn, kWinter };
enum { kPathRoad, kPathTrail, kPathGravel };

// Tree species shares per forest type: spruce, pine, oak, beech, birch.
static const double kMix[5][5] = {
  {0.34, 0.10, 0.22, 0.16, 0.18},  // mixed
  {0.88, 0.02, 0.04, 0.00, 0.06},  // spruce
  {0.06, 0.86, 0.02, 0.00, 0.06},  // pine
  {0.05, 0.00, 0.12, 0.83, 0.00},  // beech
  {0.08, 0.08, 0.04, 0.00, 0.80},  // birch
};
static const PlantKind kTreeKinds[5] = {PlantSpruce, PlantPine, PlantOak, PlantBeech, PlantBirch};
static const double kTreeHeight[5][2] = {{20, 34}, {18, 28}, {15, 24}, {22, 32}, {13, 20}};

// Forest floor per type: living cover (moss, grass) and litter (needles, leaves); sRGB.
static const uint32_t kFloor[5][2] = {
  {0x485c2c, 0x4f4434}, {0x3d5228, 0x463a2e}, {0x66643a, 0x726050}, {0x535a30, 0x6c5036}, {0x587434, 0x524836},
};

static const double kPathHalfWidth[3] = {1.5, 0.6, 1.8};

#pragma mark - Colours

static simd_float3 Pick(Rng *r, const uint32_t *colors, int n) {
  return Hex(colors[(int)(Rand(r) * n) % n]);
}

/// Foliage colour (linear) for a plant in a season, varied per plant.
static simd_float3 FoliageTint(PlantKind kind, int season, Rng *r) {
  simd_float3 c;
  static const uint32_t oakAutumn[] = {0xc0782a, 0xa5521e, 0xd2a03a, 0x8a7a2a}, beechAutumn[] = {0xb8682a, 0xc98a35, 0xa55a25};
  static const uint32_t birchAutumn[] = {0xe0b83c, 0xd4a030, 0xc7b545}, bushAutumn[] = {0xa86a2a, 0x8d4a22, 0x9a8030};
  switch (kind) {
    case PlantSpruce: c = Hex(season == kSpring ? 0x35583a : 0x2b4a2c); break;
    case PlantPine: c = Hex(0x3e5a2c); break;
    case PlantOak: c = season == kSpring ? Hex(0x7fa83f) : season == kAutumn ? Pick(r, oakAutumn, 4) : Hex(0x4f7a2c); break;
    case PlantBeech: c = season == kSpring ? Hex(0x8fb548) : season == kAutumn ? Pick(r, beechAutumn, 3) : Hex(0x5a822e); break;
    case PlantBirch: c = season == kSpring ? Hex(0xa0c552) : season == kAutumn ? Pick(r, birchAutumn, 3) : Hex(0x6f9c3c); break;
    case PlantBush: c = season == kSpring ? Hex(0x75a03c) : season == kAutumn ? Pick(r, bushAutumn, 3) : Hex(0x4c7a2c); break;
    case PlantFern: c = Hex(season == kSpring ? 0x6a9a35 : season == kAutumn ? 0x9a6a2c : 0x4f8030); break;
    case PlantGrass: c = Hex(season == kSpring ? 0x648a33 : season == kAutumn ? 0x857e48 : 0x56702c); break;
    default: c = (simd_float3){1, 1, 1}; break;
  }
  float b = (float)Range(r, 0.85, 1.12);
  return c * b * simd_make_float3((float)Range(r, 0.94, 1.06), 1, (float)Range(r, 0.92, 1.08));
}

#pragma mark - Scene

enum { kLOD = 2, kBare = 2 };
#define kMeshKeys (PlantKindCount * kPlantVariants * kLOD * kBare)

static int MeshKey(int kind, int variant, BOOL lite, BOOL bare) {
  return ((kind * kPlantVariants + variant) * kLOD + (lite ? 1 : 0)) * kBare + (bare ? 1 : 0);
}

static PlantKind KindOfKey(int key) {
  return (PlantKind)(key / (kPlantVariants * kLOD * kBare));
}

/// Instances being placed, one bucket per mesh, split into those near the camera (they cast
/// shadows) and the rest.
typedef struct {
  __unsafe_unretained NSMutableData *near[kMeshKeys], *far[kMeshKeys];
  double originZ, camZ, hills;
  int season;
} Placement;

static void Add(Placement *pl, PlantKind kind, double x, double z, double height, double width, simd_float4 tint, Rng *r) {
  BOOL bare = pl->season == kWinter && PlantIsDeciduous(kind);
  double distance = hypot(x - PathX(pl->camZ), z - pl->camZ);
  BOOL lite = kind <= PlantBirch && distance > (kind == PlantSpruce || kind == PlantPine ? 70 : 55);
  int variant = (int)(Rand(r) * kPlantVariants) % kPlantVariants;
  double sink = kind == PlantRock ? Range(r, 0.05, 0.25) * height : kind == PlantLog ? 0.1 * height : 0.15;
  PlantInstance p;
  p.posYaw = simd_make_float4((float)x, (float)(GroundHeight(x, z, pl->hills) - sink), (float)(z - pl->originZ), (float)(Rand(r) * 2 * M_PI));
  p.shape = simd_make_float4((float)width, (float)height, (float)Range(r, 0.88, 1.1), (float)(Rand(r) * 6.28));
  p.tint = tint;
  int key = MeshKey(kind, variant, lite, bare);
  [(distance < 170 ? pl->near[key] : pl->far[key]) appendBytes:&p length:sizeof p];
}

@implementation ForestScene {
  id<MTLDevice> _device;
  id<MTLRenderPipelineState> _groundPipe, _plantPipe, _plantShadowPipe;
  id<MTLDepthStencilState> _depthOn;
  id<MTLTexture> _atlas;
  id<MTLBuffer> _meshes[kMeshKeys];
  NSUInteger _meshVertices[kMeshKeys];
  id<MTLBuffer> _gridVertices, _gridIndices;
  NSUInteger _gridIndexCount;
  double _gridCell;

  // Instances, grouped by mesh: draw i is mesh _drawKey[i], instances _drawBase[i] … + _drawCount[i].
  id<MTLBuffer> _instances;
  int _drawKey[kMeshKeys];
  NSUInteger _drawBase[kMeshKeys], _drawCount[kMeshKeys], _drawNear[kMeshKeys];  // near ones first
  int _draws;
  NSUInteger _instanceTotal;

  // The layout in the instance buffer.
  double _originZ;
  int64_t _builtTileZ;
  uint64_t _builtLayout;
  ForestUniforms _uniforms;
  PlantUniforms _plantUniforms;

  // Settings (read when the layout generation changes).
  uint32_t _seed;
  int _type, _season, _pathType;
  double _density, _heightScale, _canopy, _undergrowth, _hills, _halfWidth;
}

+ (void)load {
  [SceneRegistry registerScene:self];
}

+ (NSString *)identifier {
  return @"forest";
}

+ (NSString *)title {
  return @"Forest road";
}

+ (NSArray<SceneParameter *> *)parameters {
  NSString *forest = @"Forest", *path = @"Path";
  return @[
    [OutdoorEnvironment lightingParameter:@[ @"Sunny", @"Morning sun", @"Golden hour", @"Bright overcast", @"Cloudy", @"Foggy", @"After rain" ]
                                  default:@"Sunny"],
    [[SceneParameter choiceWithKey:@"type" title:@"Trees" section:forest choices:@[ @"Mixed", @"Spruce", @"Pine", @"Beech", @"Birch" ]
                             value:0] relayout],
    [[SceneParameter choiceWithKey:@"season" title:@"Season" section:forest choices:@[ @"Spring", @"Summer", @"Autumn", @"Winter" ]
                             value:1] relayout],
    [[SceneParameter sliderWithKey:@"density" title:@"Density" section:forest minimum:0.4 maximum:1.6 step:0.05 value:1
                            format:@"%.2f×"] relayout],
    [[SceneParameter sliderWithKey:@"height" title:@"Tree height" section:forest minimum:0.6 maximum:1.4 step:0.05 value:1
                            format:@"%.2f×"] relayout],
    [[SceneParameter sliderWithKey:@"canopy" title:@"Canopy over the path" section:forest minimum:0 maximum:1 step:0.05 value:0.6
                            format:@"%.2f"] relayout],
    [[SceneParameter sliderWithKey:@"undergrowth" title:@"Undergrowth" section:forest minimum:0 maximum:1 step:0.05 value:0.6
                            format:@"%.2f"] relayout],
    [SceneParameter seedWithKey:@"seed" title:@"New Forest" section:forest value:7],
    [[SceneParameter choiceWithKey:@"path" title:@"Path" section:path choices:@[ @"Forest road", @"Trail", @"Gravel road" ] value:0] relayout],
    [[SceneParameter sliderWithKey:@"width" title:@"Path width" section:path minimum:0.6 maximum:1.6 step:0.05 value:1 format:@"%.2f×"]
        relayout],
    [[SceneParameter sliderWithKey:@"hills" title:@"Hills" section:path minimum:0 maximum:3 step:0.1 value:1 format:@"%.1f×"] relayout],
    [SceneParameter sliderWithKey:@"wind" title:@"Wind" section:path minimum:0 maximum:1 step:0.05 value:0.4 format:@"%.2f"],
  ];
}

+ (Class)environment {
  return OutdoorEnvironment.class;
}

+ (NSArray<NSString *> *)shaderSources {
  return @[ @"Plants.h", @"Plants.metal", @"ForestScene.h", @"Forest.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _builtTileZ = INT64_MIN;
  _originZ = NAN;
  _builtLayout = UINT64_MAX;

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, NO);
  pd.vertexFunction = [lib newFunctionWithName:@"ground_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"ground_fs"];
  _groundPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  pd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"plant_fs"];
  pd.alphaToCoverageEnabled = YES;  // leaf cards: cut out, antialiased by the 4× MSAA
  _plantPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
  sd.depthAttachmentPixelFormat = kShadowFormat;
  sd.vertexFunction = pd.vertexFunction;
  sd.fragmentFunction = [lib newFunctionWithName:@"plant_shadow_fs"];
  _plantShadowPipe = [device newRenderPipelineStateWithDescriptor:sd error:error];
  _atlas = FoliageAtlas(device, lib, error);
  if (!_groundPipe || !_plantPipe || !_plantShadowPipe || !_atlas) return nil;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthOn = [device newDepthStencilStateWithDescriptor:dd];

  for (int kind = 0; kind < PlantKindCount; kind++) {
    for (int v = 0; v < kPlantVariants; v++) {
      for (int lite = 0; lite < kLOD; lite++) {
        for (int bare = 0; bare < kBare; bare++) {
          int key = MeshKey(kind, v, lite, bare);
          if (bare && !PlantIsDeciduous(kind)) {  // evergreen: the same mesh in winter
            _meshes[key] = _meshes[MeshKey(kind, v, lite, NO)];
            _meshVertices[key] = _meshVertices[MeshKey(kind, v, lite, NO)];
            continue;
          }
          NSData *mesh = PlantMesh(kind, v, lite, bare);
          _meshes[key] = SceneBuffer(device, mesh);
          _meshVertices[key] = mesh.length / sizeof(MeshVertex);
        }
      }
    }
  }
  [self buildGrid];
  return self;
}

- (NSUInteger)instanceCount {
  return _instanceTotal;
}

- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values {
  double x = PathX(metres);
  return (WalkPoint){simd_make_double3(x, 0, metres), simd_make_double3(PathSlope(metres), 0, 1)};  // the path is flat
}

// Ground: a grid around the camera, finer near it, moved in whole cells so it never swims.
- (void)buildGrid {
  const int n = 200;
  const double extent = 420.0;
  _gridCell = extent * 2 / n;
  NSMutableData *v = [NSMutableData dataWithLength:sizeof(simd_float2) * (n + 1) * (n + 1)];
  simd_float2 *pv = v.mutableBytes;
  for (int j = 0; j <= n; j++) {
    for (int i = 0; i <= n; i++) pv[j * (n + 1) + i] = simd_make_float2((float)(-extent + i * _gridCell), (float)(-extent + j * _gridCell));
  }
  NSMutableData *idx = [NSMutableData dataWithLength:sizeof(uint32_t) * n * n * 6];
  uint32_t *pi = idx.mutableBytes;
  for (int j = 0; j < n; j++) {
    for (int i = 0; i < n; i++) {
      uint32_t a = j * (n + 1) + i, b = a + 1, c = a + (n + 1), d = c + 1;
      uint32_t q[6] = {a, c, b, b, c, d};
      memcpy(pi, q, sizeof q);
      pi += 6;
    }
  }
  _gridVertices = SceneBuffer(_device, v);
  _gridIndices = SceneBuffer(_device, idx);
  _gridIndexCount = (NSUInteger)n * n * 6;
}

#pragma mark Settings and layout

- (void)readSettings:(SceneValues *)values {
  _seed = (uint32_t)[values number:@"seed"];
  _type = (int)MIN(MAX([values index:@"type"], 0), 4);
  _season = (int)MIN(MAX([values index:@"season"], 0), 3);
  _pathType = (int)MIN(MAX([values index:@"path"], 0), 2);
  _density = [values number:@"density"];
  _heightScale = [values number:@"height"];
  _canopy = [values number:@"canopy"];
  _undergrowth = [values number:@"undergrowth"];
  _hills = [values number:@"hills"];
  _halfWidth = kPathHalfWidth[_pathType] * [values number:@"width"];

  simd_float3 a = Hex(kFloor[_type][0]), b = Hex(kFloor[_type][1]);
  if (_season == kSpring) a = a * simd_make_float3(0.95f, 1.12f, 0.9f);
  if (_season == kAutumn) {
    a = simd_mix(a, Hex(0x6a5a30), 0.4f);
    b = simd_mix(b, Hex(0x8a4a22), 0.55f);
  }
  _uniforms.path = kPath;
  _uniforms.floorA = simd_make_float4(a, 0);
  _uniforms.floorB = simd_make_float4(b, 0);
  _uniforms.roadHalfWidth = (float)_halfWidth;
  _uniforms.pathType = _pathType;
  _uniforms.hills = (float)_hills;
  _uniforms.snow = _season == kWinter ? 1 : 0;
  _plantUniforms.snow = _uniforms.snow;
  _plantUniforms.moss = 1;
}

- (PlantKind)treeKind:(Rng *)r {
  double pick = Rand(r), acc = 0;
  for (int i = 0; i < 5; i++) {
    acc += kMix[_type][i];
    if (pick < acc) return kTreeKinds[i];
  }
  return kTreeKinds[0];
}

- (void)addTree:(Placement *)pl kind:(PlantKind)kind x:(double)x z:(double)z scale:(double)scale width:(double)width rng:(Rng *)r {
  int i = 0;
  while (i < 4 && kTreeKinds[i] != kind) i++;
  double h = Range(r, kTreeHeight[i][0], kTreeHeight[i][1]) * _heightScale * scale;
  simd_float3 tint = FoliageTint(kind, _season, r);
  float snow = _season == kWinter ? (float)Range(r, 0.55, 0.95) : 0;
  Add(pl, kind, x, z, h, width * Range(r, 0.88, 1.15), simd_make_float4(tint, snow), r);
}

// Trees in 24 m tiles (deterministic per tile and seed), a row along each side of the path, and
// undergrowth near the walk.
- (void)rebuildAroundZ:(double)camZ {
  Placement pl = {.originZ = _originZ, .camZ = camZ, .hills = _hills, .season = _season};
  NSMutableArray *keep = [NSMutableArray array];  // owns the buckets
  for (int k = 0; k < kMeshKeys; k++) {
    NSMutableData *near = [NSMutableData data], *far = [NSMutableData data];
    [keep addObjectsFromArray:@[ near, far ]];
    pl.near[k] = near;
    pl.far[k] = far;
  }
  uint32_t seed = _seed;
  double hw = _halfWidth;
  double zMin = camZ - 340, zMax = camZ + 30;
  double cx = PathX(camZ);
  int64_t tz0 = (int64_t)floor(zMin / kTile), tz1 = (int64_t)floor(zMax / kTile);
  int64_t tx0 = (int64_t)floor((cx - 190) / kTile), tx1 = (int64_t)floor((cx + 190) / kTile);
  BOOL winter = _season == kWinter;
  for (int64_t tz = tz0; tz <= tz1; tz++) {
    for (int64_t tx = tx0; tx <= tx1; tx++) {
      Rng r = RngFor(seed, tx, tz, 1);
      // A whole number of trees per tile on average: the fraction decides one more or not.
      double expected = 7 * _density;
      int perTile = (int)expected + (Rand(&r) < expected - floor(expected) ? 1 : 0);
      for (int i = 0; i < perTile; i++) {
        double x = (tx + Rand(&r)) * kTile, z = (tz + Rand(&r)) * kTile;
        PlantKind kind = [self treeKind:&r];
        if (fabs(x - PathX(z)) < hw + 6.0) continue;  // the path rows handle the verge
        [self addTree:&pl kind:kind x:x z:z scale:1 width:1 rng:&r];
      }
      // Undergrowth within ~150 m of the camera and 70 m of the path (it is small).
      double tileZ = (tz + 0.5) * kTile;
      if (tileZ < camZ - 150 || fabs((tx + 0.5) * kTile - PathX(tileZ)) > 70) continue;
      Rng u = RngFor(seed, tx, tz, 3);
      double fernShare = _type == kTypeSpruce || _type == kTypeMixed ? 1.3 : _type == kTypeBeech ? 0.3 : 0.6;
      double grassShare = _type == kTypeBirch || _type == kTypePine ? 1.6 : _type == kTypeBeech ? 0.3 : 0.8;
      int counts[3] = {
        (int)lround(Range(&u, 2, 6) * _undergrowth * (_type == kTypeBeech ? 0.4 : 1)),
        winter ? 0 : (int)lround(Range(&u, 4, 14) * _undergrowth * fernShare),
        winter ? 0 : (int)lround(Range(&u, 8, 20) * _undergrowth * grassShare),
      };
      PlantKind kinds[3] = {PlantBush, PlantFern, PlantGrass};
      for (int k = 0; k < 3; k++) {
        for (int i = 0; i < counts[k]; i++) {
          double x = (tx + Rand(&u)) * kTile, z = (tz + Rand(&u)) * kTile;
          if (fabs(x - PathX(z)) < hw + 0.6) continue;
          double h = k == 0 ? Range(&u, 0.7, 1.7) : k == 1 ? Range(&u, 0.45, 0.95) : Range(&u, 0.25, 0.55);
          Add(&pl, kinds[k], x, z, h, k == 1 ? Range(&u, 1.1, 1.5) : 1, simd_make_float4(FoliageTint(kinds[k], _season, &u), 0), &u);
        }
      }
      if (Rand(&u) < 0.55) {  // a rock, a log or a stump
        double x = (tx + Rand(&u)) * kTile, z = (tz + Rand(&u)) * kTile;
        double pick = Rand(&u);
        PlantKind kind = pick < 0.45 ? PlantRock : pick < 0.75 ? PlantLog : PlantStump;
        double h = kind == PlantRock ? Range(&u, 0.5, 1.6) : kind == PlantLog ? Range(&u, 0.3, 0.5) : Range(&u, 0.3, 0.6);
        if (fabs(x - PathX(z)) > hw + (kind == PlantLog ? 5.0 : 1.5)) {
          Add(&pl, kind, x, z, h, kind == PlantRock ? Range(&u, 1.0, 1.6) : 1, simd_make_float4(1, 1, 1, winter ? 0.8f : 0), &u);
        }
      }
    }
  }
  // Path rows: tall trees on both sides; with more canopy they stand closer and their crowns meet.
  const double spacing = 8.5;
  double offset = 4.8 - 2.6 * _canopy, chance = 0.55 + 0.4 * _canopy, crown = 0.9 + 0.4 * _canopy;
  for (int64_t k = (int64_t)floor(zMin / spacing); k <= (int64_t)floor(zMax / spacing); k++) {
    for (int side = -1; side <= 1; side += 2) {
      Rng r = RngFor(seed, k, side, 2);
      if (Rand(&r) > chance * fmin(_density, 1.2)) continue;
      double z = k * spacing + Range(&r, -1.8, 1.8);
      double x = PathX(z) + side * (hw + offset + Range(&r, 0, 2.2));
      [self addTree:&pl kind:[self treeKind:&r] x:x z:z scale:1.08 width:crown rng:&r];
    }
  }
  // Verges: grass and the odd fern or stone along the path, near the camera.
  for (int64_t k = (int64_t)floor((camZ - 120) / 6.0); k <= (int64_t)floor(zMax / 6.0); k++) {
    Rng r = RngFor(seed, k, 0, 4);
    int n = winter ? 0 : (int)lround(10 * _undergrowth * (_pathType == kPathTrail ? 1.4 : 1));
    for (int i = 0; i < n; i++) {
      double z = (k + Rand(&r)) * 6.0, side = Rand(&r) < 0.5 ? -1 : 1;
      double x = PathX(z) + side * (hw + Range(&r, 0.05, 3.5));
      BOOL fern = Rand(&r) < 0.2;
      PlantKind kind = fern ? PlantFern : PlantGrass;
      Add(&pl, kind, x, z, fern ? Range(&r, 0.4, 0.8) : Range(&r, 0.2, 0.5), fern ? 1.3 : 1,
          simd_make_float4(FoliageTint(kind, _season, &r), 0), &r);
    }
    if (Rand(&r) < 0.15) {
      double z = (k + Rand(&r)) * 6.0, side = Rand(&r) < 0.5 ? -1 : 1;
      Add(&pl, PlantRock, PathX(z) + side * (hw + Range(&r, 0.4, 2.5)), z, Range(&r, 0.25, 0.6), 1.2,
          simd_make_float4(1, 1, 1, winter ? 0.8f : 0), &r);
    }
  }

  // One buffer, grouped by mesh, each group front to back (hidden leaves then cost little).
  simd_float2 eye = simd_make_float2((float)PathX(camZ), (float)(camZ - _originZ));
  for (int key = 0; key < kMeshKeys; key++) {
    for (NSMutableData *bucket in @[ pl.near[key], pl.far[key] ]) {
      qsort_b(bucket.mutableBytes, bucket.length / sizeof(PlantInstance), sizeof(PlantInstance), ^int(const void *a, const void *b) {
        const PlantInstance *pa = a, *pb = b;
        float da = simd_distance_squared(pa->posYaw.xz, eye), db = simd_distance_squared(pb->posYaw.xz, eye);
        return da < db ? -1 : da > db;
      });
    }
  }
  NSMutableData *all = [NSMutableData data];
  _draws = 0;
  for (int key = 0; key < kMeshKeys; key++) {
    NSUInteger near = pl.near[key].length / sizeof(PlantInstance), n = near + pl.far[key].length / sizeof(PlantInstance);
    if (!n || !_meshes[key]) continue;
    _drawKey[_draws] = key;
    _drawBase[_draws] = all.length / sizeof(PlantInstance);
    _drawCount[_draws] = n;
    _drawNear[_draws] = near;
    _draws++;
    [all appendData:pl.near[key]];
    [all appendData:pl.far[key]];
  }
  _instances = SceneBuffer(_device, all);
  _instanceTotal = all.length / sizeof(PlantInstance);
}

- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values {
  _plantUniforms.wind = (float)[values number:@"wind"];
  BOOL relayout = values.layoutGeneration != _builtLayout;
  if (relayout) [self readSettings:values];
  int64_t tileZ = (int64_t)floor(frame->distance / kTile);
  if (relayout || frame->originZ != _originZ || tileZ != _builtTileZ) {
    _originZ = frame->originZ;
    _builtTileZ = tileZ;
    _builtLayout = values.layoutGeneration;
    [self rebuildAroundZ:frame->distance];
  }
}

- (void)adjustLighting:(FrameUniforms *)u values:(SceneValues *)values {
  u->fogDensity *= 1.4f;  // forest air: the far trees fade sooner
  if ([values index:@"season"] == kWinter) {
    u->groundAmbient *= 3.0f;  // light bounced off the snow
    u->whiteBalance *= simd_make_float3(0.97f, 1.0f, 1.04f);
  }
}

#pragma mark Drawing

- (void)bindPlants:(id<MTLRenderCommandEncoder>)re {
  [re setVertexBytes:&_plantUniforms length:sizeof _plantUniforms atIndex:kBufferScene];
  [re setFragmentBytes:&_plantUniforms length:sizeof _plantUniforms atIndex:kBufferScene];
  [re setFragmentTexture:_atlas atIndex:kTextureScene];
}

- (void)drawPlants:(id<MTLRenderCommandEncoder>)re shadowCasters:(BOOL)casters {
  if (!_instances) return;
  [re setVertexBuffer:_instances offset:0 atIndex:kBufferInstances];
  for (int i = 0; i < _draws; i++) {
    int key = _drawKey[i];
    NSUInteger count = _drawCount[i];
    if (casters) {
      PlantKind kind = KindOfKey(key);
      if (kind == PlantGrass || kind == PlantFern || !_drawNear[i]) continue;  // small, or too far to matter
      count = _drawNear[i];
      if (kind <= PlantBirch) key |= kBare;  // the lite mesh (the lite bit is the one above the bare bit)
    }
    [re setVertexBuffer:_meshes[key] offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_meshVertices[key] instanceCount:count baseInstance:_drawBase[i]];
  }
}

- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [self bindPlants:re];
  [re setRenderPipelineState:_plantShadowPipe];
  [self drawPlants:re shadowCasters:YES];
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [self bindPlants:re];
  [re setDepthStencilState:_depthOn];
  [re setCullMode:MTLCullModeNone];
  // Plants first: they hide much of the ground.
  [re setRenderPipelineState:_plantPipe];
  [self drawPlants:re shadowCasters:NO];
  [re setRenderPipelineState:_groundPipe];
  [re setVertexBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferScene];
  simd_float3 eye = frame->uniforms.camPos;
  simd_float2 gridOffset = simd_make_float2((float)(floor(eye.x / _gridCell) * _gridCell), (float)(floor(eye.z / _gridCell) * _gridCell));
  [re setVertexBuffer:_gridVertices offset:0 atIndex:kBufferVertices];
  [re setVertexBytes:&gridOffset length:sizeof gridOffset atIndex:kBufferInstances];
  [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_gridIndexCount indexType:MTLIndexTypeUInt32 indexBuffer:_gridIndices
          indexBufferOffset:0];
}

@end
