const std = @import("std");
const rl = @import("rl.zig");

pub fn main() !void {
    const screen_width: c_int = 640;
    const screen_height: c_int = 576;

    rl.InitWindow(screen_width, screen_height, "zero-ed");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(60);

    var perm_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var scratch_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    _ = scratch_arena;

    const perm_ally = perm_arena.allocator();

    const font = rl.LoadFontEx("FiraCode-Regular.ttf", 30, null, 0);
    var cursor_index: u32 = 0;
    _ = cursor_index;
    var cursor_row: u32 = 0;
    _ = cursor_row;
    var buffer_points = std.ArrayList(c_int).init(perm_ally);

    while (!rl.WindowShouldClose()) {
        var char_pressed: c_int = rl.GetCharPressed();
        while (char_pressed != 0) {
            try buffer_points.append(char_pressed);
            char_pressed = rl.GetCharPressed();
        }
        var key_pressed: c_int = rl.GetKeyPressed();
        while (key_pressed != 0) {
            if (key_pressed == rl.KEY_BACKSPACE) {
                _ = buffer_points.pop();
            } else if (key_pressed == rl.KEY_ENTER) {
                try buffer_points.append(key_pressed);
            }

            key_pressed = rl.GetKeyPressed();
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);

        var x_offset: c_int = 0;
        var y_offset: c_int = 0;
        for (buffer_points.items, 0..) |point, point_index| {
            if (point == rl.KEY_ENTER) {
                y_offset += 1;
                x_offset = 0;
                continue;
            }
            if (point == rl.KEY_ENTER) {
                y_offset += 1;
                x_offset = 0;
                continue;
            }

            _ = point_index;
            const glyph_info: rl.GlyphInfo =
                rl.GetGlyphInfo(font, point);
            rl.DrawTextCodepoint(
                font,
                point,
                .{
                    .x = @floatFromInt(x_offset),
                    .y = @floatFromInt(
                        @as(c_int, @intCast(y_offset)) * font.baseSize,
                    ),
                },
                @floatFromInt(font.baseSize),
                rl.WHITE,
            );

            x_offset += glyph_info.advanceX;

            // std.debug.print("{?}\n", .{glyph_info});

            // unreachable;
        }

        rl.EndDrawing();
    }

    rl.CloseWindow();
}
