#import "SeasideScene.h"

#import "CoastEnvironment.h"
#import "CoastSky.h"
#import "Furniture.h"
#import "Plants.h"
#import "SeasideProps.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"

static const float kPromenadeWidth = 8.0f;
static const double kTileLength = kPromenadeLampSpacing;  // a lamp at the start of each strip tile

#pragma mark - The coast's line (double precision for the walker; SeasidePathX elsewhere)

static double PathX(double z) {
  return 13.0 * sin(z / 170.0) + 4.0 * sin(z / 63.0 + 1.7);
}

static double PathSlope(double z) {
  return 13.0 / 170.0 * cos(z / 170.0) + 4.0 / 63.0 * cos(z / 63.0 + 1.7);
}

/// Seaward, horizontal and unit, at z (`sign`: SeasideUniforms.seaSign).
static simd_float3 Seaward(float sign, double z) {
  return simd_normalize((simd_float3){sign, 0, (float)(-sign * PathSlope(z))});
}

/// Along the coast (+z), unit.
static simd_float3 Along(double z) {
  return simd_normalize((simd_float3){(float)PathSlope(z), 0, 1});
}

/// The yaw (plant_vs) that turns a mesh's +x toward `dir`.
static double YawTurningX(simd_float3 dir) {
  return atan2(dir.z, dir.x);
}

/// The yaw (plant_vs) that turns a mesh's +z toward `dir`.
static double YawTurningZ(simd_float3 dir) {
  return atan2(-dir.x, dir.z);
}

#pragma mark - Strip tiles: paving, balustrade rails and piers, sea wall, beach

/// One kTileLength stretch of the coast's fixed geometry. Shadow casters (the balustrade's
/// stone) come first in the buffer.
@interface StripTile : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NSUInteger vertexCount, casterCount;
@end

@implementation StripTile
@end

typedef struct {
  float sign, width;
  int64_t tile;
  double z0;
} Strip;

/// A cross-section point: s seaward, y up, at absolute z; x absolute, z relative to the tile.
static simd_float3 SP(const Strip *S, float s, float y, double z) {
  return (simd_float3){(float)(PathX(z) + S->sign * s), y, (float)(z - S->z0)};
}

static void Quad(MeshBuilder *m, simd_float3 a, simd_float3 b, simd_float3 c, simd_float3 d, simd_float3 n, simd_float3 color, simd_float2 ta,
                 simd_float2 tb, simd_float2 tc, simd_float2 td) {
  [m quadA:a b:b c:c d:d normal:n color:color uvA:ta uvB:tb uvC:tc uvD:td];
}

/// A box standing on y0, centred on the coast's cross-section at (s, z), aligned with it.
static void OrientedBox(MeshBuilder *m, const Strip *S, float s, double z, float halfAlong, float halfAcross, float y0, float y1) {
  simd_float3 t = Along(z), n = Seaward(S->sign, z), up = {0, 1, 0};
  simd_float3 c = SP(S, s, 0, z);
  simd_float3 p[8];
  for (int i = 0; i < 8; i++) {
    p[i] = c + t * (i & 1 ? halfAlong : -halfAlong) + n * (i & 2 ? halfAcross : -halfAcross) + up * (i & 4 ? y1 : y0);
  }
  simd_float3 color = {1, 1, 1};
  float a = halfAlong * 2, w = halfAcross * 2;
  Quad(m, p[0], p[1], p[5], p[4], -n, color, (simd_float2){0, y0}, (simd_float2){a, y0}, (simd_float2){a, y1}, (simd_float2){0, y1});
  Quad(m, p[2], p[3], p[7], p[6], n, color, (simd_float2){0, y0}, (simd_float2){a, y0}, (simd_float2){a, y1}, (simd_float2){0, y1});
  Quad(m, p[0], p[2], p[6], p[4], -t, color, (simd_float2){0, y0}, (simd_float2){w, y0}, (simd_float2){w, y1}, (simd_float2){0, y1});
  Quad(m, p[1], p[3], p[7], p[5], t, color, (simd_float2){0, y0}, (simd_float2){w, y0}, (simd_float2){w, y1}, (simd_float2){0, y1});
  Quad(m, p[4], p[5], p[7], p[6], up, color, (simd_float2){0, 0}, (simd_float2){a, 0}, (simd_float2){a, w}, (simd_float2){0, w});
}

