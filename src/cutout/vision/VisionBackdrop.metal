// VisionBackdrop.metal: the GPU half of VisionBackdropEngine (background replacement with public
// APIs). Vision's person mask is soft but only 512×384; these kernels turn it into a full-resolution
// matte that follows the camera's own edges and composite the camera over the new background, in
// the camera's 4:2:0 YUV. VisionBackdropShared.h is pasted above this file.
//
//   vb_to_rgb     camera → RGB for Vision (it converts 4:2:0 itself, slowly: 13 ms vs 8 at 1080p)
//   vb_prepare    camera → low-resolution YUV + Vision's mask (last frame's kept where nothing moved)
//   vb_stats_h/v  the guided filter's box sums → per low-res pixel a linear model alpha ≈ a·YUV + b
//                 and how much of the mask it explains, the local colours of the person and of the
//                 old background
//   vb_box_h/v    averages the linear models (the guided filter's second box)
//   vb_columns    per column: the mask's maximum and how much moved (the CPU places the crop)
//   vb_composite  per 2×2 pixels: alpha (Vision's mask, the colour model where it's sure), the
//                 person's own colour at the edges (old background and sharpening specks out)

constexpr sampler kLinear(filter::linear, address::clamp_to_edge, coord::normalized);

// Camera YUV → Y 0…1, U and V −0.5…0.5 (BT.709 either way; only the range differs).
static float3 decodeYUV(float y, float2 c, float videoRange) {
  if (videoRange > 0.5f) return float3((y - 16.0f / 255.0f) * (255.0f / 219.0f), (c - 128.0f / 255.0f) * (255.0f / 224.0f));
  return float3(y, c - 128.0f / 255.0f);
}
static float encodeY(float y, float videoRange) {
  y = saturate(y);
  return videoRange > 0.5f ? y * (219.0f / 255.0f) + 16.0f / 255.0f : y;
}
static float2 encodeC(float2 c, float videoRange) {
  c = clamp(c, -0.5f, 0.5f);
  return videoRange > 0.5f ? c * (224.0f / 255.0f) + 128.0f / 255.0f : saturate(c + 128.0f / 255.0f);
}

// Vision's mask at a camera uv (0 outside the part of the frame it covers).
static float maskAt(texture2d<float, access::sample> mask, float2 uv, float4 roi) {
  if (uv.x < roi.x || uv.x > roi.z || uv.y < roi.y || uv.y > roi.w) return 0;
  return mask.sample(kLinear, (uv - roi.xy) / (roi.zw - roi.xy)).r;
}

kernel void vb_to_rgb(texture2d<float, access::sample> camY [[texture(0)]],
                      texture2d<float, access::sample> camC [[texture(1)]],
                      texture2d<float, access::write> rgb [[texture(2)]],
                      constant VBParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
  float2 uv = (float2(gid) + 0.5f) / float2(rgb.get_width(), rgb.get_height());
  float3 yuv = decodeYUV(camY.sample(kLinear, uv).r, camC.sample(kLinear, uv).rg, p.camVideoRange);
  // BT.709
  float3 c = float3(yuv.x + 1.5748f * yuv.z, yuv.x - 0.1873f * yuv.y - 0.4681f * yuv.z, yuv.x + 1.8556f * yuv.y);
  rgb.write(float4(saturate(c), 1), gid);
}

kernel void vb_prepare(texture2d<float, access::read> camY [[texture(0)]],
                       texture2d<float, access::read> camC [[texture(1)]],
                       texture2d<float, access::sample> mask [[texture(2)]],
                       texture2d<float, access::read> previous [[texture(3)]],  // last frame's state
                       texture2d<float, access::write> guide [[texture(4)]],    // Y U V mask
                       texture2d<float, access::write> state [[texture(5)]],    // Y, mask, moved
                       constant VBParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.low.x || gid.y >= p.low.y) return;
  uint2 base = gid * kVBScale;
  float y = 0;
  for (uint j = 0; j < kVBScale; j++)
    for (uint i = 0; i < kVBScale; i++) y += camY.read(min(base + uint2(i, j), p.size - 1)).r;
  y /= kVBScale * kVBScale;
  float2 c = 0;
  uint2 chroma = p.size / 2;
  for (uint j = 0; j < kVBScale / 2; j++)
    for (uint i = 0; i < kVBScale / 2; i++) c += camC.read(min(base / 2 + uint2(i, j), chroma - 1)).rg;
  c /= (kVBScale / 2) * (kVBScale / 2);
  float3 yuv = decodeYUV(y, c, p.camVideoRange);

  float2 uv = (float2(gid) + 0.5f) / float2(p.low);
  float m = maskAt(mask, uv, p.roi);
  float moved = 0;
  if (p.hasPrevious) {
    // Where the picture didn't change, keep part of last frame's mask: steadier edges, no lag
    // where you move. The low-res luma's noise is a quarter of the camera's.
    float4 last = previous.read(gid);
    float change = abs(yuv.x - last.x);
    m = mix(m, last.y, p.temporal * (1 - smoothstep(0.012f, 0.05f, change)));
    moved = change > 0.04f ? 1 : 0;
  }
  guide.write(float4(yuv, m), gid);
  state.write(float4(yuv.x, m, moved, 0), gid);
}

