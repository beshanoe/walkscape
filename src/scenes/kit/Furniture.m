#import "Furniture.h"

#import "SceneUtil.h"

NSData *BenchMesh(void) {
  MeshBuilder *m = [[MeshBuilder alloc] initWithSeed:1];
  m.material = 0;
  simd_float3 iron = Hex(0x253a2c), wood = Hex(0x6e4a2e);
  for (int s = -1; s <= 1; s += 2) {
    [m boxFrom:(simd_float3){s * 0.9f - 0.03f, 0, -0.25f} to:(simd_float3){s * 0.9f + 0.03f, 0.45f, 0.2f} color:iron];
    [m boxFrom:(simd_float3){s * 0.9f - 0.03f, 0.45f, -0.3f} to:(simd_float3){s * 0.9f + 0.03f, 0.85f, -0.24f} color:iron];
  }
  for (int i = 0; i < 4; i++) [m boxFrom:(simd_float3){-1.0f, 0.43f, -0.22f + i * 0.11f} to:(simd_float3){1.0f, 0.46f, -0.14f + i * 0.11f} color:wood];
  for (int i = 0; i < 3; i++) [m boxFrom:(simd_float3){-1.0f, 0.55f + i * 0.11f, -0.3f} to:(simd_float3){1.0f, 0.63f + i * 0.11f, -0.27f} color:wood];
  return m.data;
}
