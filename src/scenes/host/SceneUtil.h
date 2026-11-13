// Helpers every scene uses: deterministic randomness (SplitMix64, so a tile's contents depend only
// on its coordinates and the seed), colours, matrices and a small triangle-mesh builder.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

#import "SceneShared.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Deterministic randomness

typedef struct {
  uint64_t s;
} Rng;

static inline uint64_t SplitMix(uint64_t x) {
  x += 0x9E3779B97F4A7C15ull;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
  return x ^ (x >> 31);
}

/// A generator for cell (a, b) of layer `salt`: the same inputs always give the same numbers.
static inline Rng RngFor(uint32_t seed, int64_t a, int64_t b, uint32_t salt) {
  return (Rng){SplitMix(SplitMix(SplitMix(seed ^ ((uint64_t)salt << 32)) ^ (uint64_t)a) ^ (uint64_t)b)};
}

/// [0, 1)
static inline double Rand(Rng *r) {
  r->s = SplitMix(r->s);
  return (double)(r->s >> 11) / (double)(1ull << 53);
}

static inline double Range(Rng *r, double lo, double hi) {
  return lo + (hi - lo) * Rand(r);
}

#pragma mark - Colour and matrices

/// sRGB hex → linear RGB.
static inline simd_float3 Hex(uint32_t rgb) {
  return simd_make_float3(powf(((rgb >> 16) & 0xFF) / 255.0f, 2.2f), powf(((rgb >> 8) & 0xFF) / 255.0f, 2.2f), powf((rgb & 0xFF) / 255.0f, 2.2f));
}

static inline simd_float4x4 Perspective(float fovy, float aspect, float zNear, float zFar) {
  float ys = 1 / tanf(fovy * 0.5f), xs = ys / aspect, zs = zFar / (zNear - zFar);
  return (simd_float4x4){{{xs, 0, 0, 0}, {0, ys, 0, 0}, {0, 0, zs, -1}, {0, 0, zs * zNear, 0}}};
}

static inline simd_float4x4 LookDirection(simd_float3 eye, simd_float3 dir) {
  simd_float3 z = -simd_normalize(dir);
  simd_float3 x = simd_normalize(simd_cross((simd_float3){0, 1, 0}, z));
  simd_float3 y = simd_cross(z, x);
  return (simd_float4x4){{{x.x, y.x, z.x, 0}, {x.y, y.y, z.y, 0}, {x.z, y.z, z.z, 0}, {-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1}}};
}

#pragma mark - Meshes

/// Collects MeshVertex triangles: flat normals (or given ones), the current `material`.
@interface MeshBuilder : NSObject
- (instancetype)initWithSeed:(uint32_t)seed;
@property(nonatomic, readonly) NSMutableData *data;
@property(nonatomic, readonly) NSUInteger vertexCount;
@property(nonatomic) float material;
- (double)random;
- (double)randomFrom:(double)lo to:(double)hi;
- (void)triA:(simd_float3)a b:(simd_float3)b c:(simd_float3)c color:(simd_float3)color;
/// One vertex with everything given.
- (void)vertex:(simd_float3)p normal:(simd_float3)n color:(simd_float3)color uv:(simd_float2)uv;
/// A quad a-b-c-d (two triangles) with one normal and uv 0…1.
- (void)quadA:(simd_float3)a b:(simd_float3)b c:(simd_float3)c d:(simd_float3)d normal:(simd_float3)n color:(simd_float3)color;
/// A quad a-b-c-d with one normal and the given texture coordinates.
- (void)quadA:(simd_float3)a b:(simd_float3)b c:(simd_float3)c d:(simd_float3)d normal:(simd_float3)n color:(simd_float3)color
          uvA:(simd_float2)ta uvB:(simd_float2)tb uvC:(simd_float2)tc uvD:(simd_float2)td;
/// An axis-aligned box from `lo` to `hi`, outward normals.
- (void)boxFrom:(simd_float3)lo to:(simd_float3)hi color:(simd_float3)color;
/// A tapered tube from `a` (radius r0, colour c0) to `b` (r1, c1) with smooth normals; uv.x goes
/// around (0…1), uv.y along (0 at `a`, `vScale` × length at `b`). No caps.
- (void)tubeFrom:(simd_float3)a to:(simd_float3)b r0:(float)r0 r1:(float)r1 segments:(int)n color:(simd_float3)c0
         toColor:(simd_float3)c1 vScale:(float)vScale;
/// A flat card: from `base` along `along` for `length`, `width` wide across `across` (both unit);
/// uv.x 0…1 across, uv.y from v0 (base) to v1 (tip). `normal` is the lighting normal.
- (void)cardAt:(simd_float3)base along:(simd_float3)along across:(simd_float3)across length:(float)length width:(float)width
            v0:(float)v0 v1:(float)v1 normal:(simd_float3)normal color:(simd_float3)color;
/// A random unit vector.
- (simd_float3)randomDirection;
/// `color` scaled by 1 ± amount.
- (simd_float3)vary:(simd_float3)color by:(double)amount;
- (void)cylinderFrom:(float)y0 to:(float)y1 r0:(float)r0 r1:(float)r1 segments:(int)n color:(simd_float3)color;
- (void)coneFrom:(float)y0 height:(float)h radius:(float)r segments:(int)n color:(simd_float3)color jitter:(float)jitter;
- (void)icosahedronAt:(simd_float3)center radius:(simd_float3)r color:(simd_float3)color jitter:(float)jitter;
@end

/// A unit vector perpendicular to `n`.
static inline simd_float3 Perpendicular(simd_float3 n) {
  simd_float3 t = fabsf(n.y) < 0.9f ? (simd_float3){0, 1, 0} : (simd_float3){1, 0, 0};
  return simd_normalize(simd_cross(t, n));
}

/// A shared-storage buffer with `data`'s bytes, or nil when it's empty.
id<MTLBuffer> _Nullable SceneBuffer(id<MTLDevice> device, NSData *data);

/// An error in the WalkScape domain.
NSError *SceneError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