// Horizontal box sums of the guided filter's terms: I (YUV), p (mask), I·p, I·Iᵀ, p² (s3.w).
kernel void vb_stats_h(texture2d<float, access::read> guide [[texture(0)]],
                       texture2d<float, access::write> s0 [[texture(1)]],
                       texture2d<float, access::write> s1 [[texture(2)]],
                       texture2d<float, access::write> s2 [[texture(3)]],
                       texture2d<float, access::write> s3 [[texture(4)]],
                       constant VBParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.low.x || gid.y >= p.low.y) return;
  int x0 = max(int(gid.x) - p.radius, 0), x1 = min(int(gid.x) + p.radius, int(p.low.x) - 1);
  float4 a0 = 0, a1 = 0, a2 = 0, a3 = 0;
  for (int x = x0; x <= x1; x++) {
    float4 v = guide.read(uint2(x, gid.y));
    float3 I = v.xyz;
    float m = v.w;
    a0 += v;
    a1.xyz += I * m;
    a2.xyz += I.x * I;
    a3 += float4(I.y * I.y, I.y * I.z, I.z * I.z, m * m);
  }
  s0.write(a0, gid);
  s1.write(a1, gid);
  s2.write(a2, gid);
  s3.write(a3, gid);
}

// Solves S·x = r for a symmetric 3×3 S = [[a b c] [b d e] [c e f]] (positive definite here).
static float3 solveSymmetric(float a, float b, float c, float d, float e, float f, float3 r) {
  float A = d * f - e * e, B = c * e - b * f, C = b * e - c * d;
  float D = a * f - c * c, E = b * c - a * e, F = a * d - b * b;
  float det = a * A + b * B + c * C;
  return float3(A * r.x + B * r.y + C * r.z, B * r.x + D * r.y + E * r.z, C * r.x + E * r.y + F * r.z) / det;
}

// Vertical box sums → means → the guided filter's linear model per pixel (He, Sun & Tang 2010):
// alpha ≈ a·I + b over the window, a = (Σ_I + ε)⁻¹ cov(I, p), b = mean(p) − a·mean(I); and R², the
// share of the mask's variance the colours explain.
kernel void vb_stats_v(texture2d<float, access::read> s0 [[texture(0)]],
                       texture2d<float, access::read> s1 [[texture(1)]],
                       texture2d<float, access::read> s2 [[texture(2)]],
                       texture2d<float, access::read> s3 [[texture(3)]],
                       texture2d<float, access::write> coef [[texture(4)]],    // a (YUV), b
                       texture2d<float, access::write> fit [[texture(5)]],     // R² (how much of the mask colour explains)
                       texture2d<float, access::write> person [[texture(6)]],  // the person's local colour
                       texture2d<float, access::write> behind [[texture(7)]],  // the old background's
                       constant VBParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.low.x || gid.y >= p.low.y) return;
  int x0 = max(int(gid.x) - p.radius, 0), x1 = min(int(gid.x) + p.radius, int(p.low.x) - 1);
  int y0 = max(int(gid.y) - p.radius, 0), y1 = min(int(gid.y) + p.radius, int(p.low.y) - 1);
  float4 a0 = 0, a1 = 0, a2 = 0, a3 = 0;
  for (int y = y0; y <= y1; y++) {
    uint2 q = uint2(gid.x, y);
    a0 += s0.read(q);
    a1 += s1.read(q);
    a2 += s2.read(q);
    a3 += s3.read(q);
  }
  float p2 = a3.w;
  float n = float((x1 - x0 + 1) * (y1 - y0 + 1));
  float3 meanI = a0.xyz / n;
  float meanP = a0.w / n;
  float3 meanIp = a1.xyz / n;
  float3 cov = meanIp - meanI * meanP;
  float3 ii = a2.xyz / n - meanI.x * meanI;                                    // YY YU YV
  float3 cc = a3.xyz / n - float3(meanI.y * meanI.y, meanI.y * meanI.z, meanI.z * meanI.z);  // UU UV VV
  float3 a = solveSymmetric(ii.x + p.eps, ii.y, ii.z, cc.x + p.eps, cc.y, cc.z + p.eps, cov);
  float b = meanP - dot(a, meanI);
  float varP = p2 / n - meanP * meanP;
  float explained = varP > 1e-4f ? saturate(dot(a, cov) / varP) : 0;
  coef.write(float4(a, b), gid);
  fit.write(float4(explained, 0, 0, 0), gid);
  // Mask-weighted local means: the person's colour, and (1 − mask)-weighted the old background's.
  person.write(float4(meanIp / max(meanP, 1e-4f), 0), gid);
  behind.write(float4((meanI - meanIp) / max(1 - meanP, 1e-4f), 0), gid);
}

