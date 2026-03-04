const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
});

pub fn main() void {
    const screen_width = 800;
    const screen_height = 600;

    rl.InitWindow(screen_width, screen_height, "raylib + ANGLE (Metal)");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    // Camera for 3D scene
    var camera = rl.Camera3D{
        .position = .{ .x = 4.0, .y = 4.0, .z = 4.0 },
        .target = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        .fovy = 45.0,
        .projection = rl.CAMERA_PERSPECTIVE,
    };

    var rotation: f32 = 0.0;
    const radius = 6.0;

    while (!rl.WindowShouldClose()) {
        // Update
        rotation += 0.5;
        const angle = rotation * std.math.pi / 180.0;
        camera.position.x = radius * @cos(angle);
        camera.position.z = radius * @sin(angle);

        // Draw
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.RAYWHITE);

        rl.BeginMode3D(camera);
        {
            // Rotating cube
            rl.DrawCubeWiresV(
                .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .{ .x = 2.0, .y = 2.0, .z = 2.0 },
                rl.DARKBLUE,
            );

            // Grid for reference
            rl.DrawGrid(10, 1.0);
        }
        rl.EndMode3D();

        // HUD
        rl.DrawText("raylib + ANGLE (Metal backend)", 10, 10, 20, rl.DARKGRAY);
        rl.DrawText(
            rl.TextFormat("Rotation: %.0f", rotation),
            10,
            40,
            20,
            rl.GRAY,
        );
        rl.DrawFPS(screen_width - 100, 10);
    }
}
