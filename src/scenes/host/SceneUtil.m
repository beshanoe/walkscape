#import "SceneUtil.h"

@implementation MeshBuilder {
  Rng _rng;
}

- (instancetype)initWithSeed:(uint32_t)seed {
  if ((self = [super init])) {
    _data = [NSMutableData data];
    _rng = RngFor(seed, 0, 0, 7);
  }
  return self;
}

- (NSUInteger)vertexCount {
  return _data.length / sizeof(MeshVertex);
}

- (double)random {
  return Rand(&_rng);
}

- (double)randomFrom:(double)lo to:(double)hi {
  return Range(&_rng, lo, hi);
}

- (void)vertex:(simd_float3)p normal:(simd_float3)n color:(simd_float3)col uv:(simd_float2)uv {
  MeshVertex mv = {{p.x, p.y, p.z}, {n.x, n.y, n.z}, {col.x, col.y, col.z}, {uv.x, uv.y}, _material};
  [_data appendBytes:&mv length:sizeof mv];
}

- (void)triA:(simd_float3)a b:(simd_float3)b c:(simd_float3)c color:(simd_float3)col {
  simd_float3 n = simd_normalize(simd_cross(b - a, c - a));
  if (!simd_all(n == n)) n = (simd_float3){0, 1, 0};  // degenerate
  [self vertex:a normal:n color:col uv:(simd_float2){0, 0}];
  [self vertex:b normal:n color:col uv:(simd_float2){1, 0}];
  [self vertex:c normal:n color:col uv:(simd_float2){0, 1}];
}

- (void)quadA:(simd_float3)a b:(simd_float3)b c:(simd_float3)c d:(simd_float3)d normal:(simd_float3)n color:(simd_float3)col {
  [self vertex:a normal:n color:col uv:(simd_float2){0, 1}];
  [self vertex:b normal:n color:col uv:(simd_float2){1, 1}];
  [self vertex:c normal:n color:col uv:(simd_float2){1, 0}];
  [self vertex:a normal:n color:col uv:(simd_float2){0, 1}];
  [self vertex:c normal:n color:col uv:(simd_float2){1, 0}];
  [self vertex:d normal:n color:col uv:(simd_float2){0, 0}];
}

- (void)quadA:(simd_float3)a b:(simd_float3)b c:(simd_float3)c d:(simd_float3)d normal:(simd_float3)n color:(simd_float3)col
          uvA:(simd_float2)ta uvB:(simd_float2)tb uvC:(simd_float2)tc uvD:(simd_float2)td {
  [self vertex:a normal:n color:col uv:ta];
  [self vertex:b normal:n color:col uv:tb];
  [self vertex:c normal:n color:col uv:tc];
  [self vertex:a normal:n color:col uv:ta];
  [self vertex:c normal:n color:col uv:tc];
  [self vertex:d normal:n color:col uv:td];
}

- (void)boxFrom:(simd_float3)lo to:(simd_float3)hi color:(simd_float3)col {
  simd_float3 p[8];
  for (int i = 0; i < 8; i++) p[i] = (simd_float3){i & 1 ? hi.x : lo.x, i & 2 ? hi.y : lo.y, i & 4 ? hi.z : lo.z};
  [self quadA:p[0] b:p[1] c:p[3] d:p[2] normal:(simd_float3){0, 0, -1} color:col];  // -z
  [self quadA:p[5] b:p[4] c:p[6] d:p[7] normal:(simd_float3){0, 0, 1} color:col];   // +z
  [self quadA:p[4] b:p[0] c:p[2] d:p[6] normal:(simd_float3){-1, 0, 0} color:col];  // -x
  [self quadA:p[1] b:p[5] c:p[7] d:p[3] normal:(simd_float3){1, 0, 0} color:col];   // +x
  [self quadA:p[2] b:p[3] c:p[7] d:p[6] normal:(simd_float3){0, 1, 0} color:col];   // +y
  [self quadA:p[4] b:p[5] c:p[1] d:p[0] normal:(simd_float3){0, -1, 0} color:col];  // -y
}

- (simd_float3)randomDirection {
  float z = (float)Range(&_rng, -1, 1), a = (float)Range(&_rng, 0, 2 * M_PI), r = sqrtf(fmaxf(1 - z * z, 0));
  return (simd_float3){r * cosf(a), z, r * sinf(a)};
}

- (void)tubeFrom:(simd_float3)a to:(simd_float3)b r0:(float)r0 r1:(float)r1 segments:(int)n color:(simd_float3)c0
         toColor:(simd_float3)c1 vScale:(float)vScale {
  simd_float3 axis = b - a;
  float len = simd_length(axis);
  if (len < 1e-6f) return;
  simd_float3 w = axis / len, u = Perpendicular(w), v = simd_cross(w, u);
  float slope = (r0 - r1) / len;
  for (int i = 0; i < n; i++) {
    float a0 = 2 * (float)M_PI * i / n, a1 = 2 * (float)M_PI * (i + 1) / n;
    simd_float3 d0 = u * cosf(a0) + v * sinf(a0), d1 = u * cosf(a1) + v * sinf(a1);
    simd_float3 n0 = simd_normalize(d0 + w * slope), n1 = simd_normalize(d1 + w * slope);
    simd_float3 p00 = a + d0 * r0, p01 = b + d0 * r1, p10 = a + d1 * r0, p11 = b + d1 * r1;
    float u0 = (float)i / n, u1 = (float)(i + 1) / n, vt = len * vScale;
    [self vertex:p00 normal:n0 color:c0 uv:(simd_float2){u0, 0}];
    [self vertex:p01 normal:n0 color:c1 uv:(simd_float2){u0, vt}];
    [self vertex:p10 normal:n1 color:c0 uv:(simd_float2){u1, 0}];
    [self vertex:p10 normal:n1 color:c0 uv:(simd_float2){u1, 0}];
    [self vertex:p01 normal:n0 color:c1 uv:(simd_float2){u0, vt}];
    [self vertex:p11 normal:n1 color:c1 uv:(simd_float2){u1, vt}];
  }
}

