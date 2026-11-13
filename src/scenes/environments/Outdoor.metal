// The outdoor environment's sky: gradient, sun disk and glow, a drifting cloud deck, stars,
// horizon haze. Drawn by OutdoorEnvironment after the scene, where the depth is still at the far
// plane. Part of the host's library (after SceneShared.h and Common.metal).

/// The full sky toward `dir`: gradient, sun disk and glow, clouds, stars, horizon haze.
static float3 skyColor(float3 dir, constant FrameUniforms &u) {
  float3 c = mix(u.skyHorizon, u.skyZenith, sqrt(saturate(dir.y)));
  float cosT = dot(dir, u.sunDir);
  float3 glow = u.sunColor * (0.5 * pow(saturate(cosT), 6.0) + 1.5 * pow(saturate(cosT), 64.0)) * 0.12 * u.sunDisk;
  float3 disk = u.sunColor * smoothstep(0.99985, 0.99993, cosT) * 20.0 * u.sunDisk;
  if (u.stars > 0 && dir.y > 0) {
    float2 cell = floor(dir.xz / (dir.y + 0.3) * 260.0);
    float star = step(0.9975, hash21(cell)) * hash21(cell + 3.1);
    c += star * u.stars * 0.25 * smoothstep(0.05, 0.3, dir.y);
  }
  if (dir.y > 0 && u.cloudCover > 0) {
    // A cloud deck: fbm on a plane, drifting; lit from the sun's side.
    float2 p = dir.xz / (dir.y + 0.08) * 1.6 + float2(u.camPos.x, u.camPos.z + u.originZ) * 0.0004 + u.time * float2(0.004, 0.0025);
    float n = fbm(p, 5);
    float n2 = fbm(p + u.sunDir.xz * 0.06, 5);
    float density = smoothstep(1.0 - u.cloudCover - 0.12, 1.0 - u.cloudCover + 0.38, n) * smoothstep(0.0, 0.18, dir.y);
    float lit = saturate(0.65 + (n - n2) * 5.0);
    float3 cloud = u.cloudColor * mix(0.72, 1.08, lit) * mix(0.9, 1.05, n) + u.sunColor * 0.12 * pow(saturate(cosT), 10.0) * u.sunDisk;
    c = mix(c, cloud, density);
    glow *= 1.0 - density * 0.8;
    disk *= 1.0 - density;
  }
  c += glow + disk;
  float haze = 1.0 - exp(-fogDepth(u.camPos, dir * 1800.0, u));
  return mix(c, fogColorToward(dir, u), haze);
}

// ---- sky pass ----

struct SkyOut {
  float4 position [[position]];
  float2 ndc;
};

vertex SkyOut sky_vs(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
  SkyOut o;
  o.position = float4(p, 1.0, 1.0);
  o.ndc = p;
  return o;
}

fragment float4 sky_fs(SkyOut in [[stage_in]], constant FrameUniforms &u [[buffer(kBufferFrame)]]) {
  float4 far = u.invViewProj * float4(in.ndc, 1.0, 1.0);
  float3 dir = normalize(far.xyz / far.w - u.camPos);
  return float4(skyColor(dir, u), 1.0);
}

