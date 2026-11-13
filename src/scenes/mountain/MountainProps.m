#import "MountainProps.h"

#import "Plants.h"
#import "SceneUtil.h"

static simd_float3 V(double x, double y, double z) {
  return simd_make_float3((float)x, (float)y, (float)z);
}

NSData *MountainFlowerMesh(int kind) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:700 + (uint32_t)kind];
  static const uint32_t petals[kMountainFlowers] = {0xf6ce18, 0xf2f0e6, 0x7e58be, 0xd8508a};
  static const uint32_t hearts[kMountainFlowers] = {0xe09a10, 0xe8c020, 0xe8d8f0, 0xf0a0b8};
  simd_float3 stem = Hex(0x5a8030), leaf = Hex(0x6a9434);
  m.material = 0;
  int heads = kind == 3 ? 9 : 6;
  for (int i = 0; i < heads; i++) {
    double a = [m random] * 2 * M_PI, reach = [m randomFrom:0.05 to:0.5], tall = [m randomFrom:0.55 to:1.0];
    simd_float3 base = V(cos(a) * reach * 0.4, 0, sin(a) * reach * 0.4), top = V(cos(a) * reach, tall, sin(a) * reach);
    [m tubeFrom:base to:top r0:0.014f r1:0.009f segments:3 color:stem toColor:stem vScale:1];
    // The head: a small fan of petals tilted toward the sky and a little outward.
    simd_float3 up = simd_normalize(V(cos(a) * 0.35, 1, sin(a) * 0.35)), side = Perpendicular(up), fwd = simd_cross(up, side);
    float r = (float)[m randomFrom:0.07 to:0.11] * (kind == 3 ? 0.8f : 1);
    int n = kind == 2 ? 5 : 7;
    simd_float3 petal = Hex(petals[kind]) * (float)[m randomFrom:0.85 to:1.1], heart = Hex(hearts[kind]);
    for (int k = 0; k < n; k++) {
      float t0 = (float)(k * 2 * M_PI / n), t1 = (float)((k + 1) * 2 * M_PI / n);
      simd_float3 p0 = top + (side * cosf(t0) + fwd * sinf(t0)) * r + up * 0.02f, p1 = top + (side * cosf(t1) + fwd * sinf(t1)) * r + up * 0.02f;
      [m vertex:top normal:up color:heart uv:simd_make_float2(0, 0)];
      [m vertex:p0 normal:up color:petal uv:simd_make_float2(0, 0)];
      [m vertex:p1 normal:up color:petal uv:simd_make_float2(0, 0)];
    }
  }
  for (int i = 0; i < 5; i++) {  // leaves at the foot
    double a = [m random] * 2 * M_PI, len = [m randomFrom:0.25 to:0.5];
    simd_float3 out = V(cos(a), 0.5, sin(a)), across = V(-sin(a), 0, cos(a));
    simd_float3 tip = out * (float)len, n = simd_normalize(V(cos(a) * -0.4, 1, sin(a) * -0.4));
    [m vertex:across * 0.045f normal:n color:leaf * 0.8f uv:simd_make_float2(0, 0)];
    [m vertex:across * -0.045f normal:n color:leaf * 0.8f uv:simd_make_float2(0, 0)];
    [m vertex:tip normal:n color:leaf uv:simd_make_float2(0, 0)];
  }
  return m.data;
}