static NSData *StripMesh(const Strip *S, NSUInteger *casterVertices) {
  MeshBuilder *casters = [[MeshBuilder alloc] initWithSeed:1], *rest = [[MeshBuilder alloc] initWithSeed:2];
  const int steps = 22;  // 1 m
  const float Y = kPromenadeY, W = S->width;
  simd_float3 up = {0, 1, 0}, tileColor = {(float)S->tile, 0, 0}, plain = {1, 1, 1};
  static const float kBeachS[] = {kWallFoot, 2, 5, 9, 12.5f, 15, 17, 19.5f, 23, 28, 36, 48, 66, 92, 130, 180};
  const int beachN = sizeof kBeachS / sizeof kBeachS[0];
  for (int j = 0; j < steps; j++) {
    double za = S->z0 + j * kTileLength / steps, zb = S->z0 + (j + 1) * kTileLength / steps;
    float la = (float)(za - S->z0), lb = (float)(zb - S->z0);
    simd_float3 n = simd_normalize(Seaward(S->sign, za) + Seaward(S->sign, zb));
    // The paving, and the granite curb at its land edge.
    rest.material = kStripPaving;
    float p0 = -W + 0.25f;
    Quad(rest, SP(S, p0, Y, za), SP(S, kBalustradeIn, Y, za), SP(S, kBalustradeIn, Y, zb), SP(S, p0, Y, zb), up, tileColor,
         (simd_float2){p0, la}, (simd_float2){kBalustradeIn, la}, (simd_float2){kBalustradeIn, lb}, (simd_float2){p0, lb});
    rest.material = kStripCurb;
    Quad(rest, SP(S, -W, Y, za), SP(S, p0, Y, za), SP(S, p0, Y, zb), SP(S, -W, Y, zb), up, plain, (simd_float2){la, 0.25f},
         (simd_float2){la, 0}, (simd_float2){lb, 0}, (simd_float2){lb, 0.25f});
    Quad(rest, SP(S, -W, Y - 0.3f, za), SP(S, -W, Y, za), SP(S, -W, Y, zb), SP(S, -W, Y - 0.3f, zb), -n, plain, (simd_float2){la, -0.3f},
         (simd_float2){la, 0}, (simd_float2){lb, 0}, (simd_float2){lb, -0.3f});
    // The balustrade's plinth and coping (stone, casting shadows).
    casters.material = kStripStone;
    float yp = Y + kPlinthTop;
    Quad(casters, SP(S, kBalustradeIn, yp, za), SP(S, kBalustradeOut, yp, za), SP(S, kBalustradeOut, yp, zb), SP(S, kBalustradeIn, yp, zb), up, plain,
         (simd_float2){la, 0}, (simd_float2){la, 0.34f}, (simd_float2){lb, 0.34f}, (simd_float2){lb, 0});
    Quad(casters, SP(S, kBalustradeIn, Y, za), SP(S, kBalustradeIn, yp, za), SP(S, kBalustradeIn, yp, zb), SP(S, kBalustradeIn, Y, zb), -n, plain,
         (simd_float2){la, Y}, (simd_float2){la, yp}, (simd_float2){lb, yp}, (simd_float2){lb, Y});
    Quad(casters, SP(S, kBalustradeOut, Y, za), SP(S, kBalustradeOut, yp, za), SP(S, kBalustradeOut, yp, zb), SP(S, kBalustradeOut, Y, zb), n, plain,
         (simd_float2){la, Y}, (simd_float2){la, yp}, (simd_float2){lb, yp}, (simd_float2){lb, Y});
    float ci = kBalustradeIn - 0.035f, co = kBalustradeOut + 0.035f, cm = (ci + co) * 0.5f;
    float yb = Y + kCopingBottom, yt = Y + kCopingTop, ys = yt - 0.03f;
    simd_float3 slopeIn = simd_normalize(up * 0.98f - n * 0.2f), slopeOut = simd_normalize(up * 0.98f + n * 0.2f);
    Quad(casters, SP(S, ci, ys, za), SP(S, cm, yt, za), SP(S, cm, yt, zb), SP(S, ci, ys, zb), slopeIn, plain, (simd_float2){la, ci},
         (simd_float2){la, cm}, (simd_float2){lb, cm}, (simd_float2){lb, ci});
    Quad(casters, SP(S, cm, yt, za), SP(S, co, ys, za), SP(S, co, ys, zb), SP(S, cm, yt, zb), slopeOut, plain, (simd_float2){la, cm},
         (simd_float2){la, co}, (simd_float2){lb, co}, (simd_float2){lb, cm});
    Quad(casters, SP(S, ci, yb, za), SP(S, ci, ys, za), SP(S, ci, ys, zb), SP(S, ci, yb, zb), -n, plain, (simd_float2){la, yb},
         (simd_float2){la, ys}, (simd_float2){lb, ys}, (simd_float2){lb, yb});
    Quad(casters, SP(S, co, yb, za), SP(S, co, ys, za), SP(S, co, ys, zb), SP(S, co, yb, zb), n, plain, (simd_float2){la, yb},
         (simd_float2){la, ys}, (simd_float2){lb, ys}, (simd_float2){lb, yb});
    Quad(casters, SP(S, ci, yb, za), SP(S, co, yb, za), SP(S, co, yb, zb), SP(S, ci, yb, zb), -up, plain, (simd_float2){la, ci},
         (simd_float2){la, co}, (simd_float2){lb, co}, (simd_float2){lb, ci});
    // Distant balusters, drawn as a cut-out pattern (Seaside.metal: beyond SeasideUniforms.balusterFarZ).
    rest.material = kStripScreen;
    float h = kCopingBottom - kPlinthTop;
    Quad(rest, SP(S, kBalustradeS, yp, za), SP(S, kBalustradeS, yb, za), SP(S, kBalustradeS, yb, zb), SP(S, kBalustradeS, yp, zb), -n, tileColor,
         (simd_float2){la, 0}, (simd_float2){la, h}, (simd_float2){lb, h}, (simd_float2){lb, 0});
    // The sea wall, down into the sand.
    rest.material = kStripWall;
    float yf = kBeachTop - 0.4f;
    Quad(rest, SP(S, 0, yf, za), SP(S, 0, Y, za), SP(S, 0, Y, zb), SP(S, 0, yf, zb), n, plain, (simd_float2){la, yf}, (simd_float2){la, Y},
         (simd_float2){lb, Y}, (simd_float2){lb, yf});
    Quad(rest, SP(S, kBalustradeOut, Y, za), SP(S, 0, Y, za), SP(S, 0, Y, zb), SP(S, kBalustradeOut, Y, zb), up, plain, (simd_float2){la, Y},
         (simd_float2){la, Y}, (simd_float2){lb, Y}, (simd_float2){lb, Y});
    // The beach, into the sea. Its batter against the wall first.
    rest.material = kStripSand;
    Quad(rest, SP(S, 0, kBeachTop + 0.06f, za), SP(S, kWallFoot, kBeachTop, za), SP(S, kWallFoot, kBeachTop, zb), SP(S, 0, kBeachTop + 0.06f, zb),
         up, plain, (simd_float2){0, la}, (simd_float2){kWallFoot, la}, (simd_float2){kWallFoot, lb}, (simd_float2){0, lb});
    for (int k = 0; k + 1 < beachN; k++) {
      float s0 = kBeachS[k], s1 = kBeachS[k + 1], y0 = SeasideSandY(s0), y1 = SeasideSandY(s1);
      simd_float3 bn = simd_normalize(up * (s1 - s0) - n * (y1 - y0));
      Quad(rest, SP(S, s0, y0, za), SP(S, s1, y1, za), SP(S, s1, y1, zb), SP(S, s0, y0, zb), bn, plain, (simd_float2){s0, la}, (simd_float2){s1, la},
           (simd_float2){s1, lb}, (simd_float2){s0, lb});
    }
  }
  // Piers between the bays (a lamp's at the tile's start), with caps.
  casters.material = kStripStone;
  for (int b = 0; b < kBaysPerLamp; b++) {
    double z = S->z0 + b * kBayLength;
    BOOL lamp = b == 0;
    float half = lamp ? kLampPierHalf : kPierHalf, across = lamp ? 0.3f : 0.23f;
    OrientedBox(casters, S, kBalustradeS, z, half, across, Y, Y + kPierTop - 0.06f);
    OrientedBox(casters, S, kBalustradeS, z, half + 0.035f, across + 0.035f, Y + kPierTop - 0.06f, Y + kPierTop);
    if (lamp) OrientedBox(casters, S, kBalustradeS, z, 0.2f, 0.2f, Y + kPierTop, Y + kPierTop + 0.06f);
  }
  NSMutableData *all = [NSMutableData dataWithData:casters.data];
  *casterVertices = casters.vertexCount;
  [all appendData:rest.data];
  return all;
}