// Box average of an RGBA texture (the linear models), horizontal then vertical.
kernel void vb_box_h(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant VBParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.low.x || gid.y >= p.low.y) return;
  int x0 = max(int(gid.x) - p.radius, 0), x1 = min(int(gid.x) + p.radius, int(p.low.x) - 1);
  float4 sum = 0;
  for (int x = x0; x <= x1; x++) sum += src.read(uint2(x, gid.y));
  dst.write(sum / float(x1 - x0 + 1), gid);
}

kernel void vb_box_v(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant VBParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.low.x || gid.y >= p.low.y) return;
  int y0 = max(int(gid.y) - p.radius, 0), y1 = min(int(gid.y) + p.radius, int(p.low.y) - 1);
  float4 sum = 0;
  for (int y = y0; y <= y1; y++) sum += src.read(uint2(gid.x, y));
  dst.write(sum / float(y1 - y0 + 1), gid);
}

// Per low-res column: the mask's maximum and the share of pixels that moved since last frame.
kernel void vb_columns(texture2d<float, access::read> state [[texture(0)]],
                       device float2 *columns [[buffer(1)]],
                       constant VBParams &p [[buffer(0)]],
                       uint gid [[thread_position_in_grid]]) {
  if (gid >= p.low.x) return;
  float most = 0, moved = 0;
  for (uint y = 0; y < p.low.y; y++) {
    float4 s = state.read(uint2(gid, y));
    most = max(most, s.y);
    moved += s.z;
  }
  columns[gid] = float2(most, moved / float(p.low.y));
}

