// Forest road: the ground with its path. The trees and undergrowth are drawn by the kit's plant
// pipeline (Plants.metal). Compiled after SceneShared.h, Common.metal, Plants.h, Plants.metal and
// ForestScene.h. Keep pathX/groundHeight in sync with ForestScene.m (PathX, GroundHeight).

static float pathX(float z, float4 p) {
  return p.x * sin(z / p.y) + p.z * sin(z / p.w + 1.3);
}

static float groundHeight(float x, float z, constant ForestUniforms &f) {
  float hills = 0.8 * sin(x * 0.043 + 1.1) * sin(z * 0.037) + 0.5 * sin(x * 0.091 + z * 0.063) + 0.3 * sin(z * 0.13 - x * 0.05);
  float d = abs(x - pathX(z, f.path));
  return hills * f.hills * smoothstep(5.0, 18.0, d);
}

// ---- ground ----

struct GroundOut {
  float4 position [[position]];
  float3 world;  // relative to origin
  float3 normal;
};

vertex GroundOut ground_vs(uint vid [[vertex_id]], const device float2 *grid [[buffer(kBufferVertices)]],
                           constant FrameUniforms &u [[buffer(kBufferFrame)]], constant float2 &offset [[buffer(kBufferInstances)]],
                           constant ForestUniforms &f [[buffer(kBufferScene)]]) {
  float2 xz = grid[vid] + offset;
  float zAbs = xz.y + u.originZ;
  GroundOut o;
  o.world = float3(xz.x, groundHeight(xz.x, zAbs, f), xz.y);
  o.position = u.viewProj * float4(o.world, 1.0);
  float e = 0.5;
  float dx = groundHeight(xz.x + e, zAbs, f) - groundHeight(xz.x - e, zAbs, f);
  float dz = groundHeight(xz.x, zAbs + e, f) - groundHeight(xz.x, zAbs - e, f);
  o.normal = normalize(float3(-dx, 2 * e, -dz));
  return o;
}

fragment float4 ground_fs(GroundOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]],
                          constant ForestUniforms &f [[buffer(kBufferScene)]], depth2d_array<float> shadowMap [[texture(kTextureShadow)]]) {
  float zAbs = in.world.z + u.originZ;
  float2 p = float2(in.world.x, zAbs);
  float d = abs(in.world.x - pathX(zAbs, f.path));
  float detail = 1.0 - smoothstep(20.0, 60.0, length(in.world - u.camPos));  // fine noise fades with distance
  float macro = fbm(p * 0.05, 3);
  float n1 = valueNoise(p * 0.45), n2 = valueNoise(p * 2.3), n3 = mix(0.5, valueNoise(p * 9.0), detail);

  // Forest floor: living cover and litter in patches; darker under the canopy away from the path.
  float litter = smoothstep(0.35, 0.65, macro + (n1 - 0.5) * 0.4);
  float3 floorC = mix(f.floorA.rgb, f.floorB.rgb, litter) * (0.8 + 0.35 * n2) * (0.9 + 0.2 * n3);
  floorC *= 1.0 - smoothstep(2.0, 7.0, d - f.roadHalfWidth) * 0.3;

  // The path.
  float hw = f.roadHalfWidth;
  float wobble = ((n1 - 0.5) * 0.5 + (n2 - 0.5) * 0.25) * min(hw, 1.0) * 0.6;
  float onPath = 1.0 - smoothstep(hw - 0.15, hw + 0.25, d + wobble);
  float3 pathC;
  float rut = 0, height = n2 * 0.02 * detail + n3 * 0.006;
  if (f.pathType < 0.5) {  // forest road: two wheel ruts, grass down the middle
    rut = exp(-pow((d - hw * 0.55) / (hw * 0.17), 2.0));
    float middle = 1.0 - smoothstep(hw * 0.12, hw * 0.3, d + (n2 - 0.5) * 0.15);
    float3 soil = float3(0.20, 0.15, 0.10) * (0.8 + 0.4 * n2) * (0.9 + 0.2 * n3);
    pathC = mix(soil, float3(0.27, 0.21, 0.15) * (0.85 + 0.3 * n2), rut);
    pathC = mix(pathC, f.floorA.rgb * (0.8 + 0.4 * n2), middle * 0.85);
    height -= rut * 0.03;
  } else if (f.pathType < 1.5) {  // trail: dark soil, roots across, fallen leaves
    float3 soil = float3(0.13, 0.095, 0.065) * (0.8 + 0.4 * n2);
    float roots = smoothstep(0.035, 0.0, abs(valueNoise(float2(p.x * 1.2 + p.y * 0.3, p.y * 0.35)) - 0.5)) * detail;
    pathC = mix(soil, f.floorB.rgb * 0.9, smoothstep(0.55, 0.8, n2) * 0.6);
    pathC = mix(pathC, float3(0.09, 0.065, 0.045), roots * 0.7);
    rut = 1.0 - smoothstep(0.0, hw, d);
    height += roots * 0.02;
  } else {  // gravel
    float stones = mix(0.5, valueNoise(p * 28.0), detail);
    pathC = float3(0.29, 0.27, 0.24) * (0.78 + 0.44 * stones) * (0.9 + 0.2 * n2);
    rut = exp(-pow((d - hw * 0.5) / (hw * 0.2), 2.0)) * 0.5;
    pathC *= 1.0 - rut * 0.12;
    height += stones * 0.01 * detail;
  }
  float3 albedo = mix(floorC, pathC, onPath);
  if (f.snow > 0.5) {  // snow, trodden and dirtier in the ruts
    float3 snow = float3(0.82, 0.85, 0.9) * (0.93 + 0.07 * n2);
    albedo = mix(snow, albedo * 0.6 + snow * 0.4, onPath * rut * 0.5);
    height = n2 * 0.01;
  }

  Surface s = makeSurface(albedo, bump(normalize(in.normal), in.world, height));
  float wet = u.wetness * (1.0 - f.snow);
  if (wet > 0) {  // darker soil, a sheen, and puddles in the ruts and hollows of the path
    float puddle = onPath * smoothstep(0.6, 0.7, n1 * 0.55 + rut * 0.45 + (n3 - 0.5) * 0.1);
    s.albedo *= (1.0 - 0.4 * wet) * (1.0 - 0.5 * puddle);
    s.specular = 0.02;
    s.roughness = mix(0.8, 0.04, puddle * wet);
    s.normal = normalize(mix(s.normal, float3(0, 1, 0), puddle));
  }
  float shadow = shadowAt(in.world, s.normal, u, shadowMap);
  return float4(shadeSurface(u, in.world, s, shadow), 1.0);
}
