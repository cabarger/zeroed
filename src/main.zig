//!
//! main.zig
//!
//! Author: Caleb Barger
//! Date: 11/17/2023
//! Compiler: zig 0.11.0
//!

// - Nav / basic actions [X]
//     - Scrolling [ ]
// - Command buffer
//    - Draw command buffer
//    - 'w' command
//        - Write a buffer to a file
//    - 'o' command
//        - New buffer from file
//    - Switch buffers
// - Time between key press
// - Smooth scrolling!!!!!!!

// TODO(caleb):
// - Move off of raylib's key input

const std = @import("std");
const rl = @import("rl.zig");

const ArrayList = std.ArrayList;

const Mode = enum {
    normal,
    insert,
    command,
    select,
};

const Buffer = struct {
    selection_start: usize,
    selection_end: usize,
    cursor_index: usize,
    points: ArrayList(c_int),
};

fn cursorColFromIndex(points: *ArrayList(c_int), current_index: usize) usize {
    var result: usize = 0;
    var points_index: usize = current_index;
    while (points_index != 0) {
        points_index -= 1;
        if (points.items[points_index] == '\n')
            break;
        result += 1;
    }
    return result;
}

fn lineLenFromIndex(points: *ArrayList(c_int), current_index: usize) usize {
    const column_points = cursorColFromIndex(points, current_index) + 1;

    // Count chars until newline
    var points_until_nl: usize = 0;
    var points_index = current_index;
    while (points_index < points.items.len and
        points.items[points_index] != '\n') : (points_index += 1)
        points_until_nl += 1;

    return column_points + points_until_nl;
}

fn cursorRowFromIndex(points: *ArrayList(c_int), current_index: usize) usize {
    var result: usize = 0;
    for (points.items[0..current_index]) |point| {
        if (point == '\n')
            result += 1;
    }
    return result;
}

fn cursorDownIndex(points: *ArrayList(c_int), cursor_index: usize) usize {
    var result = cursor_index;
    const cursor_col = cursorColFromIndex(points, cursor_index);

    // How many points until the next newline
    var points_index: usize = cursor_index;
    var cursor_advance_amount: usize = 0;
    while (points_index < points.items.len and
        points.items[points_index] != '\n') : (points_index += 1)
        cursor_advance_amount += 1;
    cursor_advance_amount += 1; // Eat '\n'
    cursor_advance_amount += cursor_col; // Advance to current col pos
    const new_cursor_index = cursor_index + cursor_advance_amount;
    if (new_cursor_index < points.items.len) { // Bounds checking
        result = new_cursor_index;
    }
    return result;
}

/// Compute new cursor index when navigating up
fn cursorUpIndex(points: *ArrayList(c_int), cursor_index: usize) usize {
    var result = cursor_index;
    var new_cursor_index: isize = @intCast(cursor_index);
    const cursor_col = cursorColFromIndex(points, @intCast(new_cursor_index));
    if (new_cursor_index - @as(isize, @intCast(cursor_col + 1)) >= 0) { // Check this isn't the first row
        const line_len = lineLenFromIndex(
            points,
            @intCast(new_cursor_index - @as(isize, @intCast(cursor_col + 1))),
        );
        if (line_len <= cursor_col) {
            result -= cursor_col + 1;
        } else {
            new_cursor_index -= @intCast(cursor_col + 1);
            new_cursor_index += @as(isize, @intCast(cursor_col + 1)) - @as(isize, @intCast(line_len));
            if (new_cursor_index >= 0)
                result = @intCast(new_cursor_index);
        }
    }
    return result;
}

fn cursorRightIndex(points: *ArrayList(c_int), cursor_index: usize) usize {
    if (cursor_index + 1 <= points.items.len)
        return cursor_index + 1;
    return cursor_index;
}

fn cursorLeftIndex(points: *ArrayList(c_int), cursor_index: usize) usize {
    _ = points;
    if (cursor_index != 0)
        return cursor_index - 1;
    return cursor_index;
}

/// Get point index which is <= 5 lines above cursor pos
fn startPointIndexFromCursor(points: *ArrayList(c_int), cursor_index: usize) usize {
    var point_index = cursor_index;
    var newline_count: usize = 0;
    while (point_index != 0) : (point_index -= 1) {
        if (points.items[point_index - 1] == '\n')
            newline_count += 1;
        if (newline_count > 5)
            break;
    }
    return point_index;
}

/// How many rows from start point index
fn rowsFromStartPoint(points: *ArrayList(c_int), start_index: usize, cursor_index: usize) usize {
    var result: usize = 0;
    for (points.items[start_index..cursor_index]) |point| {
        if (point == '\n')
            result += 1;
    }
    return result;
}

// if rows_from_start <= 5
// compute new start index

