# Ray Tracing in One Weekend — Zig + Raylib Edition

Based on [Peter Shirley's *Ray Tracing in One Weekend*](https://raytracing.github.io/books/RayTracingInOneWeekend.html), adapted to Zig and raylib.

Instead of writing PPM files, we render into a raylib image buffer and display the result in a window — watching the image come alive as it renders row by row.

## Prerequisites

- Zig 0.15+ installed
- This repository cloned and building (`zig build run` shows the demo window)
- Familiarity with basic linear algebra (vectors, dot products)

## Architecture

```
Ray tracer (Zig, f64 math)
    ↓ writes pixels
raylib Image buffer (CPU, RGBA u8)
    ↓ rl.UpdateTexture()
GPU Texture
    ↓ rl.DrawTextureEx()
Window (via GLFW → EGL → ANGLE → Metal)
```

The ray tracer runs on the CPU, computing color values per pixel. We write those into a raylib `Image` (a CPU-side pixel buffer), upload to a GPU texture, and draw it fullscreen. Progressive rendering keeps the window responsive during long renders.

---

## Chapter 1: Displaying an Image with Raylib

The original tutorial starts by writing a PPM image file. We replace that with a raylib window showing a gradient.

Replace `src/main.zig` with:

```zig
const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
});

pub fn main() void {
    const image_width = 256;
    const image_height = 256;
    const window_scale = 2;

    rl.InitWindow(
        image_width * window_scale,
        image_height * window_scale,
        "Ray Tracing in One Weekend",
    );
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // CPU-side image buffer
    const image = rl.GenImageColor(image_width, image_height, rl.BLACK);
    defer rl.UnloadImage(image);
    const pixels: [*]rl.Color = @ptrCast(@alignCast(image.data.?));

    // Write a gradient — equivalent to the book's first PPM output
    for (0..image_height) |j| {
        for (0..image_width) |i| {
            const fi: f64 = @floatFromInt(i);
            const fj: f64 = @floatFromInt(j);
            pixels[j * image_width + i] = .{
                .r = @intFromFloat(255.999 * fi / (image_width - 1)),
                .g = @intFromFloat(255.999 * fj / (image_height - 1)),
                .b = @intFromFloat(255.999 * 0.25),
                .a = 255,
            };
        }
    }

    // Upload to GPU
    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.DrawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, window_scale, rl.WHITE);
        rl.EndDrawing();
    }
}
```

Run with `zig build run`. You should see a 512x512 window with a red-green gradient and a blue tint — the classic first image from the book.

**Key differences from the book:**
- Instead of `std::cout` writing PPM bytes, we write RGBA pixels into `image.data`
- `@ptrCast(@alignCast(image.data.?))` converts raylib's `?*anyopaque` to a typed pixel pointer
- `rl.LoadTextureFromImage` uploads to the GPU; `rl.DrawTextureEx` draws it scaled up

---

## Chapter 2: The Vec3 Struct

The book uses a C++ `vec3` class with operator overloading. In Zig, we use a struct with methods. Add this above `main`:

```zig
const Vec3 = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }

    fn scale(v: Vec3, t: f64) Vec3 {
        return .{ .x = v.x * t, .y = v.y * t, .z = v.z * t };
    }

    fn div(v: Vec3, t: f64) Vec3 {
        return v.scale(1.0 / t);
    }

    fn neg(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }

    fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    fn length_squared(v: Vec3) f64 {
        return Vec3.dot(v, v);
    }

    fn length(v: Vec3) f64 {
        return @sqrt(v.length_squared());
    }

    fn unit_vector(v: Vec3) Vec3 {
        return v.div(v.length());
    }

    fn near_zero(v: Vec3) bool {
        const s = 1e-8;
        return @abs(v.x) < s and @abs(v.y) < s and @abs(v.z) < s;
    }
};

const Point3 = Vec3;
const Color = Vec3;
```

**Zig vs C++ notes:**
- No operator overloading — we use named methods: `a.add(b)` instead of `a + b`
- `f64` throughout, matching the book's `double`
- Default field values of `0` let us write `Color{}` for black
- Method calls chain nicely: `v.sub(w).unit_vector().scale(2.0)`

---

## Chapter 3: Rays, a Simple Camera, and Background

Add the `Ray` struct and `ray_color` function:

```zig
const Ray = struct {
    origin: Point3,
    direction: Vec3,

    fn at(self: Ray, t: f64) Point3 {
        return self.origin.add(self.direction.scale(t));
    }
};

fn ray_color(r: Ray) Color {
    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    // Lerp between white and sky blue
    const white = Color{ .x = 1.0, .y = 1.0, .z = 1.0 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}
```

Add a helper to convert our `Color` (0.0–1.0 f64) to raylib's `rl.Color` (0–255 u8):

```zig
fn vec_to_rl_color(color: Color) rl.Color {
    return .{
        .r = @intFromFloat(std.math.clamp(color.x, 0, 0.999) * 256),
        .g = @intFromFloat(std.math.clamp(color.y, 0, 0.999) * 256),
        .b = @intFromFloat(std.math.clamp(color.z, 0, 0.999) * 256),
        .a = 255,
    };
}
```

Now update `main` to trace rays through each pixel. Replace the gradient-writing code with a proper camera setup:

```zig
pub fn main() void {
    // Image
    const aspect_ratio = 16.0 / 9.0;
    const image_width = 400;
    const image_height: comptime_int = @intFromFloat(@as(f64, image_width) / aspect_ratio);
    const window_scale = 2;

    rl.InitWindow(
        image_width * window_scale,
        image_height * window_scale,
        "Ray Tracing in One Weekend",
    );
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // Camera
    const focal_length = 1.0;
    const viewport_height = 2.0;
    const viewport_width = viewport_height * (@as(f64, image_width) / @as(f64, image_height));
    const camera_center = Point3{};

    // Viewport vectors
    const viewport_u = Vec3{ .x = viewport_width };
    const viewport_v = Vec3{ .y = -viewport_height }; // y points down in image
    const pixel_delta_u = viewport_u.div(image_width);
    const pixel_delta_v = viewport_v.div(image_height);

    // Upper-left pixel
    const viewport_upper_left = camera_center
        .sub(Vec3{ .z = focal_length })
        .sub(viewport_u.div(2))
        .sub(viewport_v.div(2));
    const pixel00_loc = viewport_upper_left
        .add(pixel_delta_u.add(pixel_delta_v).scale(0.5));

    // Image buffer
    const image = rl.GenImageColor(image_width, image_height, rl.BLACK);
    defer rl.UnloadImage(image);
    const pixels: [*]rl.Color = @ptrCast(@alignCast(image.data.?));

    // Render
    for (0..image_height) |j| {
        for (0..image_width) |i| {
            const pixel_center = pixel00_loc
                .add(pixel_delta_u.scale(@floatFromInt(i)))
                .add(pixel_delta_v.scale(@floatFromInt(j)));
            const ray_direction = pixel_center.sub(camera_center);
            const r = Ray{ .origin = camera_center, .direction = ray_direction };

            const color = ray_color(r);
            pixels[j * image_width + i] = vec_to_rl_color(color);
        }
    }

    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.DrawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, window_scale, rl.WHITE);
        rl.EndDrawing();
    }
}
```

You should see the blue-to-white sky gradient from the book.

---

## Chapter 4: Adding a Sphere

Add a sphere intersection test. The math is identical to the book — we solve the quadratic equation for a ray hitting a sphere:

```zig
fn hit_sphere(center: Point3, radius: f64, r: Ray) f64 {
    const oc = center.sub(r.origin);
    const a = r.direction.length_squared();
    const h = Vec3.dot(r.direction, oc);
    const c = oc.length_squared() - radius * radius;
    const discriminant = h * h - a * c;

    if (discriminant < 0) {
        return -1.0;
    } else {
        return (h - @sqrt(discriminant)) / a;
    }
}
```

Update `ray_color` to test against a sphere at (0, 0, -1):

```zig
fn ray_color(r: Ray) Color {
    // Sphere hit → red
    if (hit_sphere(Point3{ .z = -1 }, 0.5, r) > 0.0) {
        return Color{ .x = 1, .y = 0, .z = 0 };
    }

    // Sky gradient
    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    const white = Color{ .x = 1, .y = 1, .z = 1 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}
```

You should see a red circle on the sky background.

Now update it to visualize surface normals (the normal at the hit point mapped to color):

```zig
fn ray_color(r: Ray) Color {
    const sphere_center = Point3{ .z = -1 };
    const t = hit_sphere(sphere_center, 0.5, r);
    if (t > 0.0) {
        const n = r.at(t).sub(sphere_center).unit_vector();
        return Color{ .x = n.x + 1, .y = n.y + 1, .z = n.z + 1 }.scale(0.5);
    }

    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    const white = Color{ .x = 1, .y = 1, .z = 1 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}
```

The sphere now shows a colorful normal map — the classic image from the book.

---

## Chapter 5: Surface Normals and Multiple Objects

Time to generalize. Instead of hard-coding one sphere in `ray_color`, we create a proper hit-testing system.

The book uses C++ class inheritance (`Hittable` base class). In Zig, we keep it simple — since we only have spheres, we use a `Sphere` struct with a `hit` method and iterate over a slice.

Add these types:

```zig
const HitRecord = struct {
    p: Point3 = .{},
    normal: Vec3 = .{},
    t: f64 = 0,
    front_face: bool = true,

    fn set_face_normal(self: *HitRecord, r: Ray, outward_normal: Vec3) void {
        self.front_face = Vec3.dot(r.direction, outward_normal) < 0;
        self.normal = if (self.front_face) outward_normal else outward_normal.neg();
    }
};

const Sphere = struct {
    center: Point3,
    radius: f64,

    fn hit(self: Sphere, r: Ray, ray_tmin: f64, ray_tmax: f64, rec: *HitRecord) bool {
        const oc = self.center.sub(r.origin);
        const a = r.direction.length_squared();
        const h = Vec3.dot(r.direction, oc);
        const c = oc.length_squared() - self.radius * self.radius;
        const discriminant = h * h - a * c;

        if (discriminant < 0) return false;

        const sqrtd = @sqrt(discriminant);

        // Find the nearest root in the acceptable range
        var root = (h - sqrtd) / a;
        if (root <= ray_tmin or ray_tmax <= root) {
            root = (h + sqrtd) / a;
            if (root <= ray_tmin or ray_tmax <= root) return false;
        }

        rec.t = root;
        rec.p = r.at(root);
        const outward_normal = rec.p.sub(self.center).div(self.radius);
        rec.set_face_normal(r, outward_normal);
        return true;
    }
};
```

Add a function to test a ray against all spheres:

```zig
fn world_hit(world: []const Sphere, r: Ray, ray_tmin: f64, ray_tmax: f64) ?HitRecord {
    var rec: HitRecord = undefined;
    var hit_anything = false;
    var closest = ray_tmax;

    for (world) |sphere| {
        var temp: HitRecord = undefined;
        if (sphere.hit(r, ray_tmin, closest, &temp)) {
            hit_anything = true;
            closest = temp.t;
            rec = temp;
        }
    }

    return if (hit_anything) rec else null;
}
```

Update `ray_color` to use the world:

```zig
fn ray_color(r: Ray, world: []const Sphere) Color {
    if (world_hit(world, r, 0.001, std.math.inf(f64))) |rec| {
        return rec.normal.add(Vec3{ .x = 1, .y = 1, .z = 1 }).scale(0.5);
    }

    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    const white = Color{ .x = 1, .y = 1, .z = 1 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}
```

In `main`, set up the scene (a sphere on a large ground sphere) and pass the world to `ray_color`:

```zig
    // Scene — the book's two-sphere setup
    const world = [_]Sphere{
        .{ .center = .{ .y = 0, .z = -1 }, .radius = 0.5 },
        .{ .center = .{ .y = -100.5, .z = -1 }, .radius = 100 },
    };

    // In the render loop, change the ray_color call:
    const color = ray_color(r, &world);
```

You should see the sphere sitting on a green-ish ground plane (the large sphere's surface normals pointing mostly up appear green).

Remove the old `hit_sphere` function — it's been replaced by `Sphere.hit`.

---

## Chapter 6: Antialiasing

Antialiasing sends multiple rays per pixel with slight random offsets, then averages the results. This is where rendering starts taking real time, so we introduce **progressive rendering** — processing a few rows per frame to keep the window responsive.

We need a random number generator. Add this near the top:

```zig
fn random_double(rng: *std.Random.DefaultPrng) f64 {
    return rng.random().float(f64);
}

fn random_double_range(rng: *std.Random.DefaultPrng, min: f64, max: f64) f64 {
    return min + (max - min) * rng.random().float(f64);
}
```

Now restructure `main` for progressive rendering. This is a significant rewrite — here's the complete updated `main`:

```zig
pub fn main() void {
    // Image
    const aspect_ratio = 16.0 / 9.0;
    const image_width = 400;
    const image_height: comptime_int = @intFromFloat(@as(f64, image_width) / aspect_ratio);
    const window_scale = 2;
    const samples_per_pixel = 10;
    const pixel_samples_scale = 1.0 / @as(f64, samples_per_pixel);

    rl.InitWindow(
        image_width * window_scale,
        image_height * window_scale,
        "Ray Tracing in One Weekend",
    );
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // Camera
    const focal_length = 1.0;
    const viewport_height = 2.0;
    const viewport_width = viewport_height * (@as(f64, image_width) / @as(f64, image_height));
    const camera_center = Point3{};

    const viewport_u = Vec3{ .x = viewport_width };
    const viewport_v = Vec3{ .y = -viewport_height };
    const pixel_delta_u = viewport_u.div(image_width);
    const pixel_delta_v = viewport_v.div(image_height);

    const viewport_upper_left = camera_center
        .sub(Vec3{ .z = focal_length })
        .sub(viewport_u.div(2))
        .sub(viewport_v.div(2));
    const pixel00_loc = viewport_upper_left
        .add(pixel_delta_u.add(pixel_delta_v).scale(0.5));

    // Scene
    const world = [_]Sphere{
        .{ .center = .{ .y = 0, .z = -1 }, .radius = 0.5 },
        .{ .center = .{ .y = -100.5, .z = -1 }, .radius = 100 },
    };

    // Image buffer
    const image = rl.GenImageColor(image_width, image_height, rl.BLACK);
    defer rl.UnloadImage(image);
    const pixels: [*]rl.Color = @ptrCast(@alignCast(image.data.?));

    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    // Progressive rendering state
    var rng = std.Random.DefaultPrng.init(42);
    var current_row: usize = 0;
    const rows_per_frame = 4;

    while (!rl.WindowShouldClose()) {
        // Render a few rows each frame
        if (current_row < image_height) {
            const end_row = @min(current_row + rows_per_frame, @as(usize, image_height));
            var j = current_row;
            while (j < end_row) : (j += 1) {
                for (0..image_width) |i| {
                    var pixel_color = Color{};
                    for (0..samples_per_pixel) |_| {
                        const offset_x = random_double(&rng) - 0.5;
                        const offset_y = random_double(&rng) - 0.5;
                        const pixel_center = pixel00_loc
                            .add(pixel_delta_u.scale(@as(f64, @floatFromInt(i)) + offset_x))
                            .add(pixel_delta_v.scale(@as(f64, @floatFromInt(j)) + offset_y));
                        const ray_direction = pixel_center.sub(camera_center);
                        const r = Ray{ .origin = camera_center, .direction = ray_direction };
                        pixel_color = pixel_color.add(ray_color(r, &world));
                    }
                    pixels[j * image_width + i] = vec_to_rl_color(pixel_color.scale(pixel_samples_scale));
                }
            }
            current_row = end_row;
            rl.UpdateTexture(texture, image.data);
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.DrawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, window_scale, rl.WHITE);
        if (current_row < image_height) {
            rl.DrawText(
                rl.TextFormat("Rendering: %d%%", @as(c_int, @intCast(current_row * 100 / image_height))),
                10, 10, 20, rl.WHITE,
            );
        } else {
            rl.DrawText("Done! Press ESC to exit.", 10, 10, 20, rl.GREEN);
        }
        rl.EndDrawing();
    }
}
```

**What changed:**
- Rendering moved *inside* the window loop, processing `rows_per_frame` rows per frame
- Each pixel gets `samples_per_pixel` jittered rays, averaged together
- `rl.UpdateTexture` uploads the latest pixels after each batch of rows
- A progress indicator shows rendering status
- The image fills in top-to-bottom while the window stays responsive

The antialiased sphere edges should look noticeably smoother.

---

## Chapter 7: Diffuse Materials

Diffuse (Lambertian) surfaces scatter light in random directions. We need random vector utilities:

```zig
fn random_vec3(rng: *std.Random.DefaultPrng) Vec3 {
    return .{
        .x = random_double(rng),
        .y = random_double(rng),
        .z = random_double(rng),
    };
}

fn random_vec3_range(rng: *std.Random.DefaultPrng, min: f64, max: f64) Vec3 {
    return .{
        .x = random_double_range(rng, min, max),
        .y = random_double_range(rng, min, max),
        .z = random_double_range(rng, min, max),
    };
}

fn random_unit_vector(rng: *std.Random.DefaultPrng) Vec3 {
    while (true) {
        const p = random_vec3_range(rng, -1, 1);
        const lensq = p.length_squared();
        if (lensq > 1e-160 and lensq <= 1)
            return p.div(@sqrt(lensq));
    }
}

fn random_on_hemisphere(rng: *std.Random.DefaultPrng, normal: Vec3) Vec3 {
    const on_unit_sphere = random_unit_vector(rng);
    if (Vec3.dot(on_unit_sphere, normal) > 0.0) return on_unit_sphere;
    return on_unit_sphere.neg();
}
```

Update `ray_color` to bounce rays (Lambertian scattering). We add a `max_depth` parameter to limit recursion. Note: Zig doesn't have implicit recursion limits — we use an explicit depth counter:

```zig
fn ray_color(r: Ray, world: []const Sphere, depth: usize, rng: *std.Random.DefaultPrng) Color {
    if (depth == 0) return Color{};

    if (world_hit(world, r, 0.001, std.math.inf(f64))) |rec| {
        const direction = rec.normal.add(random_unit_vector(rng));
        const bounced = Ray{ .origin = rec.p, .direction = direction };
        return ray_color(bounced, world, depth - 1, rng).scale(0.5);
    }

    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    const white = Color{ .x = 1, .y = 1, .z = 1 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}
```

Update the call in `main` (add `max_depth` and `rng`):

```zig
    const max_depth = 50;
    // ... in the render loop:
    pixel_color = pixel_color.add(ray_color(r, &world, max_depth, &rng));
```

**Gamma correction** — the image looks too dark because we're viewing linear color values. Add gamma correction to `vec_to_rl_color`:

```zig
fn linear_to_gamma(linear: f64) f64 {
    if (linear > 0) return @sqrt(linear);
    return 0;
}

fn vec_to_rl_color(color: Color) rl.Color {
    const r = linear_to_gamma(color.x);
    const g = linear_to_gamma(color.y);
    const b = linear_to_gamma(color.z);
    return .{
        .r = @intFromFloat(std.math.clamp(r, 0, 0.999) * 256),
        .g = @intFromFloat(std.math.clamp(g, 0, 0.999) * 256),
        .b = @intFromFloat(std.math.clamp(b, 0, 0.999) * 256),
        .a = 255,
    };
}
```

The sphere now appears as a soft gray diffuse surface against the sky.

---

## Chapter 8: Metal

Time for materials! The book uses C++ class inheritance. In Zig, we use a **tagged union** — a natural fit since a material is exactly one of several variants.

First, add the `reflect` helper:

```zig
fn reflect(v: Vec3, n: Vec3) Vec3 {
    return v.sub(n.scale(2.0 * Vec3.dot(v, n)));
}
```

Define the material system:

```zig
const ScatterResult = struct {
    attenuation: Color,
    scattered: Ray,
};

const Lambertian = struct {
    albedo: Color,

    fn scatter(self: Lambertian, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        var direction = rec.normal.add(random_unit_vector(rng));
        if (direction.near_zero()) direction = rec.normal;
        return .{
            .attenuation = self.albedo,
            .scattered = .{ .origin = rec.p, .direction = direction },
        };
    }
};

const Metal = struct {
    albedo: Color,
    fuzz: f64,

    fn scatter(self: Metal, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        var reflected = reflect(r_in.direction, rec.normal);
        reflected = reflected.unit_vector().add(random_unit_vector(rng).scale(self.fuzz));
        if (Vec3.dot(reflected, rec.normal) <= 0) return null;
        return .{
            .attenuation = self.albedo,
            .scattered = .{ .origin = rec.p, .direction = reflected },
        };
    }
};

const Material = union(enum) {
    lambertian: Lambertian,
    metal: Metal,

    fn scatter(self: Material, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        return switch (self) {
            .lambertian => |m| m.scatter(rec, rng),
            .metal => |m| m.scatter(r_in, rec, rng),
        };
    }
};
```

Add a `mat` field to `HitRecord` and `Sphere`:

```zig
const HitRecord = struct {
    p: Point3 = .{},
    normal: Vec3 = .{},
    t: f64 = 0,
    front_face: bool = true,
    mat: Material = .{ .lambertian = .{ .albedo = .{} } },

    // ... set_face_normal unchanged
};

const Sphere = struct {
    center: Point3,
    radius: f64,
    mat: Material,

    fn hit(self: Sphere, r: Ray, ray_tmin: f64, ray_tmax: f64, rec: *HitRecord) bool {
        // ... same intersection math ...
        rec.mat = self.mat; // Add this line after setting p, t, normal
        return true;
    }
};
```

Update `ray_color` to use materials:

```zig
fn ray_color(r: Ray, world: []const Sphere, depth: usize, rng: *std.Random.DefaultPrng) Color {
    if (depth == 0) return Color{};

    if (world_hit(world, r, 0.001, std.math.inf(f64))) |rec| {
        if (rec.mat.scatter(r, rec, rng)) |result| {
            return ray_color(result.scattered, world, depth - 1, rng)
                .mul(result.attenuation);
        }
        return Color{};
    }

    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    const white = Color{ .x = 1, .y = 1, .z = 1 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}
```

Update the scene in `main`:

```zig
    const mat_ground = Material{ .lambertian = .{ .albedo = .{ .x = 0.8, .y = 0.8, .z = 0.0 } } };
    const mat_center = Material{ .lambertian = .{ .albedo = .{ .x = 0.1, .y = 0.2, .z = 0.5 } } };
    const mat_left = Material{ .metal = .{ .albedo = .{ .x = 0.8, .y = 0.8, .z = 0.8 }, .fuzz = 0.3 } };
    const mat_right = Material{ .metal = .{ .albedo = .{ .x = 0.8, .y = 0.6, .z = 0.2 }, .fuzz = 1.0 } };

    const world = [_]Sphere{
        .{ .center = .{ .y = -100.5, .z = -1 }, .radius = 100, .mat = mat_ground },
        .{ .center = .{ .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_center },
        .{ .center = .{ .x = -1, .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_left },
        .{ .center = .{ .x = 1, .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_right },
    };
```

You should see a blue diffuse sphere flanked by two shiny metal spheres on a yellowish ground.

---

## Chapter 9: Dielectrics

Glass and water refract light. Add the `refract` function and Schlick's reflectance approximation:

```zig
fn refract(uv: Vec3, n: Vec3, etai_over_etat: f64) Vec3 {
    const cos_theta = @min(Vec3.dot(uv.neg(), n), 1.0);
    const r_out_perp = uv.add(n.scale(cos_theta)).scale(etai_over_etat);
    const r_out_parallel = n.scale(-@sqrt(@abs(1.0 - r_out_perp.length_squared())));
    return r_out_perp.add(r_out_parallel);
}

fn reflectance(cosine: f64, ri: f64) f64 {
    // Schlick's approximation
    var r0 = (1.0 - ri) / (1.0 + ri);
    r0 = r0 * r0;
    return r0 + (1.0 - r0) * std.math.pow(f64, 1.0 - cosine, 5);
}
```

Add the `Dielectric` material:

```zig
const Dielectric = struct {
    refraction_index: f64,

    fn scatter(self: Dielectric, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        const ri = if (rec.front_face) 1.0 / self.refraction_index else self.refraction_index;
        const unit_direction = r_in.direction.unit_vector();

        const cos_theta = @min(Vec3.dot(unit_direction.neg(), rec.normal), 1.0);
        const sin_theta = @sqrt(1.0 - cos_theta * cos_theta);
        const cannot_refract = ri * sin_theta > 1.0;

        const direction = if (cannot_refract or reflectance(cos_theta, ri) > random_double(rng))
            reflect(unit_direction, rec.normal)
        else
            refract(unit_direction, rec.normal, ri);

        return .{
            .attenuation = Color{ .x = 1, .y = 1, .z = 1 },
            .scattered = .{ .origin = rec.p, .direction = direction },
        };
    }
};
```

Add `.dielectric` to the `Material` tagged union:

```zig
const Material = union(enum) {
    lambertian: Lambertian,
    metal: Metal,
    dielectric: Dielectric,

    fn scatter(self: Material, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        return switch (self) {
            .lambertian => |m| m.scatter(rec, rng),
            .metal => |m| m.scatter(r_in, rec, rng),
            .dielectric => |m| m.scatter(r_in, rec, rng),
        };
    }
};
```

Update the scene — replace the left metal sphere with glass, and add the "hollow glass sphere" trick (a sphere with negative radius inverts the normals, creating a hollow bubble):

```zig
    const mat_ground = Material{ .lambertian = .{ .albedo = .{ .x = 0.8, .y = 0.8, .z = 0.0 } } };
    const mat_center = Material{ .lambertian = .{ .albedo = .{ .x = 0.1, .y = 0.2, .z = 0.5 } } };
    const mat_left = Material{ .dielectric = .{ .refraction_index = 1.50 } };
    const mat_bubble = Material{ .dielectric = .{ .refraction_index = 1.00 / 1.50 } };
    const mat_right = Material{ .metal = .{ .albedo = .{ .x = 0.8, .y = 0.6, .z = 0.2 }, .fuzz = 1.0 } };

    const world = [_]Sphere{
        .{ .center = .{ .y = -100.5, .z = -1 }, .radius = 100, .mat = mat_ground },
        .{ .center = .{ .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_center },
        .{ .center = .{ .x = -1, .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_left },
        .{ .center = .{ .x = -1, .y = 0, .z = -1 }, .radius = 0.4, .mat = mat_bubble },
        .{ .center = .{ .x = 1, .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_right },
    };
```

The left sphere now appears as a hollow glass ball. Note the bubble trick: the inner sphere uses the reciprocal refraction index (`1.0 / 1.5`), which is equivalent to using a negative radius in the original book.

---

## Chapter 10: Positionable Camera

So far the camera is fixed at the origin looking down -Z. Let's make it configurable with field of view, position, and orientation.

Replace the manual camera setup in `main` with a `Camera` struct:

```zig
const CameraConfig = struct {
    image_width: u32 = 400,
    aspect_ratio: f64 = 16.0 / 9.0,
    samples_per_pixel: u32 = 10,
    max_depth: u32 = 50,

    vfov: f64 = 90,
    lookfrom: Point3 = .{ .z = 0 },
    lookat: Point3 = .{ .z = -1 },
    vup: Vec3 = .{ .y = 1 },

    defocus_angle: f64 = 0,
    focus_dist: f64 = 10,
};

const Camera = struct {
    image_width: u32,
    image_height: u32,
    center: Point3,
    pixel00_loc: Point3,
    pixel_delta_u: Vec3,
    pixel_delta_v: Vec3,
    samples_per_pixel: u32,
    max_depth: u32,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,
    defocus_angle: f64,

    fn init(cfg: CameraConfig) Camera {
        const image_height_f = @max(@as(f64, @floatFromInt(cfg.image_width)) / cfg.aspect_ratio, 1);
        const image_height: u32 = @intFromFloat(image_height_f);

        const theta = cfg.vfov * std.math.pi / 180.0;
        const h = @tan(theta / 2.0);
        const viewport_height = 2.0 * h * cfg.focus_dist;
        const viewport_width = viewport_height * (@as(f64, @floatFromInt(cfg.image_width)) / @as(f64, @floatFromInt(image_height)));

        const w = cfg.lookfrom.sub(cfg.lookat).unit_vector();
        const u = Vec3.cross(cfg.vup, w).unit_vector();
        const v = Vec3.cross(w, u);

        const viewport_u = u.scale(viewport_width);
        const viewport_v = v.neg().scale(viewport_height);
        const pixel_delta_u = viewport_u.div(@floatFromInt(cfg.image_width));
        const pixel_delta_v = viewport_v.div(@floatFromInt(image_height));

        const viewport_upper_left = cfg.lookfrom
            .sub(w.scale(cfg.focus_dist))
            .sub(viewport_u.scale(0.5))
            .sub(viewport_v.scale(0.5));
        const pixel00_loc = viewport_upper_left
            .add(pixel_delta_u.add(pixel_delta_v).scale(0.5));

        const defocus_radius = cfg.focus_dist * @tan(cfg.defocus_angle / 2.0 * std.math.pi / 180.0);

        return .{
            .image_width = cfg.image_width,
            .image_height = image_height,
            .center = cfg.lookfrom,
            .pixel00_loc = pixel00_loc,
            .pixel_delta_u = pixel_delta_u,
            .pixel_delta_v = pixel_delta_v,
            .samples_per_pixel = cfg.samples_per_pixel,
            .max_depth = cfg.max_depth,
            .defocus_disk_u = u.scale(defocus_radius),
            .defocus_disk_v = v.scale(defocus_radius),
            .defocus_angle = cfg.defocus_angle,
        };
    }

    fn get_ray(self: Camera, i: usize, j: usize, rng: *std.Random.DefaultPrng) Ray {
        const offset_x = random_double(rng) - 0.5;
        const offset_y = random_double(rng) - 0.5;
        const pixel_center = self.pixel00_loc
            .add(self.pixel_delta_u.scale(@as(f64, @floatFromInt(i)) + offset_x))
            .add(self.pixel_delta_v.scale(@as(f64, @floatFromInt(j)) + offset_y));

        const origin = if (self.defocus_angle <= 0) self.center else self.defocus_disk_sample(rng);
        return .{ .origin = origin, .direction = pixel_center.sub(origin) };
    }

    fn defocus_disk_sample(self: Camera, rng: *std.Random.DefaultPrng) Point3 {
        const p = random_in_unit_disk(rng);
        return self.center
            .add(self.defocus_disk_u.scale(p.x))
            .add(self.defocus_disk_v.scale(p.y));
    }
};

fn random_in_unit_disk(rng: *std.Random.DefaultPrng) Vec3 {
    while (true) {
        const p = Vec3{
            .x = random_double_range(rng, -1, 1),
            .y = random_double_range(rng, -1, 1),
        };
        if (p.length_squared() < 1) return p;
    }
}
```

Now rewrite `main` to use the Camera. Try the book's elevated view:

```zig
pub fn main() void {
    const cam = Camera.init(.{
        .image_width = 400,
        .samples_per_pixel = 10,
        .max_depth = 50,
        .vfov = 20,
        .lookfrom = .{ .x = -2, .y = 2, .z = 1 },
        .lookat = .{ .x = 0, .y = 0, .z = -1 },
        .vup = .{ .y = 1 },
    });

    const window_scale = 2;
    rl.InitWindow(
        @as(c_int, @intCast(cam.image_width)) * window_scale,
        @as(c_int, @intCast(cam.image_height)) * window_scale,
        "Ray Tracing in One Weekend",
    );
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // Scene (same as chapter 9)
    const mat_ground = Material{ .lambertian = .{ .albedo = .{ .x = 0.8, .y = 0.8, .z = 0.0 } } };
    const mat_center = Material{ .lambertian = .{ .albedo = .{ .x = 0.1, .y = 0.2, .z = 0.5 } } };
    const mat_left = Material{ .dielectric = .{ .refraction_index = 1.50 } };
    const mat_bubble = Material{ .dielectric = .{ .refraction_index = 1.00 / 1.50 } };
    const mat_right = Material{ .metal = .{ .albedo = .{ .x = 0.8, .y = 0.6, .z = 0.2 }, .fuzz = 1.0 } };

    const world = [_]Sphere{
        .{ .center = .{ .y = -100.5, .z = -1 }, .radius = 100, .mat = mat_ground },
        .{ .center = .{ .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_center },
        .{ .center = .{ .x = -1, .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_left },
        .{ .center = .{ .x = -1, .y = 0, .z = -1 }, .radius = 0.4, .mat = mat_bubble },
        .{ .center = .{ .x = 1, .y = 0, .z = -1 }, .radius = 0.5, .mat = mat_right },
    };

    // Image buffer
    const image = rl.GenImageColor(
        @intCast(cam.image_width),
        @intCast(cam.image_height),
        rl.BLACK,
    );
    defer rl.UnloadImage(image);
    const pixels: [*]rl.Color = @ptrCast(@alignCast(image.data.?));

    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    // Progressive rendering
    var rng = std.Random.DefaultPrng.init(42);
    var current_row: usize = 0;
    const rows_per_frame = 4;
    const pixel_samples_scale = 1.0 / @as(f64, @floatFromInt(cam.samples_per_pixel));

    while (!rl.WindowShouldClose()) {
        if (current_row < cam.image_height) {
            const end_row = @min(current_row + rows_per_frame, @as(usize, cam.image_height));
            var j = current_row;
            while (j < end_row) : (j += 1) {
                for (0..cam.image_width) |i| {
                    var pixel_color = Color{};
                    for (0..cam.samples_per_pixel) |_| {
                        const r = cam.get_ray(i, j, &rng);
                        pixel_color = pixel_color.add(ray_color(r, &world, cam.max_depth, &rng));
                    }
                    pixels[j * cam.image_width + i] = vec_to_rl_color(pixel_color.scale(pixel_samples_scale));
                }
            }
            current_row = end_row;
            rl.UpdateTexture(texture, image.data);
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.DrawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, window_scale, rl.WHITE);
        if (current_row < cam.image_height) {
            rl.DrawText(
                rl.TextFormat("Rendering: %d%%", @as(c_int, @intCast(current_row * 100 / cam.image_height))),
                10, 10, 20, rl.WHITE,
            );
        } else {
            rl.DrawText("Done! Press ESC to exit.", 10, 10, 20, rl.GREEN);
        }
        rl.EndDrawing();
    }
}
```

The camera now views the scene from an elevated angle with a narrow field of view. Try changing `vfov`, `lookfrom`, and `lookat` to explore the scene.

---

## Chapter 11: Defocus Blur (Depth of Field)

The Camera struct already has defocus blur support (we added it in the previous chapter for completeness). To enable it, just set `defocus_angle` and `focus_dist` in the config:

```zig
    const cam = Camera.init(.{
        .image_width = 400,
        .samples_per_pixel = 10,
        .max_depth = 50,
        .vfov = 20,
        .lookfrom = .{ .x = -2, .y = 2, .z = 1 },
        .lookat = .{ .x = 0, .y = 0, .z = -1 },
        .vup = .{ .y = 1 },
        .defocus_angle = 10.0,
        .focus_dist = 3.4,
    });
```

**How it works:**
- `defocus_angle` controls the size of the lens aperture (bigger = more blur)
- `focus_dist` sets the distance at which objects are perfectly sharp
- Each ray originates from a random point on the defocus disk (a thin lens) instead of a single point
- Objects at `focus_dist` from the camera are sharp; closer and farther objects blur

The three spheres should now show depth-of-field blur, with the focused sphere sharp and others soft.

---

## Chapter 12: Final Render

The classic "random spheres" scene from the book cover. We generate a field of small random spheres around three large featured spheres.

Since the sphere count is dynamic, we use a bounded buffer:

```zig
const World = struct {
    spheres: [500]Sphere = undefined,
    len: usize = 0,

    fn add(self: *World, sphere: Sphere) void {
        self.spheres[self.len] = sphere;
        self.len += 1;
    }

    fn items(self: *const World) []const Sphere {
        return self.spheres[0..self.len];
    }
};
```

Here is the scene setup function:

```zig
fn random_scene(rng: *std.Random.DefaultPrng) World {
    var world = World{};

    // Ground
    world.add(.{
        .center = .{ .y = -1000 },
        .radius = 1000,
        .mat = .{ .lambertian = .{ .albedo = .{ .x = 0.5, .y = 0.5, .z = 0.5 } } },
    });

    // Small random spheres
    var a: i32 = -11;
    while (a < 11) : (a += 1) {
        var b: i32 = -11;
        while (b < 11) : (b += 1) {
            const choose_mat = random_double(rng);
            const center = Point3{
                .x = @as(f64, @floatFromInt(a)) + 0.9 * random_double(rng),
                .y = 0.2,
                .z = @as(f64, @floatFromInt(b)) + 0.9 * random_double(rng),
            };

            if (center.sub(Point3{ .x = 4, .y = 0.2 }).length() > 0.9) {
                if (choose_mat < 0.8) {
                    // Diffuse
                    const albedo = random_vec3(rng).mul(random_vec3(rng));
                    world.add(.{
                        .center = center,
                        .radius = 0.2,
                        .mat = .{ .lambertian = .{ .albedo = albedo } },
                    });
                } else if (choose_mat < 0.95) {
                    // Metal
                    const albedo = random_vec3_range(rng, 0.5, 1);
                    const fuzz = random_double_range(rng, 0, 0.5);
                    world.add(.{
                        .center = center,
                        .radius = 0.2,
                        .mat = .{ .metal = .{ .albedo = albedo, .fuzz = fuzz } },
                    });
                } else {
                    // Glass
                    world.add(.{
                        .center = center,
                        .radius = 0.2,
                        .mat = .{ .dielectric = .{ .refraction_index = 1.5 } },
                    });
                }
            }
        }
    }

    // Three big spheres
    world.add(.{
        .center = .{ .y = 1 },
        .radius = 1,
        .mat = .{ .dielectric = .{ .refraction_index = 1.5 } },
    });
    world.add(.{
        .center = .{ .x = -4, .y = 1 },
        .radius = 1,
        .mat = .{ .lambertian = .{ .albedo = .{ .x = 0.4, .y = 0.2, .z = 0.1 } } },
    });
    world.add(.{
        .center = .{ .x = 4, .y = 1 },
        .radius = 1,
        .mat = .{ .metal = .{ .albedo = .{ .x = 0.7, .y = 0.6, .z = 0.5 }, .fuzz = 0 } },
    });

    return world;
}
```

Update the call in `main` to use `world_hit` with the world items:

```zig
    // Change world_hit calls to use world.items()
    pixel_color = pixel_color.add(ray_color(r, world.items(), cam.max_depth, &rng));
```

And the camera for the book's final view:

```zig
    const cam = Camera.init(.{
        .image_width = 800,
        .samples_per_pixel = 50,
        .max_depth = 50,
        .vfov = 20,
        .lookfrom = .{ .x = 13, .y = 2, .z = 3 },
        .lookat = .{ .y = 0 },
        .vup = .{ .y = 1 },
        .defocus_angle = 0.6,
        .focus_dist = 10.0,
    });
```

> **Render time:** At 800x450, 50 samples, this takes a minute or two. You can watch it fill in progressively. For higher quality, increase `samples_per_pixel` to 100-500 (and go get coffee).

---

## Complete Final Code

Here is the entire `src/main.zig` for the final render. Copy this in and run `zig build run`.

```zig
const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
});

// ============================================================
// Vec3
// ============================================================

const Vec3 = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    fn scale(v: Vec3, t: f64) Vec3 {
        return .{ .x = v.x * t, .y = v.y * t, .z = v.z * t };
    }
    fn div(v: Vec3, t: f64) Vec3 {
        return v.scale(1.0 / t);
    }
    fn neg(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }
    fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    fn length_squared(v: Vec3) f64 {
        return Vec3.dot(v, v);
    }
    fn length(v: Vec3) f64 {
        return @sqrt(v.length_squared());
    }
    fn unit_vector(v: Vec3) Vec3 {
        return v.div(v.length());
    }
    fn near_zero(v: Vec3) bool {
        const s = 1e-8;
        return @abs(v.x) < s and @abs(v.y) < s and @abs(v.z) < s;
    }
};

const Point3 = Vec3;
const Color = Vec3;

// ============================================================
// Ray
// ============================================================

const Ray = struct {
    origin: Point3,
    direction: Vec3,

    fn at(self: Ray, t: f64) Point3 {
        return self.origin.add(self.direction.scale(t));
    }
};

// ============================================================
// Materials
// ============================================================

const ScatterResult = struct {
    attenuation: Color,
    scattered: Ray,
};

const Lambertian = struct {
    albedo: Color,

    fn scatter(self: Lambertian, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        var direction = rec.normal.add(random_unit_vector(rng));
        if (direction.near_zero()) direction = rec.normal;
        return .{
            .attenuation = self.albedo,
            .scattered = .{ .origin = rec.p, .direction = direction },
        };
    }
};

const Metal = struct {
    albedo: Color,
    fuzz: f64,

    fn scatter(self: Metal, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        var reflected = reflect(r_in.direction, rec.normal);
        reflected = reflected.unit_vector().add(random_unit_vector(rng).scale(self.fuzz));
        if (Vec3.dot(reflected, rec.normal) <= 0) return null;
        return .{
            .attenuation = self.albedo,
            .scattered = .{ .origin = rec.p, .direction = reflected },
        };
    }
};

const Dielectric = struct {
    refraction_index: f64,

    fn scatter(self: Dielectric, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        const ri = if (rec.front_face) 1.0 / self.refraction_index else self.refraction_index;
        const unit_direction = r_in.direction.unit_vector();
        const cos_theta = @min(Vec3.dot(unit_direction.neg(), rec.normal), 1.0);
        const sin_theta = @sqrt(1.0 - cos_theta * cos_theta);
        const cannot_refract = ri * sin_theta > 1.0;

        const direction = if (cannot_refract or schlick_reflectance(cos_theta, ri) > random_double(rng))
            reflect(unit_direction, rec.normal)
        else
            refract(unit_direction, rec.normal, ri);

        return .{
            .attenuation = Color{ .x = 1, .y = 1, .z = 1 },
            .scattered = .{ .origin = rec.p, .direction = direction },
        };
    }
};

const Material = union(enum) {
    lambertian: Lambertian,
    metal: Metal,
    dielectric: Dielectric,

    fn scatter(self: Material, r_in: Ray, rec: HitRecord, rng: *std.Random.DefaultPrng) ?ScatterResult {
        return switch (self) {
            .lambertian => |m| m.scatter(rec, rng),
            .metal => |m| m.scatter(r_in, rec, rng),
            .dielectric => |m| m.scatter(r_in, rec, rng),
        };
    }
};

// ============================================================
// Hit testing
// ============================================================

const HitRecord = struct {
    p: Point3 = .{},
    normal: Vec3 = .{},
    t: f64 = 0,
    front_face: bool = true,
    mat: Material = .{ .lambertian = .{ .albedo = .{} } },

    fn set_face_normal(self: *HitRecord, r: Ray, outward_normal: Vec3) void {
        self.front_face = Vec3.dot(r.direction, outward_normal) < 0;
        self.normal = if (self.front_face) outward_normal else outward_normal.neg();
    }
};

const Sphere = struct {
    center: Point3,
    radius: f64,
    mat: Material,

    fn hit(self: Sphere, r: Ray, ray_tmin: f64, ray_tmax: f64, rec: *HitRecord) bool {
        const oc = self.center.sub(r.origin);
        const a = r.direction.length_squared();
        const h = Vec3.dot(r.direction, oc);
        const c = oc.length_squared() - self.radius * self.radius;
        const discriminant = h * h - a * c;
        if (discriminant < 0) return false;

        const sqrtd = @sqrt(discriminant);
        var root = (h - sqrtd) / a;
        if (root <= ray_tmin or ray_tmax <= root) {
            root = (h + sqrtd) / a;
            if (root <= ray_tmin or ray_tmax <= root) return false;
        }

        rec.t = root;
        rec.p = r.at(root);
        const outward_normal = rec.p.sub(self.center).div(self.radius);
        rec.set_face_normal(r, outward_normal);
        rec.mat = self.mat;
        return true;
    }
};

const World = struct {
    spheres: [500]Sphere = undefined,
    len: usize = 0,

    fn add(self: *World, sphere: Sphere) void {
        self.spheres[self.len] = sphere;
        self.len += 1;
    }

    fn items(self: *const World) []const Sphere {
        return self.spheres[0..self.len];
    }
};

fn world_hit(world: []const Sphere, r: Ray, ray_tmin: f64, ray_tmax: f64) ?HitRecord {
    var rec: HitRecord = undefined;
    var hit_anything = false;
    var closest = ray_tmax;

    for (world) |sphere| {
        var temp: HitRecord = undefined;
        if (sphere.hit(r, ray_tmin, closest, &temp)) {
            hit_anything = true;
            closest = temp.t;
            rec = temp;
        }
    }

    return if (hit_anything) rec else null;
}

// ============================================================
// Camera
// ============================================================

const CameraConfig = struct {
    image_width: u32 = 400,
    aspect_ratio: f64 = 16.0 / 9.0,
    samples_per_pixel: u32 = 10,
    max_depth: u32 = 50,
    vfov: f64 = 90,
    lookfrom: Point3 = .{ .z = 0 },
    lookat: Point3 = .{ .z = -1 },
    vup: Vec3 = .{ .y = 1 },
    defocus_angle: f64 = 0,
    focus_dist: f64 = 10,
};

const Camera = struct {
    image_width: u32,
    image_height: u32,
    center: Point3,
    pixel00_loc: Point3,
    pixel_delta_u: Vec3,
    pixel_delta_v: Vec3,
    samples_per_pixel: u32,
    max_depth: u32,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,
    defocus_angle: f64,

    fn init(cfg: CameraConfig) Camera {
        const image_height_f = @max(@as(f64, @floatFromInt(cfg.image_width)) / cfg.aspect_ratio, 1);
        const image_height: u32 = @intFromFloat(image_height_f);

        const theta = cfg.vfov * std.math.pi / 180.0;
        const h = @tan(theta / 2.0);
        const viewport_height = 2.0 * h * cfg.focus_dist;
        const viewport_width = viewport_height * (@as(f64, @floatFromInt(cfg.image_width)) / @as(f64, @floatFromInt(image_height)));

        const w = cfg.lookfrom.sub(cfg.lookat).unit_vector();
        const u = Vec3.cross(cfg.vup, w).unit_vector();
        const v = Vec3.cross(w, u);

        const viewport_u = u.scale(viewport_width);
        const viewport_v = v.neg().scale(viewport_height);
        const pixel_delta_u = viewport_u.div(@floatFromInt(cfg.image_width));
        const pixel_delta_v = viewport_v.div(@floatFromInt(image_height));

        const viewport_upper_left = cfg.lookfrom
            .sub(w.scale(cfg.focus_dist))
            .sub(viewport_u.scale(0.5))
            .sub(viewport_v.scale(0.5));
        const pixel00_loc = viewport_upper_left
            .add(pixel_delta_u.add(pixel_delta_v).scale(0.5));

        const defocus_radius = cfg.focus_dist * @tan(cfg.defocus_angle / 2.0 * std.math.pi / 180.0);

        return .{
            .image_width = cfg.image_width,
            .image_height = image_height,
            .center = cfg.lookfrom,
            .pixel00_loc = pixel00_loc,
            .pixel_delta_u = pixel_delta_u,
            .pixel_delta_v = pixel_delta_v,
            .samples_per_pixel = cfg.samples_per_pixel,
            .max_depth = cfg.max_depth,
            .defocus_disk_u = u.scale(defocus_radius),
            .defocus_disk_v = v.scale(defocus_radius),
            .defocus_angle = cfg.defocus_angle,
        };
    }

    fn get_ray(self: Camera, i: usize, j: usize, rng: *std.Random.DefaultPrng) Ray {
        const offset_x = random_double(rng) - 0.5;
        const offset_y = random_double(rng) - 0.5;
        const pixel_center = self.pixel00_loc
            .add(self.pixel_delta_u.scale(@as(f64, @floatFromInt(i)) + offset_x))
            .add(self.pixel_delta_v.scale(@as(f64, @floatFromInt(j)) + offset_y));

        const origin = if (self.defocus_angle <= 0) self.center else self.defocus_disk_sample(rng);
        return .{ .origin = origin, .direction = pixel_center.sub(origin) };
    }

    fn defocus_disk_sample(self: Camera, rng: *std.Random.DefaultPrng) Point3 {
        const p = random_in_unit_disk(rng);
        return self.center
            .add(self.defocus_disk_u.scale(p.x))
            .add(self.defocus_disk_v.scale(p.y));
    }
};

// ============================================================
// Helpers
// ============================================================

fn random_double(rng: *std.Random.DefaultPrng) f64 {
    return rng.random().float(f64);
}

fn random_double_range(rng: *std.Random.DefaultPrng, min: f64, max: f64) f64 {
    return min + (max - min) * rng.random().float(f64);
}

fn random_vec3(rng: *std.Random.DefaultPrng) Vec3 {
    return .{ .x = random_double(rng), .y = random_double(rng), .z = random_double(rng) };
}

fn random_vec3_range(rng: *std.Random.DefaultPrng, min: f64, max: f64) Vec3 {
    return .{
        .x = random_double_range(rng, min, max),
        .y = random_double_range(rng, min, max),
        .z = random_double_range(rng, min, max),
    };
}

fn random_unit_vector(rng: *std.Random.DefaultPrng) Vec3 {
    while (true) {
        const p = random_vec3_range(rng, -1, 1);
        const lensq = p.length_squared();
        if (lensq > 1e-160 and lensq <= 1) return p.div(@sqrt(lensq));
    }
}

fn random_in_unit_disk(rng: *std.Random.DefaultPrng) Vec3 {
    while (true) {
        const p = Vec3{ .x = random_double_range(rng, -1, 1), .y = random_double_range(rng, -1, 1) };
        if (p.length_squared() < 1) return p;
    }
}

fn reflect(v: Vec3, n: Vec3) Vec3 {
    return v.sub(n.scale(2.0 * Vec3.dot(v, n)));
}

fn refract(uv: Vec3, n: Vec3, etai_over_etat: f64) Vec3 {
    const cos_theta = @min(Vec3.dot(uv.neg(), n), 1.0);
    const r_out_perp = uv.add(n.scale(cos_theta)).scale(etai_over_etat);
    const r_out_parallel = n.scale(-@sqrt(@abs(1.0 - r_out_perp.length_squared())));
    return r_out_perp.add(r_out_parallel);
}

fn schlick_reflectance(cosine: f64, ri: f64) f64 {
    var r0 = (1.0 - ri) / (1.0 + ri);
    r0 = r0 * r0;
    return r0 + (1.0 - r0) * std.math.pow(f64, 1.0 - cosine, 5);
}

fn linear_to_gamma(linear: f64) f64 {
    if (linear > 0) return @sqrt(linear);
    return 0;
}

fn vec_to_rl_color(color: Color) rl.Color {
    const r = linear_to_gamma(color.x);
    const g = linear_to_gamma(color.y);
    const b = linear_to_gamma(color.z);
    return .{
        .r = @intFromFloat(std.math.clamp(r, 0, 0.999) * 256),
        .g = @intFromFloat(std.math.clamp(g, 0, 0.999) * 256),
        .b = @intFromFloat(std.math.clamp(b, 0, 0.999) * 256),
        .a = 255,
    };
}

// ============================================================
// Ray tracing
// ============================================================

fn ray_color(r: Ray, world: []const Sphere, depth: u32, rng: *std.Random.DefaultPrng) Color {
    if (depth == 0) return Color{};

    if (world_hit(world, r, 0.001, std.math.inf(f64))) |rec| {
        if (rec.mat.scatter(r, rec, rng)) |result| {
            return ray_color(result.scattered, world, depth - 1, rng).mul(result.attenuation);
        }
        return Color{};
    }

    const unit_direction = r.direction.unit_vector();
    const a = 0.5 * (unit_direction.y + 1.0);
    const white = Color{ .x = 1, .y = 1, .z = 1 };
    const sky_blue = Color{ .x = 0.5, .y = 0.7, .z = 1.0 };
    return white.scale(1.0 - a).add(sky_blue.scale(a));
}

// ============================================================
// Scene
// ============================================================

fn random_scene(rng: *std.Random.DefaultPrng) World {
    var world = World{};

    // Ground
    world.add(.{
        .center = .{ .y = -1000 },
        .radius = 1000,
        .mat = .{ .lambertian = .{ .albedo = .{ .x = 0.5, .y = 0.5, .z = 0.5 } } },
    });

    // Random small spheres
    var a: i32 = -11;
    while (a < 11) : (a += 1) {
        var b: i32 = -11;
        while (b < 11) : (b += 1) {
            const choose_mat = random_double(rng);
            const center = Point3{
                .x = @as(f64, @floatFromInt(a)) + 0.9 * random_double(rng),
                .y = 0.2,
                .z = @as(f64, @floatFromInt(b)) + 0.9 * random_double(rng),
            };

            if (center.sub(Point3{ .x = 4, .y = 0.2 }).length() > 0.9) {
                if (choose_mat < 0.8) {
                    const albedo = random_vec3(rng).mul(random_vec3(rng));
                    world.add(.{
                        .center = center,
                        .radius = 0.2,
                        .mat = .{ .lambertian = .{ .albedo = albedo } },
                    });
                } else if (choose_mat < 0.95) {
                    const albedo = random_vec3_range(rng, 0.5, 1);
                    const fuzz = random_double_range(rng, 0, 0.5);
                    world.add(.{
                        .center = center,
                        .radius = 0.2,
                        .mat = .{ .metal = .{ .albedo = albedo, .fuzz = fuzz } },
                    });
                } else {
                    world.add(.{
                        .center = center,
                        .radius = 0.2,
                        .mat = .{ .dielectric = .{ .refraction_index = 1.5 } },
                    });
                }
            }
        }
    }

    // Three feature spheres
    world.add(.{
        .center = .{ .y = 1 },
        .radius = 1,
        .mat = .{ .dielectric = .{ .refraction_index = 1.5 } },
    });
    world.add(.{
        .center = .{ .x = -4, .y = 1 },
        .radius = 1,
        .mat = .{ .lambertian = .{ .albedo = .{ .x = 0.4, .y = 0.2, .z = 0.1 } } },
    });
    world.add(.{
        .center = .{ .x = 4, .y = 1 },
        .radius = 1,
        .mat = .{ .metal = .{ .albedo = .{ .x = 0.7, .y = 0.6, .z = 0.5 }, .fuzz = 0 } },
    });

    return world;
}

// ============================================================
// Main
// ============================================================

pub fn main() void {
    const cam = Camera.init(.{
        .image_width = 800,
        .samples_per_pixel = 50,
        .max_depth = 50,
        .vfov = 20,
        .lookfrom = .{ .x = 13, .y = 2, .z = 3 },
        .lookat = .{ .y = 0 },
        .vup = .{ .y = 1 },
        .defocus_angle = 0.6,
        .focus_dist = 10.0,
    });

    const window_scale = 1;
    rl.InitWindow(
        @as(c_int, @intCast(cam.image_width)) * window_scale,
        @as(c_int, @intCast(cam.image_height)) * window_scale,
        "Ray Tracing in One Weekend — Zig + Raylib",
    );
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // Build the scene
    var rng = std.Random.DefaultPrng.init(42);
    const world = random_scene(&rng);

    // Image buffer
    const image = rl.GenImageColor(@intCast(cam.image_width), @intCast(cam.image_height), rl.BLACK);
    defer rl.UnloadImage(image);
    const pixels: [*]rl.Color = @ptrCast(@alignCast(image.data.?));

    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    // Progressive rendering state
    var current_row: usize = 0;
    const rows_per_frame = 2;
    const pixel_samples_scale = 1.0 / @as(f64, @floatFromInt(cam.samples_per_pixel));

    while (!rl.WindowShouldClose()) {
        if (current_row < cam.image_height) {
            const end_row = @min(current_row + rows_per_frame, @as(usize, cam.image_height));
            var j = current_row;
            while (j < end_row) : (j += 1) {
                for (0..cam.image_width) |i| {
                    var pixel_color = Color{};
                    for (0..cam.samples_per_pixel) |_| {
                        const r = cam.get_ray(i, j, &rng);
                        pixel_color = pixel_color.add(ray_color(r, world.items(), cam.max_depth, &rng));
                    }
                    pixels[j * cam.image_width + i] = vec_to_rl_color(pixel_color.scale(pixel_samples_scale));
                }
            }
            current_row = end_row;
            rl.UpdateTexture(texture, image.data);
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.DrawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, window_scale, rl.WHITE);
        if (current_row < cam.image_height) {
            rl.DrawText(
                rl.TextFormat("Rendering: %d%%", @as(c_int, @intCast(current_row * 100 / cam.image_height))),
                10, 10, 20, rl.WHITE,
            );
        } else {
            rl.DrawText("Done! Press ESC to exit.", 10, 10, 20, rl.GREEN);
        }
        rl.EndDrawing();
    }
}
```

---

## What's Next?

Congratulations — you've built a complete ray tracer in Zig with real-time progressive display!

Some ideas for extending it:

- **Performance**: Zig's `@Vector` SIMD types for Vec3, or multi-threaded rendering with `std.Thread`
- **More shapes**: Planes, triangles, boxes (see *Ray Tracing: The Next Week*)
- **Textures**: Image-mapped textures, procedural noise
- **Interactive camera**: Use raylib input to move the camera and re-render
- **BVH acceleration**: Bounding volume hierarchies for faster scenes with many objects

See Peter Shirley's [*Ray Tracing: The Next Week*](https://raytracing.github.io/books/RayTracingTheNextWeek.html) for the natural continuation.