/// A subdivided icosahedron pushed into a block: faces flattened toward a few planes, so that it
/// breaks like bedded limestone and not like a potato.
static void Lump(MeshBuilder *m, simd_float3 center, simd_float3 radius, int kind, float turn) {
  const float t = (1.0f + sqrtf(5.0f)) / 2.0f;
  simd_float3 v[12] = {{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0}, {0, -1, t}, {0, 1, t},
                       {0, -1, -t}, {0, 1, -t}, {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}};
  static const int f[20][3] = {{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11}, {1, 5, 9}, {5, 11, 4},
                               {11, 10, 2}, {10, 7, 6}, {7, 1, 8}, {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8},
                               {3, 8, 9}, {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1}};
  float cs = cosf(turn), sn = sinf(turn);
  simd_float3 (^shape)(simd_float3) = ^simd_float3(simd_float3 dir) {
    dir = simd_normalize(dir);
    dir = (simd_float3){cs * dir.x - sn * dir.z, dir.y, sn * dir.x + cs * dir.z};
    // Toward a cube (the largest component wins), by an amount that varies around the stone.
    float big = fmaxf(fmaxf(fabsf(dir.x), fabsf(dir.y)), fabsf(dir.z));
    float box = 0.3f + 0.2f * sinf(dir.x * 3.1f + kind * 1.7f + turn);
    simd_float3 p = dir * (1 - box + box * 0.82f / big);
    p *= 1 + 0.1f * sinf(dir.x * 6.3f + dir.z * 4.1f + kind) + 0.07f * sinf(dir.y * 8.0f - dir.x * 5.0f + turn);
    if (kind == 2) p.xz *= 1 - 0.45f * fmaxf(p.y, 0);  // pointed
    return center + p * radius;
  };
  // Two subdivisions, normals from the shape itself: worn, rounded edges.
  simd_float3 (^normalAt)(simd_float3) = ^simd_float3(simd_float3 dir) {
    dir = simd_normalize(dir);
    simd_float3 a = Perpendicular(dir), b = simd_cross(dir, a);
    simd_float3 p = shape(dir), n = simd_cross(shape(dir + a * 0.12f) - p, shape(dir + b * 0.12f) - p);
    n = simd_normalize(n);
    return simd_dot(n, p - center) < 0 ? -n : n;
  };
  simd_float3 color = {1, 1, 1};
  for (int i = 0; i < 20; i++) {
    simd_float3 a = v[f[i][0]], b = v[f[i][1]], c = v[f[i][2]];
    simd_float3 ab = (a + b) / 2, bc = (b + c) / 2, ca = (c + a) / 2;
    simd_float3 tris[4][3] = {{a, ab, ca}, {ab, b, bc}, {ca, bc, c}, {ab, bc, ca}};
    for (int k = 0; k < 4; k++) {
      simd_float3 p = tris[k][0], q = tris[k][1], r = tris[k][2];
      simd_float3 pq = (p + q) / 2, qr = (q + r) / 2, rp = (r + p) / 2;
      simd_float3 sub[4][3] = {{p, pq, rp}, {pq, q, qr}, {rp, qr, r}, {pq, qr, rp}};
      for (int s = 0; s < 4; s++) {
        for (int j = 0; j < 3; j++) [m vertex:shape(sub[s][j]) normal:normalAt(sub[s][j]) color:color uv:simd_make_float2(0, 0)];
      }
    }
  }
}

NSData *MountainStoneMesh(int kind) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:720 + (uint32_t)kind];
  m.material = kMaterialRock;
  static const simd_float3 radii[kMountainStones] = {{0.62f, 0.5f, 0.52f}, {0.85f, 0.32f, 0.6f}, {0.5f, 0.55f, 0.45f}};
  simd_float3 r = radii[kind % kMountainStones];
  Lump(m, V(0, r.y * 0.9, 0), r, kind, 0.4f * kind);
  return m.data;
}

NSData *MountainDwarfPineMesh(int kind) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:740 + (uint32_t)kind];
  int limbs = kind == 0 ? 7 : 5;
  for (int i = 0; i < limbs; i++) {
    double a = i * 2 * M_PI / limbs + [m randomFrom:-0.3 to:0.3], reach = [m randomFrom:0.45 to:0.95];
    // A limb creeps out along the ground and turns up at its end.
    simd_float3 knee = V(cos(a) * reach * 0.6, 0.12, sin(a) * reach * 0.6), tip = V(cos(a) * reach, [m randomFrom:0.45 to:0.85], sin(a) * reach);
    m.material = kMaterialBark;
    [m tubeFrom:V(0, 0, 0) to:knee r0:0.03f r1:0.022f segments:5 color:Hex(0x3c342e) toColor:Hex(0x4a3e34) vScale:8];
    [m tubeFrom:knee to:tip r0:0.022f r1:0.008f segments:5 color:Hex(0x4a3e34) toColor:Hex(0x5a4638) vScale:8];
    m.material = kMaterialCard + kCellPine;
    PlantCrown(m, tip * 0.92f, V(0.3, 0.26, 0.3), 16, 0.2f, 0.1f);
    PlantCrown(m, (knee + tip) * 0.5f + V(0, 0.08, 0), V(0.24, 0.2, 0.24), 9, 0.19f, 0.1f);
  }
  m.material = kMaterialCard + kCellPine;
  PlantCrown(m, V(0, 0.55, 0), V(0.4, 0.4, 0.4), 22, 0.22f, 0.1f);
  return m.data;
}

