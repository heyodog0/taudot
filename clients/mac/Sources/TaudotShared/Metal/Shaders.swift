// Metal shaders, compiled at runtime (SwiftPM has no .metal step without resources).
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float2 viewport; float4 clip; float clipRadius; };

struct RectInst { float4 rect; float4 color; float4 params; };   // params: kind, a, b, c
struct GlyphInst { float4 rect; float4 uv; float4 color; float4 flags; };

struct RectOut { float4 pos [[position]]; float4 color; float4 params; float4 rect; };
struct GlyphOut { float4 pos [[position]]; float2 uv; float4 color; float colorGlyph; };

constant float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };

float4 toNDC(float2 p, float2 vp) { return float4(p.x / vp.x * 2 - 1, 1 - p.y / vp.y * 2, 0, 1); }

float sdRoundRect(float2 p, float4 r, float radius) {
  float2 c = r.xy + r.zw * 0.5;
  float2 q = abs(p - c) - r.zw * 0.5 + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float clipCoverage(float2 p, constant Uniforms& u) {
  if (u.clipRadius <= 0) return 1;
  return clamp(0.5 - sdRoundRect(p, u.clip, u.clipRadius), 0.0, 1.0);
}

vertex RectOut rectVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant RectInst* inst [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
  RectInst r = inst[iid];
  float2 p = r.rect.xy + corners[vid] * r.rect.zw;
  RectOut o; o.pos = toNDC(p, u.viewport); o.color = r.color; o.params = r.params; o.rect = r.rect;
  return o;
}

fragment float4 rectFragment(RectOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
  float2 p = in.pos.xy;
  int kind = int(in.params.x);
  float a = 1;
  if (kind == 1) {            // rounded rect, radius a
    a = clamp(0.5 - sdRoundRect(p, in.rect, in.params.y), 0.0, 1.0);
  } else if (kind == 2) {     // shadow: rect inset by b, radius a, blur b
    float b = in.params.z;
    float4 inner = float4(in.rect.xy + b, in.rect.zw - 2 * b);
    float d = sdRoundRect(p, inner, in.params.y);
    a = 1 - smoothstep(-b * 0.5, b, d);
    a = a * a;
  } else if (kind == 3) {     // undercurl: thickness a, period b
    float t = in.params.y, period = in.params.z;
    float amp = max(in.rect.w * 0.5 - t * 0.5, 0.5);
    float cy = in.rect.y + in.rect.w * 0.5;
    float x = p.x - in.rect.x;
    float y = cy - amp * sin(x / period * 6.2831853);
    float slope = amp * 6.2831853 / period * cos(x / period * 6.2831853);
    float d = abs(p.y - y) / sqrt(1 + slope * slope);
    a = clamp(t * 0.5 + 0.5 - d, 0.0, 1.0);
  } else if (kind == 4) {     // dotted: thickness a
    float t = in.params.y;
    a = fmod(p.x - in.rect.x, 2 * t) < t ? 1 : 0;
  } else if (kind == 5) {     // dashed: thickness a
    float t = in.params.y;
    a = fmod(p.x - in.rect.x, 6 * t) < 4 * t ? 1 : 0;
  }
  a *= clipCoverage(p, u);
  return float4(in.color.rgb * in.color.a, in.color.a) * a;
}

vertex GlyphOut glyphVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant GlyphInst* inst [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
  GlyphInst g = inst[iid];
  float2 c = corners[vid];
  GlyphOut o;
  o.pos = toNDC(g.rect.xy + c * g.rect.zw, u.viewport);
  o.uv = g.uv.xy + c * g.uv.zw;
  o.color = g.color;
  o.colorGlyph = g.flags.x;
  return o;
}

fragment float4 glyphFragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
  constexpr sampler s(coord::pixel, filter::nearest);
  float4 t = atlas.sample(s, in.uv);
  float cov = clipCoverage(in.pos.xy, u);
  if (in.colorGlyph > 0.5) return t * in.color.a * cov;
  float a = t.a * in.color.a * cov;
  return float4(in.color.rgb * a, a);
}
"""
