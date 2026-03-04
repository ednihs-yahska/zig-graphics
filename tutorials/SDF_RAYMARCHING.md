# SDF Raymarching with Fragment Shaders — Zig + Raylib

Render 3D scenes entirely in a fragment shader using **Signed Distance Functions** (SDFs) and **raymarching**. No 3D models, no vertices — just math.

We draw a fullscreen rectangle with a custom shader applied. The fragment shader does all the work: for each pixel, it marches a ray through the scene, finds the closest surface using distance functions, and computes lighting.

## Prerequisites

- This repo builds and runs (`zig build run`)
- Basic understanding of shaders (vertex/fragment pipeline)
- The project uses **GLES2 via ANGLE**, so all shaders must be **GLSL ES 100**

---

## Tutorial 1: Setup + Sphere

### Concepts

**Signed Distance Function (SDF):** A function that returns the shortest distance from a point to a surface. Negative inside, zero on the surface, positive outside.

**Raymarching:** Instead of computing ray-surface intersections analytically (like in ray tracing), we *march* along the ray in steps. At each step, we query the SDF to get the distance to the nearest surface, then advance by that distance. When the distance is tiny, we've hit something.

```
Ray origin ----d1----+---d2---+--d3--+-d4-+d5*  ← hit!
                     |        |      |    |
               query SDF  query  query query
```

### The Fragment Shader

The shader runs per-pixel. For each pixel, it constructs a ray from the camera through that pixel, marches it through the scene, and computes the color.

