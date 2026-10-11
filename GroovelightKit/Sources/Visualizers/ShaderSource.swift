// Metal source compiled at runtime with `MTLDevice.makeLibrary(source:)`, so the package builds without the
// separately downloaded Metal toolchain.
enum ShaderSource {
    static let all = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float bass;
        float mid;
        float treble;
        float level;
        float beat;
        float zoom;
        float rotation;
        float decay;
        float hue;
        uint bandCount;
        uint waveCount;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    float3 hsv2rgb(float3 c) {
        float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
        return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
    }

    float sampleWave(constant float *wave, uint count, float x) {
        float fx = clamp(x, 0.0, 1.0) * float(count - 1);
        uint i = uint(fx);
        return mix(wave[i], wave[min(i + 1, count - 1)], fract(fx));
    }

    // Single triangle covering the screen. uv origin is top-left (texture space).
    vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 pos = float2((vid << 1) & 2, vid & 2);
        VOut out;
        out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(pos.x, 1.0 - pos.y);
        return out;
    }

    fragment float4 present_fragment(VOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler s(filter::linear);
        float3 c = source.sample(s, in.uv).rgb;
        // Soft tone map so additive glows do not clip harshly.
        c = c / (1.0 + c * 0.35);
        return float4(c, 1.0);
    }

    // Previous frame, zoomed / rotated / warped and faded: the classic feedback trail.
    fragment float4 feedback_fragment(VOut in [[stage_in]], texture2d<float> previous [[texture(0)]],
                                      constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_zero, filter::linear);
        float aspect = u.resolution.x / u.resolution.y;
        float2 c = in.uv - 0.5;
        c.x *= aspect;
        float r = length(c);
        float angle = u.rotation + 0.02 * sin(u.time * 0.7 + r * 6.0) * u.mid;
        float2x2 m = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));
        c = (m * c) / (u.zoom + 0.015 * u.bass);
        c.x /= aspect;
        return previous.sample(s, c + 0.5) * u.decay;
    }

    // Windows Media Player "Bars and Waves": LED segmented spectrum bars with peak caps, reflection and a scope.
    fragment float4 bars_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  constant float *bands [[buffer(1)]], constant float *peaks [[buffer(2)]],
                                  constant float *wave [[buffer(3)]]) {
        float2 p = float2(in.uv.x, 1.0 - in.uv.y);
        float3 col = mix(float3(0.01, 0.01, 0.04), float3(0.0, 0.04, 0.10), p.y);

        const float floorY = 0.26;
        const float maxH = 0.62;
        uint n = u.bandCount;
        float fx = p.x * float(n);
        uint i = min(uint(fx), n - 1);
        float local = fract(fx);
        float gap = smoothstep(0.08, 0.14, local) * smoothstep(0.92, 0.86, local);
        float h = bands[i] * maxH;
        float y = p.y - floorY;

        float t = clamp(y / maxH, 0.0, 1.0);
        float3 barColor = mix(float3(0.10, 0.85, 0.45), float3(1.0, 0.88, 0.15), smoothstep(0.35, 0.7, t));
        barColor = mix(barColor, float3(1.0, 0.22, 0.12), smoothstep(0.78, 0.95, t));
        barColor = mix(barColor, hsv2rgb(float3(fract(u.hue + float(i) / float(n) * 0.3), 0.7, 1.0)), 0.25);

        if (y >= 0.0) {
            float segment = smoothstep(0.15, 0.3, fract(y * 70.0));
            if (y < h) {
                col += barColor * gap * segment * (0.85 + 0.3 * u.beat);
            }
            float pk = peaks[i] * maxH;
            col += float3(0.85, 0.95, 1.0) * gap * smoothstep(0.006, 0.002, abs(y - pk));
        } else {
            float ry = -y;
            float reflectH = h * 0.45;
            if (ry < reflectH) {
                col += barColor * gap * 0.22 * (1.0 - ry / (reflectH + 1e-3));
            }
        }

        float w = sampleWave(wave, u.waveCount, p.x);
        float d = abs(p.y - (0.9 + w * 0.08));
        col += float3(0.35, 0.75, 1.0) * smoothstep(0.004, 0.0, d);
        col += float3(0.10, 0.30, 0.70) * smoothstep(0.025, 0.0, d) * 0.5;
        return float4(col, 1.0);
    }

    // iTunes 4 "Lights": colored glowing orbs dancing on Lissajous paths, sized by their frequency band.
    fragment float4 lights_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                    constant float *bands [[buffer(1)]]) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = in.uv - 0.5;
        p.x *= aspect;
        float3 col = float3(0.0);
        for (int k = 0; k < 7; k++) {
            float fk = float(k);
            float energy = bands[min(uint(k * 9 + 3), u.bandCount - 1)];
            float t = u.time * (0.25 + 0.06 * fk);
            float2 c = float2(sin(t * 1.3 + fk * 1.7) * 0.42 * aspect, cos(t * 0.9 + fk * 2.3) * 0.33);
            float radius = 0.03 + energy * 0.14 + u.beat * 0.02;
            float d = length(p - c);
            float3 hue = hsv2rgb(float3(fract(u.hue + fk / 7.0), 0.75, 1.0));
            col += hue * (radius * radius) / (d * d + 0.0015) * 0.05 * (0.25 + energy);
        }
        return float4(col, 1.0);
    }

    // WMP "Ambience" style: a waveform ring and pulsing core drawn over a zooming, swirling feedback tunnel.
    fragment float4 ambience_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                      constant float *wave [[buffer(3)]]) {
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = in.uv - 0.5;
        p.x *= aspect;
        float r = length(p);
        float a = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
        // Mirror the angle so the ring has no seam.
        float w = sampleWave(wave, u.waveCount, a < 0.5 ? a * 2.0 : (1.0 - a) * 2.0);
        float ringR = 0.10 + u.bass * 0.10 + w * 0.07;
        float d = abs(r - ringR);
        float3 ring = hsv2rgb(float3(fract(u.hue + a * 0.5), 0.85, 1.0));
        float3 col = ring * smoothstep(0.010, 0.0, d) * (0.25 + 0.4 * u.level);
        col += hsv2rgb(float3(fract(u.hue + 0.5), 0.6, 1.0)) * smoothstep(0.12, 0.0, r) * (0.01 + u.beat * 0.12);
        return float4(col, 1.0);
    }

    // iTunes "Magnetosphere"-like particles pulled by orbiting magnets whose strength follows bass / mid / treble.
    struct Particle {
        float2 position;
        float2 velocity;
        float life;
        float hue;
    };

    float hash(float n) { return fract(sin(n) * 43758.5453123); }

    kernel void particles_update(device Particle *particles [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
        Particle q = particles[id];
        float aspect = u.resolution.x / u.resolution.y;
        float strengths[3] = { u.bass, u.mid, u.treble };
        float2 acceleration = float2(0.0);
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float t = u.time * (0.35 + 0.15 * fk) + fk * 2.1;
            float2 magnet = float2(cos(t) * 0.55 * aspect, sin(t * 1.3) * 0.45);
            float2 delta = magnet - q.position;
            float dist2 = dot(delta, delta) + 0.04;
            acceleration += normalize(delta) * (0.1 + strengths[k] * 0.8) / (dist2 + 0.15);
        }
        acceleration += float2(-q.position.y, q.position.x) * (0.8 + u.mid * 1.5);
        q.velocity = q.velocity * 0.965 + acceleration * 0.00045 * (1.0 + u.beat * 2.0);
        q.position += q.velocity;
        q.life -= 0.0025;
        if (q.life <= 0.0 || length(q.position) > 2.5) {
            float seed = float(id) * 0.6180339 + u.time;
            float angle = hash(seed) * 6.2831853;
            float radius = 0.05 + hash(seed + 1.7) * 0.25;
            q.position = float2(cos(angle), sin(angle)) * radius;
            q.velocity = float2(-sin(angle), cos(angle)) * 0.004;
            q.life = 0.5 + hash(seed + 3.1) * 0.5;
            q.hue = fract(u.hue + hash(seed + 5.3) * 0.25);
        }
        particles[id] = q;
    }

    struct PointOut {
        float4 position [[position]];
        float size [[point_size]];
        float3 color;
    };

    vertex PointOut particles_vertex(uint vid [[vertex_id]], const device Particle *particles [[buffer(0)]],
                                     constant Uniforms &u [[buffer(1)]]) {
        Particle q = particles[vid];
        float aspect = u.resolution.x / u.resolution.y;
        PointOut out;
        out.position = float4(q.position.x / aspect, q.position.y, 0.0, 1.0);
        out.size = 2.0 + u.level * 4.0;
        out.color = hsv2rgb(float3(q.hue, 0.85, 1.0)) * q.life * 0.09;
        return out;
    }

    fragment float4 particles_fragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
        float falloff = smoothstep(0.5, 0.0, length(pc - 0.5));
        return float4(in.color * falloff, 1.0);
    }
    """
}
