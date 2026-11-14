// josh CRT example shader
//
// A retro CRT effect for the terminal. It demonstrates the custom_shader
// post-processing pipeline.
//
// Usage:
//   custom_shader = "crt.fs";
//
// The terminal gives this shader:
//   texture0      - the rendered terminal scene (sampler2D)
//   fragTexCoord  - texture coordinate, (0,0) top-left .. (1,1) bottom-right
//   iTime         - seconds since the terminal started
//   iResolution   - window size in pixels
//
// Everything below `--- knobs ---` is tunable.

#version 330

in vec2 fragTexCoord;
out vec4 finalColor;

uniform sampler2D texture0;
uniform float iTime;
uniform vec2  iResolution;

// --- knobs ---
const float curvature  = 0.10;   // how much the screen bulges outward
const float scanlines  = 0.45;   // scanline darkness (0 = off, 1 = full)
const float vignette   = 0.60;   // corner darkening
const float aberration = 0.0015; // RGB fringing strength
const float flicker    = 0.02;   // subtle brightness flicker
const float rollSpeed  = 0.30;   // speed of the moving scanline band

// Barrel distortion: warp the texture coordinate outward from the centre so
// the image looks like it's drawn on the inside of a curved tube.
vec2 distort(vec2 uv) {
    vec2 p  = uv - 0.5;
    float r2 = dot(p, p);
    return p * (1.0 + curvature * r2) + 0.5;
}

void main() {
    vec2 d = distort(fragTexCoord);

    // Pixels warped past the screen edge become the black bezel.
    if (d.x < 0.0 || d.x > 1.0 || d.y < 0.0 || d.y > 1.0) {
        finalColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Chromatic aberration: sample the red, green and blue channels at
    // slightly different offsets. The offset grows toward the edges, like a
    // real tube where the colour beams land imperfectly.
    vec2 offset = (d - 0.5) * aberration;
    float r = texture(texture0, d + offset).r;
    float g = texture(texture0, d).g;
    float b = texture(texture0, d - offset).b;
    vec3 col = vec3(r, g, b);

    // Scanlines: one dark band per scanline. Squaring keeps them thin.
    float scan = sin(d.y * iResolution.y * 3.14159265);
    col *= 1.0 - scanlines * scan * scan;

    // A faint band that slowly rolls down the screen.
    float band = 0.5 + 0.5 * sin(d.y * iResolution.y * 0.15 + iTime * rollSpeed);
    col *= 1.0 - 0.06 * band;

    // Vignette: darken toward the edges/corners.
    vec2 q = d - 0.5;
    col *= 1.0 - vignette * dot(q, q) * 2.0;

    // Flicker: a barely-visible brightness wobble.
    col *= 1.0 - flicker * (0.5 + 0.5 * sin(iTime * 24.0));

    finalColor = vec4(col, 1.0);
}
