#include <metal_stdlib>
using namespace metal;

// ─── Shared Types ───────────────────────────────────────────────────

struct WaveformUniforms {
    float2 viewportSize;     // (width, height)
    float visibleStart;      // normalized 0-1 start of visible bucket range
    float visibleEnd;        // normalized 0-1 end of visible bucket range
    float centerY;           // vertical center in pixels
    float scale;             // amplitude scale (0.9)
    float playheadX;         // playhead x position in pixels (-1 if hidden)
    float loopStartX;        // loop start x (-1 if no loop)
    float loopEndX;          // loop end x (-1 if no loop)
    int totalBuckets;        // bucket count for current LOD level
    int isStereo;            // 1 = stereo mode
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// ─── Waveform Band Rendering ────────────────────────────────────────
// Each band (low/mid/high) is rendered as a triangle strip.
// Vertex pairs: (x, centerY - amp) and (x, centerY + amp) for each pixel.

struct BandVertex {
    float amplitude;  // Band amplitude at this bucket
};

struct BandUniforms {
    float4 bandColor;        // RGBA color for this band
    float2 viewportSize;
    float visibleStart;      // bucket index (fractional) of visible start
    float visibleEnd;        // bucket index (fractional) of visible end
    float centerY;
    float halfHeight;        // half the rendering height (centerY for mono, quarterH for stereo)
    float scale;
    int totalBuckets;
    int useAdditive;         // 1 = additive blending
};

vertex VertexOut waveformBandVertex(
    uint vertexID [[vertex_id]],
    const device float* amplitudes [[buffer(0)]],
    constant BandUniforms& uniforms [[buffer(1)]]
) {
    // Each pair of vertices forms top/bottom of the waveform at one x position
    uint pixelX = vertexID / 2;
    bool isBottom = (vertexID % 2) == 1;

    float viewWidth = uniforms.viewportSize.x;
    float t = float(pixelX) / viewWidth;

    // Map pixel to fractional bucket index with linear interpolation
    float bucketF = uniforms.visibleStart + t * (uniforms.visibleEnd - uniforms.visibleStart);
    int idx0 = clamp(int(bucketF), 0, uniforms.totalBuckets - 1);
    int idx1 = clamp(idx0 + 1, 0, uniforms.totalBuckets - 1);
    float frac = bucketF - float(idx0);

    // Linear interpolation between adjacent buckets
    float amp = mix(amplitudes[idx0], amplitudes[idx1], frac);

    float x = (float(pixelX) / viewWidth) * 2.0 - 1.0;  // NDC
    float yOffset = amp * uniforms.halfHeight * uniforms.scale;
    float y;
    if (isBottom) {
        y = uniforms.centerY + yOffset;
    } else {
        y = uniforms.centerY - yOffset;
    }
    // Convert y from pixels to NDC
    float yNDC = 1.0 - (y / uniforms.viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(x, yNDC, 0.0, 1.0);
    out.color = uniforms.bandColor;
    return out;
}

fragment float4 waveformBandFragment(VertexOut in [[stage_in]]) {
    return in.color;
}

// ─── Line Rendering (grid, playhead, slice markers, loop borders) ───

struct LineVertex {
    float2 position;  // in pixels
    float4 color;
};

vertex VertexOut lineVertex(
    uint vertexID [[vertex_id]],
    const device LineVertex* vertices [[buffer(0)]],
    constant float2& viewportSize [[buffer(1)]]
) {
    LineVertex v = vertices[vertexID];
    float x = (v.position.x / viewportSize.x) * 2.0 - 1.0;
    float y = 1.0 - (v.position.y / viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(x, y, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 lineFragment(VertexOut in [[stage_in]]) {
    return in.color;
}

// ─── Quad Rendering (loop region fill, dim overlays) ────────────────

struct QuadVertex {
    float2 position;  // in pixels
    float4 color;
};

vertex VertexOut quadVertex(
    uint vertexID [[vertex_id]],
    const device QuadVertex* vertices [[buffer(0)]],
    constant float2& viewportSize [[buffer(1)]]
) {
    QuadVertex v = vertices[vertexID];
    float x = (v.position.x / viewportSize.x) * 2.0 - 1.0;
    float y = 1.0 - (v.position.y / viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(x, y, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 quadFragment(VertexOut in [[stage_in]]) {
    return in.color;
}

// ─── Waveform Outline (glow effect) ─────────────────────────────────
// Renders the envelope outline with a subtle glow by drawing a wider
// semi-transparent stroke behind the main outline.

struct OutlineUniforms {
    float2 viewportSize;
    float visibleStart;
    float visibleEnd;
    float centerY;
    float halfHeight;
    float scale;
    int totalBuckets;
    float glowWidth;      // width of glow in pixels (e.g., 3.0)
    float4 glowColor;     // glow color with alpha
};

// The outline uses min/max data (2 floats per bucket: min, max)
vertex VertexOut outlineVertex(
    uint vertexID [[vertex_id]],
    const device float2* minMaxData [[buffer(0)]],  // (min, max) pairs
    constant OutlineUniforms& uniforms [[buffer(1)]]
) {
    // vertexID encodes: which pixel column, top/bottom edge, inner/outer glow
    // Layout: for each pixel, 4 vertices: outer-top, inner-top, inner-bottom, outer-bottom
    uint pixelX = vertexID / 4;
    uint sub = vertexID % 4;

    float viewWidth = uniforms.viewportSize.x;
    float t = float(pixelX) / viewWidth;
    float bucketF = uniforms.visibleStart + t * (uniforms.visibleEnd - uniforms.visibleStart);
    int idx0 = clamp(int(bucketF), 0, uniforms.totalBuckets - 1);
    int idx1 = clamp(idx0 + 1, 0, uniforms.totalBuckets - 1);
    float frac = bucketF - float(idx0);

    float2 mm0 = minMaxData[idx0];
    float2 mm1 = minMaxData[idx1];
    float minVal = mix(mm0.x, mm1.x, frac);
    float maxVal = mix(mm0.y, mm1.y, frac);

    float x = (float(pixelX) / viewWidth) * 2.0 - 1.0;
    float topY = uniforms.centerY - maxVal * uniforms.halfHeight * uniforms.scale;
    float botY = uniforms.centerY - minVal * uniforms.halfHeight * uniforms.scale;

    float y;
    float alpha;
    float glowPx = uniforms.glowWidth;

    switch (sub) {
        case 0: y = topY - glowPx; alpha = 0.0; break;  // outer top (faded)
        case 1: y = topY;          alpha = 1.0; break;  // inner top (solid)
        case 2: y = botY;          alpha = 1.0; break;  // inner bottom (solid)
        case 3: y = botY + glowPx; alpha = 0.0; break;  // outer bottom (faded)
        default: y = topY; alpha = 0.0; break;
    }

    float yNDC = 1.0 - (y / uniforms.viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(x, yNDC, 0.0, 1.0);
    out.color = float4(uniforms.glowColor.rgb, uniforms.glowColor.a * alpha);
    return out;
}

fragment float4 outlineFragment(VertexOut in [[stage_in]]) {
    return in.color;
}