NSData *MountainCairnMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:760];
  m.material = kMaterialRock;
  float y = 0;
  for (int i = 0; i < 7; i++) {
    float w = 0.52f * (1 - i / 8.5f), h = 0.085f * (1 - i * 0.05f);
    simd_float3 c = V([m randomFrom:-0.05 to:0.05] * (1 - i / 7.0), y + h, [m randomFrom:-0.05 to:0.05] * (1 - i / 7.0));
    Lump(m, c, V(w * [m randomFrom:0.85 to:1.1], h, w * [m randomFrom:0.75 to:1.0]), 1, (float)[m randomFrom:0 to:6]);
    y += h * 1.55f;
  }
  Lump(m, V(0, y + 0.05, 0), V(0.09, 0.08, 0.08), 2, 1);
  return m.data;
}

NSData *MountainSignMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:770];
  m.material = 0;
  simd_float3 wood = Hex(0x74604a), white = Hex(0xe6e2d6), red = Hex(0xb02a22), yellow = Hex(0xe0b020);
  [m boxFrom:V(-0.045, 0, -0.045) to:V(0.045, 2.05, 0.045) color:wood];
  [m boxFrom:V(-0.052, 2.05, -0.052) to:V(0.052, 2.08, 0.052) color:wood * 0.7f];
  // The waymark painted round the post: red, white, red.
  for (int k = 0; k < 3; k++) {
    [m boxFrom:V(-0.048, 1.12 + 0.06 * k, -0.048) to:V(0.048, 1.18 + 0.06 * k, 0.048) color:k == 1 ? white : red];
  }
  // Two plates pointing along the trail, one each way: a white board with a red tip.
  for (int k = 0; k < 2; k++) {
    float y = 1.86f - 0.2f * k, dir = k == 0 ? 1 : -1, z = 0.05f;
    [m boxFrom:V(dir > 0 ? -0.1 : -0.56, y - 0.065, z) to:V(dir > 0 ? 0.56 : 0.1, y + 0.065, z + 0.018) color:k == 0 ? white : yellow];
    simd_float3 a = V(dir * 0.56, y - 0.065, z), b = V(dir * 0.56, y + 0.065, z), c = V(dir * 0.68, y, z);
    simd_float3 a2 = a + V(0, 0, 0.018), b2 = b + V(0, 0, 0.018), c2 = c + V(0, 0, 0.018);
    [m triA:a2 b:c2 c:b2 color:red];
    [m triA:a b:b c:c color:red];
    [m quadA:a b:c c:c2 d:a2 normal:V(0, -1, 0) color:red];
    [m quadA:c b:b c:b2 d:c2 normal:V(0, 1, 0) color:red];
    // Lettering: a few dark bars.
    for (int l = 0; l < 4; l++) {
      float x0 = dir * (0.0f + 0.11f * l) - (dir > 0 ? 0 : 0.08f);
      [m boxFrom:V(x0, y - 0.012 + 0.03 * (l % 2), z + 0.018) to:V(x0 + 0.08, y + 0.012 + 0.03 * (l % 2), z + 0.02) color:Hex(0x2a2a2a)];
    }
  }
  return m.data;
}

NSData *MountainCrossMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:780];
  m.material = 0;
  simd_float3 wood = Hex(0x6e5a48);
  [m boxFrom:V(-0.07, 0, -0.07) to:V(0.07, 3.2, 0.07) color:wood];
  [m boxFrom:V(-0.75, 2.3, -0.06) to:V(0.75, 2.44, 0.06) color:wood * 0.92f];
  m.material = kMaterialRock;
  for (int i = 0; i < 9; i++) {
    double a = i * 0.7, r = 0.18 + 0.3 * [m random];
    Lump(m, V(cos(a) * r, 0.1 + 0.12 * [m random], sin(a) * r), V(0.2, 0.12, 0.17), i % 3, (float)a);
  }
  return m.data;
}