#pragma mark - Scene

enum {
  kGroupBaluster,
  kGroupBalusterLite,
  kGroupLamp,
  kGroupBench,
  kGroupPine,                                       // + variant × 2 + lite
  kGroupBush = kGroupPine + kPineVariants * 2,      // + variant
  kGroupGrass = kGroupBush + kPlantVariants,        // + variant
  kGroups = kGroupGrass + kPlantVariants,
};

static void AddInstance(NSMutableData *group, double x, double y, double z, double originZ, double yaw, simd_float4 tint, double height,
                        double width, double bright) {
  PlantInstance p;
  p.posYaw = simd_make_float4((float)x, (float)y, (float)(z - originZ), (float)yaw);
  p.shape = simd_make_float4((float)width, (float)height, (float)bright, (float)fmod(fabs(z) * 1.37 + x * 0.7, 6.28));
  p.tint = tint;
  [group appendBytes:&p length:sizeof p];
}

@implementation SeasideScene {
  id<MTLDevice> _device;
  id<MTLRenderPipelineState> _propPipe, _propShadowPipe, _stripPipe, _stripShadowPipe, _parkPipe, _seaPipe, _farPipe;
  id<MTLDepthStencilState> _depthOn, _depthFar;
  id<MTLTexture> _atlas, _clouds;
  id<MTLBuffer> _meshes[kGroups];
  NSUInteger _meshVertices[kGroups];
  NSMutableDictionary<NSNumber *, StripTile *> *_tiles;

  id<MTLBuffer> _instances;
  NSUInteger _groupBase[kGroups], _groupCount[kGroups], _instanceTotal;

  id<MTLBuffer> _parkVertices, _parkIndices, _seaVertices, _seaIndices;
  NSUInteger _parkIndexCount, _seaIndexCount;
  double _parkCell;

  double _originZ;
  int64_t _builtBay;
  uint64_t _builtLayout;
  SeasideUniforms _uniforms;
  PlantUniforms _propUniforms, _plantUniforms;

  // The waves (rebuilt when the wind changes): wavevector, amplitude, steepness, frequency, phase.
  SeaWaves _waves;
  simd_float2 _waveK[kSeaWaves];
  float _waveAmp[kSeaWaves], _waveSteep[kSeaWaves];
  double _waveOmega[kSeaWaves], _wavePhase[kSeaWaves];
  float _waveWind, _waveSign;

  // Settings (the layout's read when it changes; the weather's each frame).
  float _seaSign, _width, _pines, _wind;
  uint32_t _seed;
}

+ (void)load {
  [SceneRegistry registerScene:self];
}

+ (NSString *)identifier {
  return @"seaside";
}

+ (NSString *)title {
  return @"Seaside promenade";
}