- (void)cardAt:(simd_float3)base along:(simd_float3)along across:(simd_float3)across length:(float)length width:(float)width
            v0:(float)v0 v1:(float)v1 normal:(simd_float3)normal color:(simd_float3)color {
  simd_float3 h = across * (width * 0.5f), tip = base + along * length;
  simd_float3 p0 = base - h, p1 = base + h, p2 = tip + h, p3 = tip - h;
  [self vertex:p0 normal:normal color:color uv:(simd_float2){0, v0}];
  [self vertex:p1 normal:normal color:color uv:(simd_float2){1, v0}];
  [self vertex:p2 normal:normal color:color uv:(simd_float2){1, v1}];
  [self vertex:p0 normal:normal color:color uv:(simd_float2){0, v0}];
  [self vertex:p2 normal:normal color:color uv:(simd_float2){1, v1}];
  [self vertex:p3 normal:normal color:color uv:(simd_float2){0, v1}];
}

- (simd_float3)vary:(simd_float3)c by:(double)amount {
  return c * (float)(1.0 + (Rand(&_rng) - 0.5) * 2 * amount);
}

- (void)cylinderFrom:(float)y0 to:(float)y1 r0:(float)r0 r1:(float)r1 segments:(int)n color:(simd_float3)col {
  for (int i = 0; i < n; i++) {
    float a0 = 2 * M_PI * i / n, a1 = 2 * M_PI * (i + 1) / n;
    simd_float3 b0 = {r0 * cosf(a0), y0, r0 * sinf(a0)}, b1 = {r0 * cosf(a1), y0, r0 * sinf(a1)};
    simd_float3 t0 = {r1 * cosf(a0), y1, r1 * sinf(a0)}, t1 = {r1 * cosf(a1), y1, r1 * sinf(a1)};
    simd_float3 c = [self vary:col by:0.06];
    [self triA:b0 b:t0 c:b1 color:c];
    [self triA:b1 b:t0 c:t1 color:c];
  }
}

- (void)coneFrom:(float)y0 height:(float)h radius:(float)r segments:(int)n color:(simd_float3)col jitter:(float)jitter {
  simd_float3 apex = {(float)Range(&_rng, -jitter, jitter) * r, y0 + h, (float)Range(&_rng, -jitter, jitter) * r};
  simd_float3 center = {0, y0 + h * 0.08f, 0};
  float twist = (float)Rand(&_rng) * 6.28f;
  for (int i = 0; i < n; i++) {
    float a0 = twist + 2 * M_PI * i / n, a1 = twist + 2 * M_PI * (i + 1) / n;
    float j0 = 1 + (float)Range(&_rng, -jitter, jitter), j1 = j0;
    simd_float3 p0 = {r * j0 * cosf(a0), y0, r * j0 * sinf(a0)};
    simd_float3 p1 = {r * j1 * cosf(a1), y0, r * j1 * sinf(a1)};
    simd_float3 c = [self vary:col by:0.1];
    [self triA:p0 b:apex c:p1 color:c];
    [self triA:p1 b:center c:p0 color:c * 0.55f];  // underside, seen when looking up
  }
}

- (void)icosahedronAt:(simd_float3)center radius:(simd_float3)r color:(simd_float3)col jitter:(float)jitter {
  const float t = (1.0f + sqrtf(5.0f)) / 2.0f;
  simd_float3 v[12] = {{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0}, {0, -1, t}, {0, 1, t},
                       {0, -1, -t}, {0, 1, -t}, {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}};
  static const int f[20][3] = {{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11}, {1, 5, 9}, {5, 11, 4},
                               {11, 10, 2}, {10, 7, 6}, {7, 1, 8}, {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8},
                               {3, 8, 9}, {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1}};
  for (int i = 0; i < 12; i++) {
    v[i] = simd_normalize(v[i]) * (float)(1 + Range(&_rng, -jitter, jitter));
    v[i] = center + v[i] * r;
  }
  for (int i = 0; i < 20; i++) [self triA:v[f[i][0]] b:v[f[i][1]] c:v[f[i][2]] color:[self vary:col by:0.12]];
}

@end

id<MTLBuffer> SceneBuffer(id<MTLDevice> device, NSData *data) {
  return data.length ? [device newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared] : nil;
}

NSError *SceneError(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  return [NSError errorWithDomain:@"WalkScape" code:2 userInfo:@{NSLocalizedDescriptionKey : message}];
}
