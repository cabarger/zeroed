//!
//! main.zig
//!
//! Author: Caleb Barger
//! Date: 11/17/2023
//! Compiler: zig 0.11.0
//!

const std = @import("std");
const rl = @import("rl.zig");

const ArrayList = std.ArrayList;

const Mode = enum {
    normal,
    insert,
    command,
};

fn cursorPFromIndex(
    cursor_index: usize,
    buffer_points: *const ArrayList(c_int),
    sample_glyph_info: *const rl.GlyphInfo,
    font: *const rl.Font,
) rl.Vector2 {
    var cursor_p = rl.Vector2{ .x = 0.0, .y = 0.0 };
    for (buffer_points.items[0..cursor_index]) |point| {
        if (point == rl.KEY_ENTER) {
            cursor_p.y += @floatFromInt(font.baseSize);
            cursor_p.x = 0.0;
            continue;
        } else if (point == rl.KEY_TAB) {
            cursor_p.x += @floatFromInt(sample_glyph_info.image.width * 4);
            continue;
        } else {
            cursor_p.x += @floatFromInt(sample_glyph_info.image.width);
        }
    }
    return cursor_p;
}

pub fn main() !void {
    const screen_width: c_int = 1680;
    const screen_height: c_int = 1050;

    rl.InitWindow(screen_width, screen_height, "zero-ed");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_HIGHDPI);
    rl.SetTargetFPS(60);

    var buffer_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var scratch_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    _ = scratch_arena;

    const buffer_ally = buffer_arena.allocator();

    const font = rl.LoadFontEx("FiraCode-Regular.ttf", 30, null, 0);
    const sample_glyph_info: rl.GlyphInfo =
        rl.GetGlyphInfo(font, ' ');

    const rows = @divFloor(screen_height, font.baseSize);
    _ = rows;
    const cols = @divFloor(screen_width, sample_glyph_info.image.width);
    _ = cols;

    var mode: Mode = .insert;
    var cursor_index: usize = 0;

    var buffer_points = std.ArrayList(c_int).init(buffer_ally);

    while (!rl.WindowShouldClose()) {
        var char_pressed: c_int = rl.GetCharPressed();
        while (char_pressed != 0) {
            if (mode == .insert) {
                try buffer_points.append(char_pressed);
                cursor_index += 1;
            } else if (char_pressed == ':') {
                mode = .command;
            } else if (char_pressed == ':') {
                mode = .command;
            }
            char_pressed = rl.GetCharPressed();
        }
        var key_pressed: c_int = rl.GetKeyPressed();
        while (key_pressed != 0) {
            if (key_pressed == rl.KEY_CAPS_LOCK) {
                mode = .normal;
            } else if (key_pressed == rl.KEY_I and mode == .normal) {
                mode = .insert;
            } else if (key_pressed == rl.KEY_BACKSPACE) {
                _ = buffer_points.pop();
                cursor_index -= 1;
            } else if (key_pressed == rl.KEY_ENTER) {
                cursor_index += 1;
                try buffer_points.append(key_pressed);
            } else if (key_pressed == rl.KEY_TAB) {
                try buffer_points.append(key_pressed);
                cursor_index += 1;
            } else if (key_pressed == rl.KEY_UP) {
                cursor_index -= 1;
            } else if (key_pressed == rl.KEY_DOWN) {
                // cursor_p.y += 1.0;
            } else if (key_pressed == rl.KEY_RIGHT) {
                // cursor_p.x += 1.0;
            } else if (key_pressed == rl.KEY_LEFT) { // cursor_p.x -= 1.0;
            }

            key_pressed = rl.GetKeyPressed();
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);

        // Draw buffer
        var x_offset: c_int = 0;
        var y_offset: c_int = 0;
        for (buffer_points.items, 0..) |point, point_index| {
            _ = point_index;
            if (point == rl.KEY_ENTER) {
                y_offset += 1;
                x_offset = 0;
                continue;
            }
            if (point == rl.KEY_TAB) {
                x_offset += sample_glyph_info.image.width * 4;
                continue;
            }

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
            x_offset += sample_glyph_info.image.width;
        }

        // Draw cursor
        var cursor_p = cursorPFromIndex(
            cursor_index,
            &buffer_points,
            &sample_glyph_info,
            &font,
        );
        if (mode == .normal) {
            rl.DrawRectangle(
                @as(c_int, @intFromFloat(cursor_p.x)),
                @as(c_int, @intFromFloat(cursor_p.y)),
                sample_glyph_info.image.width,
                font.baseSize,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        } else if (mode == .insert) {
            rl.DrawLineEx(
                cursor_p,
                rl.Vector2{
                    .x = cursor_p.x,
                    .y = cursor_p.y + @as(f32, @floatFromInt(font.baseSize)),
                },
                2.0,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        }

        // TODO(caleb): Draw command buffer

        rl.EndDrawing();
    }

    var dumpf = try std.fs.cwd().createFile("delme.cpp", .{});
    var dump_writer = dumpf.writer();
    for (buffer_points.items) |point| {
        if (point == rl.KEY_ENTER) {
            try dump_writer.writeByte('\n');
        } else if (point == rl.KEY_TAB) {
            try dump_writer.writeByte(' ');
            try dump_writer.writeByte(' ');
            try dump_writer.writeByte(' ');
            try dump_writer.writeByte(' ');
        } else {
            const point_u32: u32 = @intCast(point);
            try dump_writer.writeByte(@truncate(point_u32));
        }
    }
    dumpf.close();

    rl.CloseWindow();
}