kernel void vb_composite(texture2d<float, access::read> camY [[texture(0)]],
                         texture2d<float, access::sample> camC [[texture(1)]],
                         texture2d<float, access::sample> bgY [[texture(2)]],
                         texture2d<float, access::sample> bgC [[texture(3)]],
                         texture2d<float, access::sample> mask [[texture(4)]],
                         texture2d<float, access::sample> coef [[texture(5)]],
                         texture2d<float, access::sample> fit [[texture(6)]],
                         texture2d<float, access::sample> person [[texture(7)]],
                         texture2d<float, access::sample> behind [[texture(8)]],
                         texture2d<float, access::write> outY [[texture(9)]],
                         texture2d<float, access::write> outC [[texture(10)]],
                         texture2d<float, access::write> matte [[texture(11)]],
                         constant VBParams &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
  uint2 chroma = p.size / 2;
  if (gid.x >= chroma.x || gid.y >= chroma.y) return;
  // The 4×4 luma around this 2×2 block: alpha is evaluated on a [1 2 1]² blur of the camera's
  // luma, so its noise doesn't shimmer along the edges (the output keeps the sharp pixels).
  float lumaAround[4][4];
  for (int j = 0; j < 4; j++)
    for (int i = 0; i < 4; i++) lumaAround[j][i] = camY.read(uint2(clamp(int2(gid * 2) + int2(i - 1, j - 1), int2(0), int2(p.size) - 1))).r;
  float2 uvSum = 0;
  for (uint k = 0; k < 4; k++) {
    uint2 pix = gid * 2 + uint2(k & 1, k >> 1);
    float2 uv = (float2(pix) + 0.5f) / float2(p.size);
    // Chroma interpolated per pixel: edges against the old background are often colour edges,
    // and half-resolution chroma would make alpha step every 2 pixels.
    uint bx = k & 1, by = k >> 1;
    float2 chromaHere = camC.sample(kLinear, uv).rg;
    float3 C = decodeYUV(lumaAround[by + 1][bx + 1], chromaHere, p.camVideoRange);
    float smooth = 0;
    for (uint j = 0; j < 3; j++)
      for (uint i = 0; i < 3; i++) smooth += lumaAround[by + j][bx + i] * float((1 + (i & 1)) * (1 + (j & 1)));
    float3 G = decodeYUV(smooth / 16, chromaHere, p.camVideoRange);  // the guide for alpha
    float2 bgUV = uv * p.bgScale + p.bgOffset;
    float3 B = decodeYUV(bgY.sample(kLinear, bgUV).r, bgC.sample(kLinear, bgUV).rg, p.bgVideoRange);
    float alpha;
    float3 out;
    if (p.refine) {
      float4 ab = coef.sample(kLinear, uv);
      // The colour model's alpha may only differ from Vision's mask near its edge: between the
      // mask's min within bandRadius and its max within half that (sampled at full resolution, so
      // the band's own edges are smooth). In further than out: outward, dark things next to you
      // (a wardrobe's door gap next to a dark shirt) would grow out of you as spikes.
      float m = maskAt(mask, uv, p.roi);
      float lo = m, hi = m;
      for (int t = 0; t < 8; t++) {
        float2 dir = float2(cos(float(t) * (M_PI_F / 4)), sin(float(t) * (M_PI_F / 4))) * p.bandRadius / float2(p.size);
        lo = min(lo, maskAt(mask, uv + dir, p.roi));
        hi = max(hi, maskAt(mask, uv + dir * 0.5f, p.roi));
      }
      float guided = saturate(clamp(dot(ab.xyz, G) + ab.w, lo, hi));
      // Vision's mask is crisp and well placed; the colour model takes over only where the
      // person's and the old background's colours are clearly apart and explain the mask (a dark
      // shirt against a white wall, hair against the sky). Where you and the room look alike (a
      // bald head against a pale wall) it would only blur the edge.
      float3 personC = person.sample(kLinear, uv).xyz;
      float3 behindC = behind.sample(kLinear, uv).xyz;
      float contrast = length((personC - behindC) * float3(1, 2, 2));  // chroma's range is smaller
      float useColour = smoothstep(p.explainedFrom, p.explainedTo, fit.sample(kLinear, uv).x) * smoothstep(p.contrastFrom, p.contrastTo, contrast);
      // Two alphas, as Apple's spill correction does: the colour model's follows the camera's own
      // (soft) edge and says how much of each camera pixel is the person; the composite uses the
      // same edge made crisper. So the camera's soft fringe (a dark shirt lit up by the white wall
      // behind it) turns back into shirt instead of letting the new background through.
      float alphaColour = mix(m, guided, useColour);
      alpha = mix(m, saturate((guided - 0.5f) * p.edgeSharpen + 0.5f), useColour);
      // The person's colour at the edge: C = α·F + (1 − α)·B_old, so take the old background out
      // where alpha is high enough to trust it; the person's local colour where it's low. Near the
      // edge, from the slightly blurred camera: its sharpening leaves single dark or bright pixels.
      float3 Cedge = mix(G, C, smoothstep(0.9f, 1.0f, lo));
      float3 unmixed = clamp((Cedge - (1 - alphaColour) * behindC) / max(alphaColour, 0.05f), float3(0, -0.5f, -0.5f), float3(1, 0.5f, 0.5f));
      float3 F = mix(personC, unmixed, smoothstep(0.3f, 0.7f, alphaColour));
      out = alpha * F + (1 - alpha) * B;
    } else {
      alpha = maskAt(mask, uv, p.roi);
      out = mix(B, C, alpha);
    }
    outY.write(float4(encodeY(out.x, p.camVideoRange)), pix);
    uvSum += out.yz;
    if (p.writeMatte) matte.write(float4(alpha), pix);
  }
  outC.write(float4(encodeC(uvSum / 4, p.camVideoRange), 0, 0), gid);
}