Create `src/sdf_sphere.glsl` (or embed it in Zig — we'll embed it):

```glsl
#version 100
precision highp float;

uniform float iTime;
uniform vec2 iResolution;

#define MAX_STEPS 100
#define MAX_DIST 100.0
#define SURF_DIST 0.001

// ---- SDF Primitives ----

float sdSphere(vec3 p, float r) {
    return length(p) - r;
}

float sdPlane(vec3 p) {
    return p.y;
}

// ---- Scene ----

float scene(vec3 p) {
    float sphere = sdSphere(p - vec3(0.0, 1.0, 0.0), 1.0);
    float ground = sdPlane(p);
    return min(sphere, ground);
}

// ---- Normal via gradient of the SDF ----

vec3 getNormal(vec3 p) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        scene(p + e.xyy) - scene(p - e.xyy),
        scene(p + e.yxy) - scene(p - e.yxy),
        scene(p + e.yyx) - scene(p - e.yyx)
    ));
}

// ---- Raymarching ----

float rayMarch(vec3 ro, vec3 rd) {
    float t = 0.0;
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 p = ro + rd * t;
        float d = scene(p);
        t += d;
        if (d < SURF_DIST || t > MAX_DIST) break;
    }
    return t;
}

// ---- Main ----

void main() {
    // Map pixel to centered UV with aspect correction
    vec2 uv = (2.0 * gl_FragCoord.xy - iResolution.xy) / iResolution.y;

    // Camera — orbits the scene
    float angle = iTime * 0.4;
    vec3 ro = vec3(cos(angle) * 5.0, 2.5, sin(angle) * 5.0);
    vec3 target = vec3(0.0, 0.5, 0.0);

    // Camera basis vectors
    vec3 fwd = normalize(target - ro);
    vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(right, fwd);
    vec3 rd = normalize(uv.x * right + uv.y * up + 1.5 * fwd);

    // March!
    float t = rayMarch(ro, rd);

    // Shading
    vec3 col = vec3(0.05, 0.05, 0.1); // dark background

    if (t < MAX_DIST) {
        vec3 p = ro + rd * t;
        vec3 n = getNormal(p);

        // Light direction
        vec3 lightDir = normalize(vec3(0.8, 1.0, -0.6));
        float diff = max(dot(n, lightDir), 0.0);
        float amb = 0.15;

        // Checkerboard ground
        vec3 matColor;
        if (p.y < 0.01) {
            float checker = mod(floor(p.x) + floor(p.z), 2.0);
            matColor = mix(vec3(0.35), vec3(0.65), checker);
        } else {
            matColor = vec3(0.9, 0.25, 0.2); // sphere: red-orange
        }

        col = matColor * (diff + amb);

        // Simple fog for depth
        col = mix(col, vec3(0.05, 0.05, 0.1), 1.0 - exp(-0.01 * t * t));
    }

    // Gamma correction
    col = pow(col, vec3(1.0 / 2.2));

    gl_FragColor = vec4(col, 1.0);
}
```

**Key ideas:**
- `sdSphere(p, r)` — distance from point `p` to a sphere of radius `r` centered at the origin. Translate the sphere by subtracting its center from `p`.
- `min(sphere, ground)` — the **union** of two SDFs. The closest surface wins.
- `getNormal` — estimates the surface normal by sampling the SDF at six nearby points (finite difference gradient).
- The camera orbits using `sin`/`cos` on `iTime`.

### The Zig Host Code

The Zig side is minimal: create a window, load the shader, pass uniforms (`iTime`, `iResolution`), draw a fullscreen rectangle each frame.

Replace `src/main.zig`:

```zig
const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
});

// GLSL ES 100 fragment shader — embedded as a Zig string
const fs_source =
    \\#version 100
    \\precision highp float;
    \\
    \\uniform float iTime;
    \\uniform vec2 iResolution;
    \\
    \\#define MAX_STEPS 100
    \\#define MAX_DIST 100.0
    \\#define SURF_DIST 0.001
    \\
    \\float sdSphere(vec3 p, float r) {
    \\    return length(p) - r;
    \\}
    \\
    \\float sdPlane(vec3 p) {
    \\    return p.y;
    \\}
    \\
    \\float scene(vec3 p) {
    \\    float sphere = sdSphere(p - vec3(0.0, 1.0, 0.0), 1.0);
    \\    float ground = sdPlane(p);
    \\    return min(sphere, ground);
    \\}
    \\
    \\vec3 getNormal(vec3 p) {
    \\    vec2 e = vec2(0.001, 0.0);
    \\    return normalize(vec3(
    \\        scene(p + e.xyy) - scene(p - e.xyy),
    \\        scene(p + e.yxy) - scene(p - e.yxy),
    \\        scene(p + e.yyx) - scene(p - e.yyx)
    \\    ));
    \\}
    \\
    \\float rayMarch(vec3 ro, vec3 rd) {
    \\    float t = 0.0;
    \\    for (int i = 0; i < MAX_STEPS; i++) {
    \\        vec3 p = ro + rd * t;
    \\        float d = scene(p);
    \\        t += d;
    \\        if (d < SURF_DIST || t > MAX_DIST) break;
    \\    }
    \\    return t;
    \\}
    \\
    \\void main() {
    \\    vec2 uv = (2.0 * gl_FragCoord.xy - iResolution.xy) / iResolution.y;
    \\
    \\    float angle = iTime * 0.4;
    \\    vec3 ro = vec3(cos(angle) * 5.0, 2.5, sin(angle) * 5.0);
    \\    vec3 target = vec3(0.0, 0.5, 0.0);
    \\
    \\    vec3 fwd = normalize(target - ro);
    \\    vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
    \\    vec3 up = cross(right, fwd);
    \\    vec3 rd = normalize(uv.x * right + uv.y * up + 1.5 * fwd);
    \\
    \\    float t = rayMarch(ro, rd);
    \\
    \\    vec3 col = vec3(0.05, 0.05, 0.1);
    \\    if (t < MAX_DIST) {
    \\        vec3 p = ro + rd * t;
    \\        vec3 n = getNormal(p);
    \\        vec3 lightDir = normalize(vec3(0.8, 1.0, -0.6));
    \\        float diff = max(dot(n, lightDir), 0.0);
    \\        float amb = 0.15;
    \\
    \\        vec3 matColor;
    \\        if (p.y < 0.01) {
    \\            float checker = mod(floor(p.x) + floor(p.z), 2.0);
    \\            matColor = mix(vec3(0.35), vec3(0.65), checker);
    \\        } else {
    \\            matColor = vec3(0.9, 0.25, 0.2);
    \\        }
    \\
    \\        col = matColor * (diff + amb);
    \\        col = mix(col, vec3(0.05, 0.05, 0.1), 1.0 - exp(-0.01 * t * t));
    \\    }
    \\
    \\    col = pow(col, vec3(1.0 / 2.2));
    \\    gl_FragColor = vec4(col, 1.0);
    \\}
;

pub fn main() void {
    const screen_width = 800;
    const screen_height = 600;

    rl.InitWindow(screen_width, screen_height, "SDF Raymarching - Sphere");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // Load shader — null vertex shader = use raylib's default
    const shader = rl.LoadShaderFromMemory(null, fs_source);
    defer rl.UnloadShader(shader);

    // Get uniform locations
    const time_loc = rl.GetShaderLocation(shader, "iTime");
    const res_loc = rl.GetShaderLocation(shader, "iResolution");

    while (!rl.WindowShouldClose()) {
        // Update uniforms
        const time: f32 = @floatCast(rl.GetTime());
        rl.SetShaderValue(shader, time_loc, &time, rl.SHADER_UNIFORM_FLOAT);
        const res = [2]f32{
            @floatFromInt(rl.GetScreenWidth()),
            @floatFromInt(rl.GetScreenHeight()),
        };
        rl.SetShaderValue(shader, res_loc, &res, rl.SHADER_UNIFORM_VEC2);

        // Draw fullscreen quad with our shader
        rl.BeginDrawing();
        rl.BeginShaderMode(shader);
        rl.DrawRectangle(0, 0, screen_width, screen_height, rl.WHITE);
        rl.EndShaderMode();
        rl.DrawFPS(10, 10);
        rl.EndDrawing();
    }
}
```

Run with `zig build run`. You should see a red sphere on a checkerboard floor, with the camera slowly orbiting.

**How the host code works:**
- `LoadShaderFromMemory(null, fs_source)` — compiles the fragment shader; `null` uses raylib's default vertex shader which passes through texture coordinates
- `GetShaderLocation` — finds the GPU uniform location by name
- `SetShaderValue` — uploads the uniform value each frame
- `BeginShaderMode` / `EndShaderMode` — all draw calls between these use our shader
- `DrawRectangle` covering the full window acts as our "fullscreen quad" — the shader runs for every pixel

### Loading shaders from standalone files

The tutorial above embeds the GLSL source as a Zig multiline string (`\\` syntax). This works, but for larger shaders or if you prefer editing `.glsl` files with proper syntax highlighting, you can use `@embedFile` instead:

```zig
// Embed src/shaders/raymarching.frag at compile time as a []const u8
const fs_source = @embedFile("shaders/raymarching.frag");
const shader = rl.LoadShaderFromMemory(null, fs_source);
```

`@embedFile` resolves paths relative to the source file's directory. So with `src/main.zig` calling `@embedFile("shaders/raymarching.frag")`, the file would live at `src/shaders/raymarching.frag`.

The shader is baked into the binary at compile time — no file I/O at runtime, no need to ship the `.glsl` file alongside the executable. If you change the `.glsl` file, `zig build` recompiles automatically.

Raylib also has `LoadShader(vsFileName, fsFileName)` which reads files at runtime, but `@embedFile` + `LoadShaderFromMemory` is simpler for distribution since everything is in one binary.

**GLES2 reminder:** Since this project uses ANGLE with OpenGL ES 2.0, all shaders must use `#version 100`, declare `precision highp float;`, and write to `gl_FragColor` (not `out vec4` / layout-based outputs).

---

## Tutorial 2: Primitive Shapes

Now we build a catalog of SDF primitives and display them all in one scene. Each shape gets a unique color via a material ID system.

### SDF Primitive Catalog

These are the fundamental building blocks. Each function returns the signed distance from point `p` to the surface. All shapes are centered at the origin — translate by subtracting the desired center from `p`.

```glsl
// Sphere: radius r
float sdSphere(vec3 p, float r) {
    return length(p) - r;
}

// Box: half-extents b (vec3)
float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Rounded Box: box with rounded edges, radius r
float sdRoundBox(vec3 p, vec3 b, float r) {
    vec3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

// Torus: R = major radius, r = tube radius
float sdTorus(vec3 p, float R, float r) {
    vec2 q = vec2(length(p.xz) - R, p.y);
    return length(q) - r;
}

// Capped Cylinder: height h, radius r
float sdCylinder(vec3 p, float h, float r) {
    vec2 d = abs(vec2(length(p.xz), p.y)) - vec2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

// Capsule: line segment from a to b, radius r
float sdCapsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 ab = b - a;
    vec3 ap = p - a;
    float t = clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - (a + t * ab)) - r;
}

// Cone: height h, radius r at base
float sdCone(vec3 p, float h, float r) {
    vec2 q = vec2(length(p.xz), p.y);
    vec2 tip = q - vec2(0.0, h);
    vec2 mantleDir = normalize(vec2(h, r));
    float mantle = dot(tip, mantleDir);
    float d = max(mantle, -q.y);
    float projected = dot(tip, vec2(mantleDir.y, -mantleDir.x));
    if (q.y > h && projected < 0.0) d = max(d, length(tip));
    if (q.y < 0.0 && q.x > r) d = max(d, length(q - vec2(r, 0.0)));
    return d;
}

// Infinite ground plane at y=0
float sdPlane(vec3 p) {
    return p.y;
}
```

### Scene with Material IDs

To color each shape differently, `scene()` now returns `vec2(distance, materialID)`. We use a union operation that picks the closer surface:

```glsl
vec2 opUnion(vec2 a, vec2 b) {
    return (a.x < b.x) ? a : b;
}

vec2 scene(vec3 p) {
    vec2 res = vec2(sdPlane(p), 0.0);                                          // ground
    res = opUnion(res, vec2(sdSphere(p - vec3(-4.5, 1.0, 0.0), 1.0), 1.0));   // sphere
    res = opUnion(res, vec2(sdBox(p - vec3(-1.5, 1.0, 0.0), vec3(0.8)), 2.0));// box
    res = opUnion(res, vec2(sdTorus(p - vec3(1.5, 1.0, 0.0), 0.7, 0.25), 3.0)); // torus
    res = opUnion(res, vec2(sdCylinder(p - vec3(4.5, 1.0, 0.0), 0.8, 0.5), 4.0)); // cylinder
    res = opUnion(res, vec2(sdCapsule(p, vec3(-3.0, 0.3, 3.0), vec3(-3.0, 1.8, 3.0), 0.3), 5.0)); // capsule
    res = opUnion(res, vec2(sdCone(p - vec3(0.0, 0.0, 3.0), 1.5, 0.7), 6.0));  // cone
    res = opUnion(res, vec2(sdRoundBox(p - vec3(3.0, 1.0, 3.0), vec3(0.6), 0.15), 7.0)); // rounded box
    return res;
}
```

### Material Colors

```glsl
vec3 getMaterial(float id) {
    if (id < 0.5) {  // ground
        return vec3(0.5);
    } else if (id < 1.5) {  // sphere
        return vec3(0.9, 0.2, 0.15);
    } else if (id < 2.5) {  // box
        return vec3(0.15, 0.7, 0.2);
    } else if (id < 3.5) {  // torus
        return vec3(0.2, 0.4, 0.9);
    } else if (id < 4.5) {  // cylinder
        return vec3(0.9, 0.7, 0.1);
    } else if (id < 5.5) {  // capsule
        return vec3(0.8, 0.3, 0.8);
    } else if (id < 6.5) {  // cone
        return vec3(0.1, 0.8, 0.7);
    } else {  // rounded box
        return vec3(0.95, 0.5, 0.2);
    }
}
```

### Updated Normal and Raymarch Functions

Since `scene()` now returns `vec2`, extract the distance component (`.x`) for normals and marching:

```glsl
vec3 getNormal(vec3 p) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        scene(p + e.xyy).x - scene(p - e.xyy).x,
        scene(p + e.yxy).x - scene(p - e.yxy).x,
        scene(p + e.yyx).x - scene(p - e.yyx).x
    ));
}

vec2 rayMarch(vec3 ro, vec3 rd) {
    float t = 0.0;
    vec2 res = vec2(0.0, -1.0);
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 p = ro + rd * t;
        res = scene(p);
        if (res.x < SURF_DIST) break;
        t += res.x;
        if (t > MAX_DIST) break;
    }
    return vec2(t, res.y);
}
```

### Complete Code — Tutorial 2

Replace `src/main.zig`:

```zig
const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
});

const fs_source =
    \\#version 100
    \\precision highp float;
    \\
    \\uniform float iTime;
    \\uniform vec2 iResolution;
    \\
    \\#define MAX_STEPS 100
    \\#define MAX_DIST 100.0
    \\#define SURF_DIST 0.001
    \\
    \\// ---- SDF Primitives ----
    \\
    \\float sdSphere(vec3 p, float r) {
    \\    return length(p) - r;
    \\}
    \\
    \\float sdBox(vec3 p, vec3 b) {
    \\    vec3 q = abs(p) - b;
    \\    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
    \\}
    \\
    \\float sdRoundBox(vec3 p, vec3 b, float r) {
    \\    vec3 q = abs(p) - b + r;
    \\    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
    \\}
    \\
    \\float sdTorus(vec3 p, float R, float r) {
    \\    vec2 q = vec2(length(p.xz) - R, p.y);
    \\    return length(q) - r;
    \\}
    \\
    \\float sdCylinder(vec3 p, float h, float r) {
    \\    vec2 d = abs(vec2(length(p.xz), p.y)) - vec2(r, h);
    \\    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
    \\}
    \\
    \\float sdCapsule(vec3 p, vec3 a, vec3 b, float r) {
    \\    vec3 ab = b - a;
    \\    vec3 ap = p - a;
    \\    float t = clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0);
    \\    return length(p - (a + t * ab)) - r;
    \\}
    \\
    \\float sdCone(vec3 p, float h, float r) {
    \\    vec2 q = vec2(length(p.xz), p.y);
    \\    vec2 tip = q - vec2(0.0, h);
    \\    vec2 mantleDir = normalize(vec2(h, r));
    \\    float mantle = dot(tip, mantleDir);
    \\    float d = max(mantle, -q.y);
    \\    float projected = dot(tip, vec2(mantleDir.y, -mantleDir.x));
    \\    if (q.y > h && projected < 0.0) d = max(d, length(tip));
    \\    if (q.y < 0.0 && q.x > r) d = max(d, length(q - vec2(r, 0.0)));
    \\    return d;
    \\}
    \\
    \\float sdPlane(vec3 p) {
    \\    return p.y;
    \\}
    \\
    \\// ---- Scene ----
    \\
    \\vec2 opUnion(vec2 a, vec2 b) {
    \\    return (a.x < b.x) ? a : b;
    \\}
    \\
    \\vec2 scene(vec3 p) {
    \\    vec2 res = vec2(sdPlane(p), 0.0);
    \\    res = opUnion(res, vec2(sdSphere(p - vec3(-4.5, 1.0, 0.0), 1.0), 1.0));
    \\    res = opUnion(res, vec2(sdBox(p - vec3(-1.5, 1.0, 0.0), vec3(0.8)), 2.0));
    \\    res = opUnion(res, vec2(sdTorus(p - vec3(1.5, 1.0, 0.0), 0.7, 0.25), 3.0));
    \\    res = opUnion(res, vec2(sdCylinder(p - vec3(4.5, 1.0, 0.0), 0.8, 0.5), 4.0));
    \\    res = opUnion(res, vec2(sdCapsule(p, vec3(-3.0, 0.3, 3.0), vec3(-3.0, 1.8, 3.0), 0.3), 5.0));
    \\    res = opUnion(res, vec2(sdCone(p - vec3(0.0, 0.0, 3.0), 1.5, 0.7), 6.0));
    \\    res = opUnion(res, vec2(sdRoundBox(p - vec3(3.0, 1.0, 3.0), vec3(0.6), 0.15), 7.0));
    \\    return res;
    \\}
    \\
    \\// ---- Normal ----
    \\
    \\vec3 getNormal(vec3 p) {
    \\    vec2 e = vec2(0.001, 0.0);
    \\    return normalize(vec3(
    \\        scene(p + e.xyy).x - scene(p - e.xyy).x,
    \\        scene(p + e.yxy).x - scene(p - e.yxy).x,
    \\        scene(p + e.yyx).x - scene(p - e.yyx).x
    \\    ));
    \\}
    \\
    \\// ---- Raymarching ----
    \\
    \\vec2 rayMarch(vec3 ro, vec3 rd) {
    \\    float t = 0.0;
    \\    vec2 res = vec2(0.0, -1.0);
    \\    for (int i = 0; i < MAX_STEPS; i++) {
    \\        vec3 p = ro + rd * t;
    \\        res = scene(p);
    \\        if (res.x < SURF_DIST) break;
    \\        t += res.x;
    \\        if (t > MAX_DIST) break;
    \\    }
    \\    return vec2(t, res.y);
    \\}
    \\
    \\// ---- Materials ----
    \\
    \\vec3 getMaterial(float id, vec3 p) {
    \\    if (id < 0.5) {
    \\        float checker = mod(floor(p.x) + floor(p.z), 2.0);
    \\        return mix(vec3(0.3), vec3(0.6), checker);
    \\    } else if (id < 1.5) { return vec3(0.9, 0.2, 0.15);
    \\    } else if (id < 2.5) { return vec3(0.15, 0.7, 0.2);
    \\    } else if (id < 3.5) { return vec3(0.2, 0.4, 0.9);
    \\    } else if (id < 4.5) { return vec3(0.9, 0.7, 0.1);
    \\    } else if (id < 5.5) { return vec3(0.8, 0.3, 0.8);
    \\    } else if (id < 6.5) { return vec3(0.1, 0.8, 0.7);
    \\    } else { return vec3(0.95, 0.5, 0.2);
    \\    }
    \\}
    \\
    \\// ---- Soft Shadow ----
    \\
    \\float softShadow(vec3 ro, vec3 rd, float mint, float maxt, float k) {
    \\    float res = 1.0;
    \\    float t = mint;
    \\    for (int i = 0; i < 64; i++) {
    \\        float h = scene(ro + rd * t).x;
    \\        res = min(res, k * h / t);
    \\        t += clamp(h, 0.02, 0.2);
    \\        if (res < 0.001 || t > maxt) break;
    \\    }
    \\    return clamp(res, 0.0, 1.0);
    \\}
    \\
    \\// ---- Main ----
    \\
    \\void main() {
    \\    vec2 uv = (2.0 * gl_FragCoord.xy - iResolution.xy) / iResolution.y;
    \\
    \\    float angle = iTime * 0.3;
    \\    vec3 ro = vec3(cos(angle) * 10.0, 5.0, sin(angle) * 10.0);
    \\    vec3 target = vec3(0.0, 0.8, 1.5);
    \\
    \\    vec3 fwd = normalize(target - ro);
    \\    vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
    \\    vec3 up = cross(right, fwd);
    \\    vec3 rd = normalize(uv.x * right + uv.y * up + 1.5 * fwd);
    \\
    \\    vec2 hit = rayMarch(ro, rd);
    \\    float t = hit.x;
    \\    float id = hit.y;
    \\
    \\    vec3 col = vec3(0.05, 0.05, 0.1);
    \\
    \\    if (t < MAX_DIST) {
    \\        vec3 p = ro + rd * t;
    \\        vec3 n = getNormal(p);
    \\        vec3 lightDir = normalize(vec3(0.8, 1.0, -0.6));
    \\
    \\        float diff = max(dot(n, lightDir), 0.0);
    \\        float shadow = softShadow(p + n * 0.01, lightDir, 0.02, 20.0, 8.0);
    \\        float amb = 0.15;
    \\
    \\        vec3 matColor = getMaterial(id, p);
    \\        col = matColor * (diff * shadow + amb);
    \\
    \\        col = mix(col, vec3(0.05, 0.05, 0.1), 1.0 - exp(-0.005 * t * t));
    \\    }
    \\
    \\    col = pow(col, vec3(1.0 / 2.2));
    \\    gl_FragColor = vec4(col, 1.0);
    \\}
;

pub fn main() void {
    const screen_width = 800;
    const screen_height = 600;

    rl.InitWindow(screen_width, screen_height, "SDF Raymarching - Primitives");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    const shader = rl.LoadShaderFromMemory(null, fs_source);
    defer rl.UnloadShader(shader);

    const time_loc = rl.GetShaderLocation(shader, "iTime");
    const res_loc = rl.GetShaderLocation(shader, "iResolution");

    while (!rl.WindowShouldClose()) {
        const time: f32 = @floatCast(rl.GetTime());
        rl.SetShaderValue(shader, time_loc, &time, rl.SHADER_UNIFORM_FLOAT);
        const res = [2]f32{ @floatFromInt(rl.GetScreenWidth()), @floatFromInt(rl.GetScreenHeight()) };
        rl.SetShaderValue(shader, res_loc, &res, rl.SHADER_UNIFORM_VEC2);

        rl.BeginDrawing();
        rl.BeginShaderMode(shader);
        rl.DrawRectangle(0, 0, screen_width, screen_height, rl.WHITE);
        rl.EndShaderMode();
        rl.DrawFPS(10, 10);
        rl.EndDrawing();
    }
}
```

You should see 8 shapes (sphere, box, torus, cylinder, capsule, cone, rounded box, ground) each in a distinct color, with soft shadows and the camera orbiting the scene.

### Primitive Quick Reference

| Shape | SDF | Parameters |
|-------|-----|------------|
| Sphere | `length(p) - r` | `r` = radius |
| Box | `length(max(abs(p)-b, 0)) + min(max(q.x,max(q.y,q.z)), 0)` | `b` = half-extents |
| Rounded Box | Box SDF - `r` | `b` = half-extents, `r` = corner radius |
| Torus | `length(vec2(length(p.xz)-R, p.y)) - r` | `R` = major, `r` = minor |
| Cylinder | Similar to box but in cylindrical coords | `h` = half-height, `r` = radius |
| Capsule | Distance to line segment - `r` | `a,b` = endpoints, `r` = radius |
| Cone | Distance to cone surface | `h` = height, `r` = base radius |
| Plane | `p.y` | Infinite ground at y=0 |

### Operations

| Operation | Formula | Effect |
|-----------|---------|--------|
| Union | `min(a, b)` | Combine shapes |
| Subtraction | `max(a, -b)` | Carve `b` out of `a` |
| Intersection | `max(a, b)` | Keep only overlap |
| Translation | `sdf(p - offset)` | Move the shape |
| Rotation | `sdf(rotMatrix * p)` | Rotate the shape |

---

## Tutorial 3: Smooth Blending

Hard `min`/`max` operations create sharp edges where shapes meet. **Smooth minimum** creates organic, blob-like transitions — like clay or liquid merging.

### Smooth Minimum

The polynomial smooth min blends two distance values when they're within distance `k` of each other:

```glsl
// Polynomial smooth min (quadratic)
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}
```

**How it works:**
- When `|a - b| > k`: one shape is far away, acts like normal `min`
- When `|a - b| < k`: both shapes are nearby, the result dips *below* both distances creating a smooth blend
- `k` controls the blend radius — bigger `k` = more blending
- At `k = 0` it's equivalent to regular `min`

### Smooth Operations (Full Set)

From smooth min, we derive the other smooth operations:

```glsl
// Smooth union: blend shapes together
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Smooth subtraction: carve b from a with smooth edge
float smax(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return max(a, b) + h * h * k * 0.25;
}

// Smooth intersection: keep overlap with smooth edge
float smaxIntersect(float a, float b, float k) {
    return smax(a, b, k);
}

// Smooth subtraction shorthand: a minus b
float sSubtract(float a, float b, float k) {
    return smax(a, -b, k);
}
```

### Smooth Union with Material Blending

When two shapes blend, their colors should blend too. We track a blend factor `h`:

```glsl
vec2 sminColor(float a, float b, float k, float idA, float idB) {
    float h = max(k - abs(a - b), 0.0) / k;
    float d = min(a, b) - h * h * k * 0.25;
    // Blend material ID based on which shape is closer
    float blend = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    float id = mix(idB, idA, blend);
    return vec2(d, id);
}
```

### Complete Code — Tutorial 3

This scene demonstrates smooth blending with animated shapes. Two spheres orbit and merge, a box melts into the ground, and a subtracted cavity shows smooth carving.

Replace `src/main.zig`:

```zig
const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
});

const fs_source =
    \\#version 100
    \\precision highp float;
    \\
    \\uniform float iTime;
    \\uniform vec2 iResolution;
    \\
    \\#define MAX_STEPS 100
    \\#define MAX_DIST 100.0
    \\#define SURF_DIST 0.001
    \\
    \\// ---- SDF Primitives ----
    \\
    \\float sdSphere(vec3 p, float r) {
    \\    return length(p) - r;
    \\}
    \\
    \\float sdBox(vec3 p, vec3 b) {
    \\    vec3 q = abs(p) - b;
    \\    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
    \\}
    \\
    \\float sdTorus(vec3 p, float R, float r) {
    \\    vec2 q = vec2(length(p.xz) - R, p.y);
    \\    return length(q) - r;
    \\}
    \\
    \\float sdPlane(vec3 p) {
    \\    return p.y;
    \\}
    \\
    \\// ---- Smooth Operations ----
    \\
    \\float smin(float a, float b, float k) {
    \\    float h = max(k - abs(a - b), 0.0) / k;
    \\    return min(a, b) - h * h * k * 0.25;
    \\}
    \\
    \\float smax(float a, float b, float k) {
    \\    float h = max(k - abs(a - b), 0.0) / k;
    \\    return max(a, b) + h * h * k * 0.25;
    \\}
    \\
    \\// Smooth union with material blending
    \\vec2 sminColor(float a, float b, float k, float idA, float idB) {
    \\    float h = max(k - abs(a - b), 0.0) / k;
    \\    float d = min(a, b) - h * h * k * 0.25;
    \\    float blend = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    \\    float id = mix(idB, idA, blend);
    \\    return vec2(d, id);
    \\}
    \\
    \\vec2 opUnion(vec2 a, vec2 b) {
    \\    return (a.x < b.x) ? a : b;
    \\}
    \\
    \\// ---- Scene ----
    \\
    \\vec2 scene(vec3 p) {
    \\    // Ground
    \\    vec2 res = vec2(sdPlane(p), 0.0);
    \\
    \\    // --- Demo 1: Smooth union (two orbiting spheres merge) ---
    \\    float orbitSpeed = iTime * 1.2;
    \\    vec3 c1 = vec3(-3.0 + sin(orbitSpeed) * 1.2, 1.0, cos(orbitSpeed) * 1.2);
    \\    vec3 c2 = vec3(-3.0 - sin(orbitSpeed) * 1.2, 1.0, -cos(orbitSpeed) * 1.2);
    \\    float s1 = sdSphere(p - c1, 0.8);
    \\    float s2 = sdSphere(p - c2, 0.8);
    \\    vec2 merging = sminColor(s1, s2, 0.8, 1.0, 2.0);
    \\    res = opUnion(res, merging);
    \\
    \\    // --- Demo 2: Smooth union of box + sphere (organic blob) ---
    \\    float box = sdBox(p - vec3(1.5, 1.0, 0.0), vec3(0.6));
    \\    float sphere = sdSphere(p - vec3(1.5, 1.8, 0.0), 0.5);
    \\    float blob = smin(box, sphere, 0.5);
    \\    res = opUnion(res, vec2(blob, 3.0));
    \\
    \\    // --- Demo 3: Smooth subtraction (sphere carved from box) ---
    \\    float outerBox = sdBox(p - vec3(5.0, 1.0, 0.0), vec3(0.9));
    \\    float carveSphere = sdSphere(p - vec3(5.0, 1.0, 0.0), 1.1);
    \\    float carved = smax(outerBox, -carveSphere, 0.3);
    \\    res = opUnion(res, vec2(carved, 4.0));
    \\
    \\    // --- Demo 4: Smooth union of torus + ground (melting into floor) ---
    \\    float torus = sdTorus(p - vec3(-6.0, 0.3, 0.0), 1.0, 0.3);
    \\    float ground = sdPlane(p);
    \\    float melted = smin(torus, ground, 0.4);
    \\    // Only use the melted ground if it's closer
    \\    if (melted < res.x) {
    \\        res = vec2(melted, 5.0);
    \\    }
    \\
    \\    return res;
    \\}
    \\
    \\// ---- Normal ----
    \\
    \\vec3 getNormal(vec3 p) {
    \\    vec2 e = vec2(0.001, 0.0);
    \\    return normalize(vec3(
    \\        scene(p + e.xyy).x - scene(p - e.xyy).x,
    \\        scene(p + e.yxy).x - scene(p - e.yxy).x,
    \\        scene(p + e.yyx).x - scene(p - e.yyx).x
    \\    ));
    \\}
    \\
    \\// ---- Raymarching ----
    \\
    \\vec2 rayMarch(vec3 ro, vec3 rd) {
    \\    float t = 0.0;
    \\    vec2 res = vec2(0.0, -1.0);
    \\    for (int i = 0; i < MAX_STEPS; i++) {
    \\        vec3 p = ro + rd * t;
    \\        res = scene(p);
    \\        if (res.x < SURF_DIST) break;
    \\        t += res.x;
    \\        if (t > MAX_DIST) break;
    \\    }
    \\    return vec2(t, res.y);
    \\}
    \\
    \\// ---- Soft Shadow ----
    \\
    \\float softShadow(vec3 ro, vec3 rd, float mint, float maxt, float k) {
    \\    float res = 1.0;
    \\    float t = mint;
    \\    for (int i = 0; i < 64; i++) {
    \\        float h = scene(ro + rd * t).x;
    \\        res = min(res, k * h / t);
    \\        t += clamp(h, 0.02, 0.2);
    \\        if (res < 0.001 || t > maxt) break;
    \\    }
    \\    return clamp(res, 0.0, 1.0);
    \\}
    \\
    \\// ---- Materials ----
    \\
    \\vec3 getMaterial(float id, vec3 p) {
    \\    if (id < 0.5) {
    \\        float checker = mod(floor(p.x) + floor(p.z), 2.0);
    \\        return mix(vec3(0.25), vec3(0.55), checker);
    \\    } else if (id < 1.5) { return vec3(0.95, 0.25, 0.15);  // sphere A (red)
    \\    } else if (id < 2.5) { return vec3(0.15, 0.65, 0.95);  // sphere B (blue)
    \\    } else if (id < 3.5) { return vec3(0.2, 0.85, 0.3);    // blob (green)
    \\    } else if (id < 4.5) { return vec3(0.9, 0.6, 0.1);     // carved (gold)
    \\    } else { return vec3(0.7, 0.3, 0.8);                    // melted torus (purple)
    \\    }
    \\}
    \\
    \\// ---- Main ----
    \\
    \\void main() {
    \\    vec2 uv = (2.0 * gl_FragCoord.xy - iResolution.xy) / iResolution.y;
    \\
    \\    float angle = iTime * 0.25;
    \\    vec3 ro = vec3(cos(angle) * 12.0, 5.0, sin(angle) * 12.0);
    \\    vec3 target = vec3(-0.5, 0.8, 0.0);
    \\
    \\    vec3 fwd = normalize(target - ro);
    \\    vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
    \\    vec3 up = cross(right, fwd);
    \\    vec3 rd = normalize(uv.x * right + uv.y * up + 1.5 * fwd);
    \\
    \\    vec2 hit = rayMarch(ro, rd);
    \\    float t = hit.x;
    \\    float id = hit.y;
    \\
    \\    vec3 col = vec3(0.05, 0.05, 0.1);
    \\
    \\    if (t < MAX_DIST) {
    \\        vec3 p = ro + rd * t;
    \\        vec3 n = getNormal(p);
    \\        vec3 lightDir = normalize(vec3(0.8, 1.0, -0.6));
    \\
    \\        float diff = max(dot(n, lightDir), 0.0);
    \\        float shadow = softShadow(p + n * 0.01, lightDir, 0.02, 20.0, 8.0);
    \\        float amb = 0.15;
    \\
    \\        vec3 matColor = getMaterial(id, p);
    \\        col = matColor * (diff * shadow + amb);
    \\
    \\        col = mix(col, vec3(0.05, 0.05, 0.1), 1.0 - exp(-0.003 * t * t));
    \\    }
    \\
    \\    col = pow(col, vec3(1.0 / 2.2));
    \\    gl_FragColor = vec4(col, 1.0);
    \\}
;

pub fn main() void {
    const screen_width = 800;
    const screen_height = 600;

    rl.InitWindow(screen_width, screen_height, "SDF Raymarching - Smooth Blending");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    const shader = rl.LoadShaderFromMemory(null, fs_source);
    defer rl.UnloadShader(shader);

    const time_loc = rl.GetShaderLocation(shader, "iTime");
    const res_loc = rl.GetShaderLocation(shader, "iResolution");

    while (!rl.WindowShouldClose()) {
        const time: f32 = @floatCast(rl.GetTime());
        rl.SetShaderValue(shader, time_loc, &time, rl.SHADER_UNIFORM_FLOAT);
        const res = [2]f32{ @floatFromInt(rl.GetScreenWidth()), @floatFromInt(rl.GetScreenHeight()) };
        rl.SetShaderValue(shader, res_loc, &res, rl.SHADER_UNIFORM_VEC2);

        rl.BeginDrawing();
        rl.BeginShaderMode(shader);
        rl.DrawRectangle(0, 0, screen_width, screen_height, rl.WHITE);
        rl.EndShaderMode();
        rl.DrawFPS(10, 10);
        rl.EndDrawing();
    }
}
```

**What to look for:**
- **Left**: Two spheres orbiting and smoothly merging — where they overlap, the surface bulges organically (like metaballs / lava lamp)
- **Center-left**: A sphere sitting on a box with smooth blending — no sharp edge where they meet
- **Center-right**: A box with a sphere carved out, smooth rounded edges on the cavity
- **Far left**: A torus melting into the ground plane with a smooth fillet

### Tuning the Blend Radius `k`

The `k` parameter controls how far apart shapes can be and still blend:

- `k = 0.0` — no blending (same as hard `min`/`max`)
- `k = 0.3` — subtle rounding at intersections
- `k = 0.8` — aggressive blending, shapes merge early
- `k = 2.0` — very blobby, shapes heavily influence each other

Try changing `k` in the `smin`/`smax` calls to see the effect. You can also animate it:

```glsl
float k = 0.3 + 0.5 * (sin(iTime) * 0.5 + 0.5);
```

### Smooth Blend Variants

**Cubic smooth min** (C1 continuous — smoother gradients, better normals):
```glsl
float sminCubic(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * h * k * (1.0/6.0);
}
```

**Exponential smooth min** (infinite blend range, no sharp cutoff):
```glsl
float sminExp(float a, float b, float k) {
    float res = exp2(-k * a) + exp2(-k * b);
    return -log2(res) / k;
}
```

Each variant produces a slightly different blend profile. The polynomial versions (quadratic/cubic) have a finite blend range controlled by `k`, while exponential blends infinitely (but drops off quickly).

---

## Further Resources

- [Inigo Quilez — Distance Functions](https://iquilezles.org/articles/distfunctions/) — the definitive SDF reference
- [Inigo Quilez — Smooth Minimum](https://iquilezles.org/articles/smin/) — deep dive on smooth operations
- [Shadertoy](https://www.shadertoy.com/) — thousands of SDF raymarching examples (note: Shadertoy uses GLSL 300 es, not 100 — you'll need to adapt `in`/`out` → `varying`/`gl_FragColor`)