+ (NSArray<SceneParameter *> *)parameters {
  NSString *promenade = @"Promenade", *sea = @"Sea";
  return @[
    [CoastEnvironment lightingParameter:CoastEnvironment.presetNames default:@"Golden hour"],
    [[SceneParameter choiceWithKey:@"sea" title:@"Sea on the" section:promenade choices:@[ @"Left", @"Right" ] value:0] relayout],
    [SceneParameter sliderWithKey:@"walk" title:@"Distance from the balustrade" section:promenade minimum:0.8 maximum:5.5 step:0.1 value:0.9
                           format:@"%.1f m"],
    [[SceneParameter sliderWithKey:@"pines" title:@"Pines" section:promenade minimum:0 maximum:1 step:0.05 value:0.7 format:@"%.2f"] relayout],
    [SceneParameter seedWithKey:@"seed" title:@"New Promenade" section:promenade value:5],
    [SceneParameter choiceWithKey:@"waves" title:@"Waves" section:sea choices:@[ @"Match the weather", @"Calm", @"Choppy", @"Rough" ] value:0],
  ];
}

+ (Class)environment {
  return CoastEnvironment.class;
}

+ (NSArray<NSString *> *)shaderSources {
  // The kit's plant shaders draw the props and pines; the coast's sky is mirrored by the sea.
  return @[ @"Plants.h", @"Plants.metal", @"CoastSky.h", @"CoastSky.metal", @"SeasideScene.h", @"Seaside.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _tiles = [NSMutableDictionary dictionary];
  _builtBay = INT64_MIN;
  _builtLayout = UINT64_MAX;
  _originZ = NAN;
  _waveWind = -1;

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, YES);
  pd.alphaToCoverageEnabled = YES;  // needle cards, the distant balusters' pattern
  pd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"seaside_prop_fs"];
  _propPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  pd.vertexFunction = [lib newFunctionWithName:@"strip_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"strip_fs"];
  _stripPipe = _propPipe ? [device newRenderPipelineStateWithDescriptor:pd error:error] : nil;
  pd.alphaToCoverageEnabled = NO;
  pd.vertexFunction = [lib newFunctionWithName:@"park_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"park_fs"];
  _parkPipe = _stripPipe ? [device newRenderPipelineStateWithDescriptor:pd error:error] : nil;

  // The sea: blended over the sand where it is shallow (premultiplied), no ambient occlusion.
  MTLRenderPipelineDescriptor *sea = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(sea, NO);
  sea.colorAttachments[0].blendingEnabled = YES;
  sea.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
  sea.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  sea.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  sea.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  sea.vertexFunction = [lib newFunctionWithName:@"sea_vs"];
  sea.fragmentFunction = [lib newFunctionWithName:@"sea_fs"];
  _seaPipe = _parkPipe ? [device newRenderPipelineStateWithDescriptor:sea error:error] : nil;
  MTLRenderPipelineDescriptor *far = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(far, NO);
  far.vertexFunction = [lib newFunctionWithName:@"far_vs"];
  far.fragmentFunction = [lib newFunctionWithName:@"far_fs"];
  _farPipe = _seaPipe ? [device newRenderPipelineStateWithDescriptor:far error:error] : nil;

  MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
  sd.depthAttachmentPixelFormat = kShadowFormat;
  sd.vertexFunction = [lib newFunctionWithName:@"plant_vs"];
  sd.fragmentFunction = [lib newFunctionWithName:@"plant_shadow_fs"];
  _propShadowPipe = _farPipe ? [device newRenderPipelineStateWithDescriptor:sd error:error] : nil;
  sd.vertexFunction = [lib newFunctionWithName:@"strip_vs"];
  sd.fragmentFunction = nil;
  _stripShadowPipe = _propShadowPipe ? [device newRenderPipelineStateWithDescriptor:sd error:error] : nil;
  if (!_stripShadowPipe) return nil;
  _atlas = FoliageAtlas(device, lib, error);
  _clouds = _atlas ? CoastCloudNoise(device, lib, error) : nil;
  if (!_clouds) return nil;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthOn = [device newDepthStencilStateWithDescriptor:dd];
  dd.depthCompareFunction = MTLCompareFunctionLessEqual;  // the far pass, just in front of the far plane
  _depthFar = [device newDepthStencilStateWithDescriptor:dd];

  for (int k = 0; k < kGroups; k++) {
    NSData *mesh;
    if (k == kGroupBaluster || k == kGroupBalusterLite) mesh = BalusterMesh(k == kGroupBalusterLite);
    else if (k == kGroupLamp) mesh = LampPostMesh();
    else if (k == kGroupBench) mesh = BenchMesh();
    else if (k < kGroupBush) mesh = WindPineMesh((k - kGroupPine) / 2, (k - kGroupPine) % 2);
    else if (k < kGroupGrass) mesh = PlantMesh(PlantBush, k - kGroupBush, NO, NO);
    else mesh = PlantMesh(PlantGrass, k - kGroupGrass, NO, NO);
    _meshes[k] = SceneBuffer(device, mesh);
    _meshVertices[k] = mesh.length / sizeof(MeshVertex);
  }
  [self buildParkGrid];
  [self buildSeaGrid];
  return self;
}

- (NSUInteger)instanceCount {
  return _instanceTotal;
}

- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values {
  double sign = [values index:@"sea"] == 1 ? 1 : -1;
  double s = kBalustradeIn - [values number:@"walk"];
  return (WalkPoint){simd_make_double3(PathX(metres) + sign * s, kPromenadeY, metres), simd_make_double3(PathSlope(metres), 0, 1)};
}

#pragma mark Grids

// The park's ground: a grid around the camera, moved in whole cells (no swimming).
- (void)buildParkGrid {
  const int n = 160;
  const double extent = 340.0;
  _parkCell = extent * 2 / n;
  NSMutableData *v = [NSMutableData dataWithLength:sizeof(simd_float2) * (n + 1) * (n + 1)];
  simd_float2 *pv = v.mutableBytes;
  for (int j = 0; j <= n; j++) {
    for (int i = 0; i <= n; i++) pv[j * (n + 1) + i] = simd_make_float2((float)(-extent + i * _parkCell), (float)(-extent + j * _parkCell));
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
  _parkVertices = SceneBuffer(_device, v);
  _parkIndices = SceneBuffer(_device, idx);
  _parkIndexCount = (NSUInteger)n * n * 6;
}

// The sea near the coast: rings around the camera, geometric in radius, over the sea's side and
// a little beyond (the coast bends); x is mirrored in sea_vs when the sea is on the left.
- (void)buildSeaGrid {
  const int rings = 190, spokes = 200;
  const double r0 = 4.0, r1 = 1150.0, a0 = -1.95, a1 = 1.95;
  double q = pow(r1 / r0, 1.0 / rings);
  NSMutableData *v = [NSMutableData dataWithLength:sizeof(simd_float2) * (rings + 1) * (spokes + 1)];
  simd_float2 *pv = v.mutableBytes;
  for (int j = 0; j <= rings; j++) {
    double r = r0 * pow(q, j);
    for (int i = 0; i <= spokes; i++) {
      double a = a0 + (a1 - a0) * i / spokes;
      pv[j * (spokes + 1) + i] = simd_make_float2((float)(r * cos(a)), (float)(r * sin(a)));
    }
  }
  NSMutableData *idx = [NSMutableData dataWithLength:sizeof(uint32_t) * rings * spokes * 6];
  uint32_t *pi = idx.mutableBytes;
  for (int j = 0; j < rings; j++) {
    for (int i = 0; i < spokes; i++) {
      uint32_t a = j * (spokes + 1) + i, b = a + 1, c = a + (spokes + 1), d = c + 1;
      uint32_t t[6] = {a, c, b, b, c, d};
      memcpy(pi, t, sizeof t);
      pi += 6;
    }
  }
  _seaVertices = SceneBuffer(_device, v);
  _seaIndices = SceneBuffer(_device, idx);
  _seaIndexCount = (NSUInteger)rings * spokes * 6;
}

#pragma mark Weather and waves

- (void)adjustLighting:(FrameUniforms *)u values:(SceneValues *)values {
  float sign = [values index:@"sea"] == 1 ? 1 : -1;
  if (sign > 0) u->sunDir.x = -u->sunDir.x;  // the sun stays over the sea
  u->windDir = simd_normalize(simd_make_float2(-sign, 0.35f));  // onshore, a little along the coast
  static const float kWind[4] = {0, 2.5f, 8, 16};
  NSInteger waves = [values index:@"waves"];
  if (waves > 0 && waves < 4) u->wind = kWind[waves];
  u->aoStrength = 0.8f;
  u->shadowSoftness = 0.008f;
  _wind = u->wind;
  _uniforms.deepColor = simd_mix(simd_make_float3(0.006f, 0.026f, 0.040f), simd_make_float3(0.012f, 0.030f, 0.028f),
                                 simd_make_float3(1, 1, 1) * u->storm);
}

/// The waves for the wind: a wind sea (a Pierson–Moskowitz spectrum, fetch-limited, its short
/// waves' slopes as Cox and Munk measured them) from twice the peak wavelength down to 5 cm, in
/// directions spread around the wind's (wider for short waves), and a swell rolling in to shore.
- (void)buildWaves {
  _waveWind = _wind;
  _waveSign = _seaSign;
  double U = fmax(_wind, 0.5), g = 9.81;
  double lp = fmax(fmin(0.83 * U * U, 6.0 + 2.4 * U), 3.0);  // peak wavelength
  double Hs = fmax(fmin(0.0214 * U * U, 0.13 * U), 0.05);    // significant height
  double slopeVar = 0.003 + 0.00512 * U;
  Rng r = RngFor(_seed, 7, 0, 71);
  double windAngle = atan2(0.35, -_seaSign), shoreAngle = atan2(0, -_seaSign);
  const int nSwell = 3, nSea = kSeaWaves - nSwell;
  double lambda[kSeaWaves], amp[kSeaWaves], angle[kSeaWaves], steep[kSeaWaves];
  double lmax = 2.0 * lp, ratio = pow(0.05 / lmax, 1.0 / (nSea - 1));
  double wp = sqrt(g * 2 * M_PI / lp), longEnergy = 0, energy[kSeaWaves];
  for (int i = 0; i < nSea; i++) {
    double l = lmax * pow(ratio, i), w = sqrt(g * 2 * M_PI / l);
    energy[i] = pow(w, -4.0) * exp(-1.25 * pow(wp / w, 4.0));  // S(ω) Δω, Δω ∝ ω
    if (l > lp / 3) longEnergy += energy[i];
    lambda[i] = l;
  }
  double norm = Hs * Hs / 8.0 / fmax(longEnergy, 1e-12), longSlope = 0, shortSlope = 0;
  for (int i = 0; i < nSea; i++) {
    double k = 2 * M_PI / lambda[i];
    amp[i] = sqrt(2 * energy[i] * norm);
    if (lambda[i] > lp / 3) longSlope += k * k * amp[i] * amp[i] / 2;
    else shortSlope += k * k * amp[i] * amp[i] / 2;
  }
  double shortScale = shortSlope > 0 ? sqrt(fmax(slopeVar - longSlope, slopeVar * 0.3) / shortSlope) : 1;
  for (int i = 0; i < nSea; i++) {
    BOOL isLong = lambda[i] > lp / 3;
    if (!isLong) amp[i] *= shortScale;
    angle[i] = windAngle + (Rand(&r) - 0.5) * 2 * (isLong ? 0.4 : 1.0);
    steep[i] = isLong ? 0.8 : 0.35;
  }
  // The swell: long, low, nearly square to the shore.
  for (int i = 0; i < nSwell; i++) {
    int k = nSea + i;
    lambda[k] = 70 + 22 * i + Range(&r, -5, 5);
    amp[k] = (0.07 + 0.012 * U) * (1.0 - 0.25 * i);
    angle[k] = shoreAngle + Range(&r, -0.15, 0.15);
    steep[k] = 0.5;
  }
  // Longest first (sea_vs moves the vertices by the first kSeaBigWaves).
  int order[kSeaWaves];
  for (int i = 0; i < kSeaWaves; i++) order[i] = i;
  for (int i = 1; i < kSeaWaves; i++) {
    for (int j = i; j > 0 && lambda[order[j]] > lambda[order[j - 1]]; j--) {
      int t = order[j];
      order[j] = order[j - 1];
      order[j - 1] = t;
    }
  }
  double chop = 0;
  for (int i = 0; i < kSeaWaves; i++) chop += steep[i] * (2 * M_PI / lambda[i]) * amp[i];
  double chopScale = chop > 0.85 ? 0.85 / chop : 1;
  for (int n = 0; n < kSeaWaves; n++) {
    int i = order[n];
    double k = 2 * M_PI / lambda[i];
    _waveK[n] = simd_make_float2((float)(k * cos(angle[i])), (float)(k * sin(angle[i])));
    _waveAmp[n] = (float)amp[i];
    _waveSteep[n] = (float)(steep[i] * chopScale);
    _waveOmega[n] = sqrt(g * k * (1 + pow(k / 370.0, 2)));  // deep water, capillary ripples
    _wavePhase[n] = Rand(&r) * 2 * M_PI;
  }
  _uniforms.surf = (float)(0.25 + Hs * 0.6 + (0.07 + 0.012 * U));
  _uniforms.surfPeriod = (float)fmax(5.5, 9.0 - U * 0.15);
  _uniforms.whitecaps = (float)fmin(fmax((U - 5.0) / 9.0, 0.0), 1.0);
}

#pragma mark Layout

- (void)readSettings:(SceneValues *)values {
  _seaSign = [values index:@"sea"] == 1 ? 1 : -1;
  _seed = (uint32_t)[values number:@"seed"];
  _pines = (float)[values number:@"pines"];
  _width = kPromenadeWidth;
  _uniforms.seaSign = _seaSign;
  _uniforms.promenadeWidth = _width;
  _waveWind = -1;
  [_tiles removeAllObjects];
}

// Balusters (near), lamps, benches, pines and shrubs around the camera.
- (void)placeAround:(double)camZ {
  NSMutableData *groups[kGroups];
  for (int k = 0; k < kGroups; k++) groups[k] = [NSMutableData data];
  double zMin = camZ - 420, zMax = camZ + 30;
  double sign = _seaSign;
  simd_float4 none = {1, 1, 1, 0};
  // Balusters within 160 m, each bay's evenly between its piers; beyond, the strip's pattern.
  int64_t b0 = (int64_t)floor((camZ - 160) / kBayLength), b1 = (int64_t)floor(zMax / kBayLength);
  _uniforms.balusterFarZ = (float)(b0 * (double)kBayLength);
  for (int64_t b = b0; b <= b1; b++) {
    BOOL lampHere = b % kBaysPerLamp == 0, lampNext = (b + 1) % kBaysPerLamp == 0;
    double start = b * (double)kBayLength + (lampHere ? kLampPierHalf : kPierHalf);
    double end = (b + 1) * (double)kBayLength - (lampNext ? kLampPierHalf : kPierHalf);
    double spacing = (end - start) / kBalustersPerBay;
    for (int i = 0; i < kBalustersPerBay; i++) {
      double z = start + (i + 0.5) * spacing;
      Rng r = RngFor(_seed, b, i, 61);
      BOOL lite = fabs(z - camZ) > 30;
      AddInstance(groups[lite ? kGroupBalusterLite : kGroupBaluster], PathX(z) + sign * kBalustradeS, kPromenadeY + kPlinthTop, z, _originZ,
                  YawTurningZ(Along(z)), none, 1, 1, Range(&r, 0.93, 1.05));
    }
  }
  // Lamps on every eighth pier, their arms over the paving; benches at the promenade's inland
  // edge, facing the sea, between them.
  simd_float4 lampPaint = simd_make_float4(Hex(0x1d3a36), 0);
  for (int64_t k = (int64_t)floor(zMin / kTileLength); k <= (int64_t)floor(zMax / kTileLength); k++) {
    double z = k * kTileLength;
    AddInstance(groups[kGroupLamp], PathX(z) + sign * kBalustradeS, kPromenadeY + kPierTop + 0.06, z, _originZ, YawTurningX(-Seaward(sign, z)), lampPaint,
                1, 1, 1);
    Rng r = RngFor(_seed, k, 0, 62);
    if (Rand(&r) < 0.8) {
      double bz = z + kTileLength * 0.5 + Range(&r, -1.5, 1.5);
      AddInstance(groups[kGroupBench], PathX(bz) + sign * (-_width + 0.7), kPromenadeY, bz, _originZ, YawTurningZ(Seaward(sign, bz)), none, 1, 1,
                  Range(&r, 0.9, 1.05));
    }
  }
  // The park: pines on a jittered grid (denser by the promenade), shrubs and dry grass near it.
  static const double kRows[][2] = {{2.5, 7}, {7, 15}, {15, 25}, {25, 37}, {37, 52}, {52, 72}, {72, 100}};
  const int rows = sizeof kRows / sizeof kRows[0];
  for (int64_t k = (int64_t)floor(zMin / kTileLength); k <= (int64_t)floor(zMax / kTileLength); k++) {
    for (int row = 0; row < rows; row++) {
      for (int cell = 0; cell < 2; cell++) {
        Rng r = RngFor(_seed, k * 2 + cell, row, 63);
        if (Rand(&r) > _pines * (row == 0 ? 0.95 : 0.7)) continue;
        double z = k * kTileLength + (cell + Range(&r, 0.1, 0.9)) * kTileLength / 2;
        double inland = Range(&r, kRows[row][0], kRows[row][1]);
        double x = PathX(z) - sign * (_width + inland);
        int variant = (int)(Rand(&r) * kPineVariants) % kPineVariants;
        BOOL lite = hypot(z - camZ, inland + _width) > 45;
        double height = Range(&r, 9, 16) * (variant == 1 ? 1.15 : 1.0);
        simd_float3 needles = Hex(0x33421f) * (float)Range(&r, 0.85, 1.12) * simd_make_float3((float)Range(&r, 0.95, 1.05), 1, (float)Range(&r, 0.9, 1.1));
        double yaw = YawTurningX(-Seaward(sign, z)) + Range(&r, -0.45, 0.45);
        AddInstance(groups[kGroupPine + variant * 2 + lite], x, SeasideParkY((float)inland, (float)x, (float)z) - 0.15, z, _originZ, yaw,
                    simd_make_float4(needles, 0), height, Range(&r, 0.9, 1.15), Range(&r, 0.9, 1.08));
      }
    }
    if (k * kTileLength < camZ - 160) continue;
    Rng r = RngFor(_seed, k, 2, 64);
    int bushes = (int)lround(Range(&r, 2, 6));
    for (int i = 0; i < bushes; i++) {
      double z = (k + Rand(&r)) * kTileLength, inland = Range(&r, 1.2, 30);
      double x = PathX(z) - sign * (_width + inland);
      simd_float3 leaves = Hex(Rand(&r) < 0.5 ? 0x3b4a26 : 0x4a5530) * (float)Range(&r, 0.85, 1.1);
      AddInstance(groups[kGroupBush + (int)(Rand(&r) * kPlantVariants) % kPlantVariants], x, SeasideParkY((float)inland, (float)x, (float)z) - 0.1, z,
                  _originZ, Rand(&r) * 6.28, simd_make_float4(leaves, 0), Range(&r, 0.8, 1.7), Range(&r, 0.9, 1.3), Range(&r, 0.9, 1.1));
    }
    int tufts = (int)lround(Range(&r, 8, 16));
    for (int i = 0; i < tufts; i++) {
      double z = (k + Rand(&r)) * kTileLength, inland = Range(&r, 0.15, 6);
      double x = PathX(z) - sign * (_width + inland);
      simd_float3 straw = Hex(Rand(&r) < 0.6 ? 0x8a7c4a : 0x6b6a38) * (float)Range(&r, 0.85, 1.1);
      AddInstance(groups[kGroupGrass + (int)(Rand(&r) * kPlantVariants) % kPlantVariants], x, SeasideParkY((float)inland, (float)x, (float)z) - 0.05, z,
                  _originZ, Rand(&r) * 6.28, simd_make_float4(straw, 0), Range(&r, 0.25, 0.6), 1, Range(&r, 0.9, 1.1));
    }
  }
  NSMutableData *all = [NSMutableData data];
  for (int k = 0; k < kGroups; k++) {
    _groupBase[k] = all.length / sizeof(PlantInstance);
    _groupCount[k] = groups[k].length / sizeof(PlantInstance);
    [all appendData:groups[k]];
  }
  _instances = SceneBuffer(_device, all);
  _instanceTotal = all.length / sizeof(PlantInstance);
}

- (void)updateTilesAround:(double)camZ {
  int64_t t0 = (int64_t)floor((camZ - 440) / kTileLength), t1 = (int64_t)floor((camZ + 40) / kTileLength);
  for (NSNumber *key in _tiles.allKeys) {
    if (key.longLongValue < t0 || key.longLongValue > t1) [_tiles removeObjectForKey:key];
  }
  for (int64_t t = t0; t <= t1; t++) {
    if (_tiles[@(t)]) continue;
    Strip S = {.sign = _seaSign, .width = _width, .tile = t, .z0 = t * kTileLength};
    NSUInteger casters = 0;
    NSData *mesh = StripMesh(&S, &casters);
    StripTile *tile = [StripTile new];
    tile.buffer = SceneBuffer(_device, mesh);
    tile.vertexCount = mesh.length / sizeof(MeshVertex);
    tile.casterCount = casters;
    _tiles[@(t)] = tile;
  }
}

- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values {
  BOOL relayout = values.layoutGeneration != _builtLayout;
  if (relayout) [self readSettings:values];
  // Re-place every bay walked: the balusters' instanced stretch moves a bay at a time.
  int64_t bay = (int64_t)floor(frame->distance / kBayLength);
  if (relayout || frame->originZ != _originZ || bay != _builtBay) {
    _originZ = frame->originZ;
    _builtBay = bay;
    _builtLayout = values.layoutGeneration;
    [self placeAround:frame->distance];
    [self updateTilesAround:frame->distance];
  }
  if (_wind != _waveWind || _seaSign != _waveSign) [self buildWaves];
  // The waves' phases at the eye, in double precision (positions in the shaders are relative to it).
  double ex = frame->eye.x, ez = frame->eye.z, t = frame->time;
  for (int i = 0; i < kSeaWaves; i++) {
    double ph = fmod(_wavePhase[i] + _waveK[i].x * ex + _waveK[i].y * ez - _waveOmega[i] * t, 2 * M_PI);
    _waves.wave[i] = simd_make_float4(_waveK[i].x, _waveK[i].y, _waveAmp[i], (float)ph);
    _waves.steep[i] = _waveSteep[i];
  }
  _uniforms.eye = simd_make_float2(frame->uniforms.camPos.x, frame->uniforms.camPos.z);
  _plantUniforms.wind = (float)fmin(_wind / 16.0, 1.0);
}

#pragma mark Drawing

- (void)bindScene:(id<MTLRenderCommandEncoder>)re {
  [re setVertexBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferSeaside];
  [re setFragmentBytes:&_uniforms length:sizeof _uniforms atIndex:kBufferSeaside];
  [re setVertexBytes:&_waves length:sizeof _waves atIndex:kBufferWaves];
  [re setFragmentBytes:&_waves length:sizeof _waves atIndex:kBufferWaves];
  [re setFragmentTexture:_atlas atIndex:kTextureScene];
  [re setFragmentTexture:_clouds atIndex:kTextureClouds];
}

- (void)drawProps:(id<MTLRenderCommandEncoder>)re shadowCasters:(BOOL)casters {
  if (!_instances) return;
  [re setVertexBuffer:_instances offset:0 atIndex:kBufferInstances];
  for (int k = 0; k < kGroups; k++) {
    if (!_groupCount[k]) continue;
    if (casters && k >= kGroupGrass) continue;  // small
    PlantUniforms *f = k >= kGroupPine ? &_plantUniforms : &_propUniforms;
    [re setVertexBytes:f length:sizeof *f atIndex:kBufferScene];
    [re setFragmentBytes:f length:sizeof *f atIndex:kBufferScene];
    // Shadows don't need every needle: pines cast them with their lighter mesh.
    int mesh = casters && k >= kGroupPine && k < kGroupBush && (k - kGroupPine) % 2 == 0 ? k + 1 : k;
    [re setVertexBuffer:_meshes[mesh] offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_meshVertices[mesh] instanceCount:_groupCount[k] baseInstance:_groupBase[k]];
  }
}

/// The strip tiles, nearest first (shadow casters only: the balustrade's stone).
- (void)drawStrips:(id<MTLRenderCommandEncoder>)re shadowCasters:(BOOL)casters {
  NSArray<NSNumber *> *keys = [[_tiles.allKeys sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator].allObjects;
  for (NSNumber *key in keys) {
    StripTile *tile = _tiles[key];
    NSUInteger count = casters ? tile.casterCount : tile.vertexCount;
    if (!count) continue;
    simd_float3 offset = {0, 0, (float)(key.longLongValue * kTileLength - _originZ)};
    [re setVertexBytes:&offset length:sizeof offset atIndex:kBufferInstances];
    [re setVertexBuffer:tile.buffer offset:0 atIndex:kBufferVertices];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
  }
}

- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [self bindScene:re];
  [re setRenderPipelineState:_propShadowPipe];
  [self drawProps:re shadowCasters:YES];
  [re setRenderPipelineState:_stripShadowPipe];
  [self drawStrips:re shadowCasters:YES];
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [self bindScene:re];
  [re setDepthStencilState:_depthOn];
  [re setCullMode:MTLCullModeNone];
  // Props first (they hide much of what is behind), then the coast's strips, the park, the sea
  // (blended over the sand where it is shallow), and what lies beyond the far plane.
  [re setRenderPipelineState:_propPipe];
  [self drawProps:re shadowCasters:NO];
  [re setRenderPipelineState:_stripPipe];
  [self drawStrips:re shadowCasters:NO];
  simd_float3 eye = frame->uniforms.camPos;
  simd_float2 parkOffset = simd_make_float2((float)(floor(eye.x / _parkCell) * _parkCell), (float)(floor(eye.z / _parkCell) * _parkCell));
  [re setRenderPipelineState:_parkPipe];
  [re setVertexBuffer:_parkVertices offset:0 atIndex:kBufferVertices];
  [re setVertexBytes:&parkOffset length:sizeof parkOffset atIndex:kBufferInstances];
  [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_parkIndexCount indexType:MTLIndexTypeUInt32 indexBuffer:_parkIndices indexBufferOffset:0];
  simd_float2 seaCenter = simd_make_float2(floorf(eye.x / 2) * 2, floorf(eye.z / 2) * 2);
  [re setRenderPipelineState:_seaPipe];
  [re setVertexBuffer:_seaVertices offset:0 atIndex:kBufferVertices];
  [re setVertexBytes:&seaCenter length:sizeof seaCenter atIndex:kBufferInstances];
  [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_seaIndexCount indexType:MTLIndexTypeUInt32 indexBuffer:_seaIndices indexBufferOffset:0];
  [re setRenderPipelineState:_farPipe];
  [re setDepthStencilState:_depthFar];
  [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

@end