fn cursorPFromIndex(
    cursor_index: usize,
    buffer_points: *const ArrayList(c_int),
    sample_glyph_info: *const rl.GlyphInfo,
    font: *const rl.Font,
) rl.Vector2 {
    var cursor_p = rl.Vector2{ .x = 0.0, .y = 0.0 };
    for (buffer_points.items[0..cursor_index]) |point| {
        if (point == '\n') {
            cursor_p.y += @floatFromInt(font.baseSize);
            cursor_p.x = 0.0;
            continue;
        } else if (point == '\t') {
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

    rl.InitWindow(screen_width, screen_height, "zed");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_HIGHDPI);
    rl.SetTargetFPS(60);

    var buffer_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var scratch_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const buffer_ally = buffer_arena.allocator();
    const scratch_ally = scratch_arena.allocator();

    const font = rl.LoadFontEx("FiraCode-Regular.ttf", 32, null, 0);
    const sample_glyph_info: rl.GlyphInfo =
        rl.GetGlyphInfo(font, ' ');

    const rows: usize = @intCast(@divFloor(screen_height, font.baseSize));
    _ = rows;
    const cols: usize = @intCast(@divFloor(screen_width, sample_glyph_info.image.width));

    var mode: Mode = .normal;

    var default_buffer = Buffer{
        .cursor_index = 0,
        .points = ArrayList(c_int).init(buffer_ally),
        .selection_start = 0,
        .selection_end = 0,
    };
    var command_buffer = ArrayList(c_int).init(scratch_ally);

    // NOTE(caleb): Debug... Load build.zig as initial buffer.
    var buildf = try std.fs.cwd().openFile("build.zig", .{});
    var build_reader = buildf.reader();
    while (build_reader.readByte() catch null) |byte| {
        const int_byte: c_int = @intCast(byte);
        try default_buffer.points.append(int_byte);
    }
    buildf.close();

    var camera = rl.Camera2D{
        .offset = .{ .x = 0.0, .y = 0.0 },
        .target = .{ .x = 0.0, .y = 0.0 },
        .rotation = 0.0,
        .zoom = 1.0,
    };
    var target_p = camera.target;

    var start_point_index: usize = 0; //startPointIndexFromCursor(&default_buffer.points, default_buffer.cursor_index);

    while (!rl.WindowShouldClose()) {
        const ctrl_is_held = rl.IsKeyDown(rl.KEY_LEFT_CONTROL);
        var char_pressed: c_int = rl.GetCharPressed();
        var key_pressed: c_int = rl.GetKeyPressed();
        while (key_pressed != 0 or char_pressed != 0) {
            switch (mode) {
                .normal => {
                    if (key_pressed == rl.KEY_I) {
                        mode = .insert;
                    } else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                        default_buffer.cursor_index = cursorUpIndex(&default_buffer.points, default_buffer.cursor_index);
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') { // FIXME(caleb): Use math!!!
                        default_buffer.cursor_index = cursorDownIndex(&default_buffer.points, default_buffer.cursor_index);
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        default_buffer.cursor_index = cursorRightIndex(
                            &default_buffer.points,
                            default_buffer.cursor_index,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        default_buffer.cursor_index = cursorLeftIndex(
                            &default_buffer.points,
                            default_buffer.cursor_index,
                        );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_D) {
                        target_p = rl.Vector2{
                            .x = camera.target.x,
                            .y = camera.target.y + @as(f32, @floatFromInt(font.baseSize * 20)),
                        };
                        for (0..20) |_|
                            default_buffer.cursor_index = cursorDownIndex(&default_buffer.points, default_buffer.cursor_index);
                    } else if (ctrl_is_held and key_pressed == rl.KEY_U) {
                        target_p = rl.Vector2{
                            .x = camera.target.x,
                            .y = camera.target.y - @as(f32, @floatFromInt(font.baseSize * 20)),
                        };
                        for (0..20) |_|
                            default_buffer.cursor_index = cursorUpIndex(&default_buffer.points, default_buffer.cursor_index);
                    }

                    if (char_pressed == 'v') {
                        default_buffer.selection_start = default_buffer.cursor_index;
                        default_buffer.selection_end = default_buffer.cursor_index + 1;
                        mode = .select;
                    } else if (char_pressed == ':') {
                        mode = .command;
                        try command_buffer.append(':');
                    } else if (char_pressed == 'd') {
                        if (default_buffer.points.items.len > 0)
                            _ = default_buffer.points.orderedRemove(default_buffer.cursor_index);
                    } else if (char_pressed == 'A') {
                        var points_index: usize = default_buffer.cursor_index;
                        while (points_index < default_buffer.points.items.len and
                            default_buffer.points.items[points_index] != '\n')
                            points_index += 1;
                        default_buffer.cursor_index = points_index;
                        mode = .insert;
                    } else if (char_pressed == 'a') {
                        // If inserting at end of buffer a second newline should be added as well!
                        if (default_buffer.cursor_index == default_buffer.points.items.len)
                            try default_buffer.points.insert(default_buffer.cursor_index, '\n');
                        default_buffer.cursor_index += 1;
                        mode = .insert;
                    }
                },
                .insert => {
                    if (char_pressed != 0) {
                        try default_buffer.points.insert(default_buffer.cursor_index, char_pressed);
                        default_buffer.cursor_index += 1;
                    }

                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_BACKSPACE) {
                        if (default_buffer.cursor_index != 0 and
                            default_buffer.points.items.len > default_buffer.cursor_index - 1)
                        {
                            default_buffer.cursor_index -= 1;
                            _ = default_buffer.points.orderedRemove(default_buffer.cursor_index);
                        }
                    } else if (key_pressed == rl.KEY_ENTER) {
                        try default_buffer.points.insert(default_buffer.cursor_index, '\n');
                        default_buffer.cursor_index += 1;
                        // If inserting at end of buffer a second newline should be added as well!
                        if (default_buffer.cursor_index == default_buffer.points.items.len)
                            try default_buffer.points.insert(default_buffer.cursor_index, '\n');
                    } else if (key_pressed == rl.KEY_TAB) {
                        try default_buffer.points.insert(default_buffer.cursor_index, '\t');
                        default_buffer.cursor_index += 1;
                    }
                },
                .command => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    }
                },
                .select => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        default_buffer.selection_end = cursorRightIndex(&default_buffer.points, default_buffer.selection_end);
                    }

                    // FIXME(caleb): !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                    if (char_pressed == 'd') {
                        std.debug.print("{d}:{d}\n", .{ default_buffer.selection_start, default_buffer.selection_end });
                        for (default_buffer.selection_start..default_buffer.selection_end) |selection_index| {
                            std.debug.print("{d}", .{selection_index});
                            const a = default_buffer.points.orderedRemove(selection_index);
                            const point_u32: u32 = @intCast(a);
                            std.debug.print("{c}\n", .{@as(u8, @truncate(point_u32))});
                        }
                        mode = .normal;
                    }
                },
            }
            key_pressed = rl.GetKeyPressed();
            char_pressed = rl.GetCharPressed();
        }

        // Lerp camera to target pos
        if (rl.Vector2Equals(camera.target, target_p) == 0) {
            camera.target = rl.Vector2Lerp(
                camera.target,
                target_p,
                0.15,
            );
        }

        // Update start draw point
        // const rows_from_start = rowsFromStartPoint(&default_buffer.points, start_point_index, default_buffer.cursor_index);
        // std.debug.print("rfs: {d}\n", .{rows_from_start});
        // if (rows_from_start <= 5) {
        //     start_point_index = startPointIndexFromCursor(&default_buffer.points, default_buffer.cursor_index);
        // }

        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });

        rl.BeginMode2D(camera);

        // Draw buffer
        {
            var x_offset: c_int = 0;
            var y_offset: c_int = 0;
            for (default_buffer.points.items[start_point_index..]) |point| {
                if (point == '\n') {
                    y_offset += 1;
                    x_offset = 0;
                    continue;
                }
                if (point == '\t') {
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
        }

        var cursor_p = cursorPFromIndex(
            default_buffer.cursor_index,
            &default_buffer.points,
            &sample_glyph_info,
            &font,
        );

        // Draw line highlight
        rl.DrawRectangle(
            0,
            @as(c_int, @intFromFloat(cursor_p.y)),
            @as(c_int, @intCast(cols)) * sample_glyph_info.image.width,
            font.baseSize,
            rl.Color{ .r = 255, .g = 255, .b = 255, .a = 20 },
        );

        // Draw cursor
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

        // Draw selection
        if (mode == .select) {
            for (default_buffer.selection_start..default_buffer.selection_end) |selection_index| {
                var selection_cell_p = cursorPFromIndex(
                    selection_index,
                    &default_buffer.points,
                    &sample_glyph_info,
                    &font,
                );
                rl.DrawRectangle(
                    @as(c_int, @intFromFloat(selection_cell_p.x)),
                    @as(c_int, @intFromFloat(selection_cell_p.y)),
                    sample_glyph_info.image.width,
                    font.baseSize,
                    rl.Color{ .r = 255, .g = 0xa5, .b = 0x00, .a = 128 },
                );
            }
        }

        rl.EndMode2D();

        // Draw command buffer
        if (mode == .command) {}

        rl.EndDrawing();
    }

    var dumpf = try std.fs.cwd().createFile("delme.cpp", .{});
    var dump_writer = dumpf.writer();
    for (default_buffer.points.items) |point| {
        if (point == '\t') {
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
