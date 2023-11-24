//!
//! main.zig
//!
//! Author: Caleb Barger
//! Date: 11/17/2023
//! Compiler: zig 0.11.0
//!

// - Nav / basic actions - in progress
//     - Scrolling
// - Command buffer
//    - Draw command buffer
//    - 'w' command
//        - Write a buffer to a file
//    - 'o' command
//        - New buffer from file
//    - Switch buffers
// - Time between key press

// TODO(caleb):
// - Move off of raylib's key input

// !!!!!!!!!!UPDATE INDICES ON ALL POINT EDITS!!!!!!!!!!

const std = @import("std");
const rl = @import("rl.zig");

const ArrayList = std.ArrayList;

const Mode = enum {
    normal,
    insert,
    command,
    select,
};

const BufferCoords = struct {
    row: usize,
    col: usize,
};

const Buffer = struct {
    selection_start: BufferCoords,
    cursor_coords: BufferCoords,
    points: ArrayList(c_int),
    line_break_indices: ArrayList(usize),
};

var screen_width: usize = 800;
var screen_height: usize = 600;

fn pointIndexFromCoords(line_break_indices: *ArrayList(usize), coords: BufferCoords) usize {
    var result = coords.col;
    if (coords.row > 0)
        result += line_break_indices.items[coords.row - 1] + 1;
    return result;
}

inline fn lineLenFromRow(
    line_break_indices: *ArrayList(usize),
    row: usize,
) usize {
    var result: usize = line_break_indices.items[row] + 1;
    if (row > 0)
        result -= line_break_indices.items[row - 1] + 1;
    return result;
}

inline fn cursorCoordsRight(
    line_break_indices: *ArrayList(usize),
    row: usize,
    col: usize,
) BufferCoords {
    var result = BufferCoords{ .row = row, .col = col };
    if (col == lineLenFromRow(line_break_indices, row) - 1) {
        if (row + 1 < line_break_indices.items.len) {
            result.col = 0;
            result.row += 1;
        }
    } else {
        result.col += 1;
    }

    return result;
}

inline fn cursorCoordsLeft(
    line_break_indices: *ArrayList(usize),
    row: usize,
    col: usize,
) BufferCoords {
    var result = BufferCoords{ .row = row, .col = col };
    if (col == 0) {
        if (row > 0) {
            result.col = lineLenFromRow(line_break_indices, row - 1) - 1;
            result.row -= 1;
        }
    } else {
        result.col -= 1;
    }

    return result;
}

inline fn cursorCoordsUp(
    line_break_indices: *ArrayList(usize),
    row: usize,
    col: usize,
) BufferCoords {
    var result = BufferCoords{ .row = row, .col = col };
    if (row > 0) {
        const line_len = lineLenFromRow(line_break_indices, row - 1);
        if (line_len - 1 < col)
            result.col = line_len - 1;
        result.row -= 1;
    }
    return result;
}

inline fn cursorCoordsDown(
    line_break_indices: *ArrayList(usize),
    row: usize,
    col: usize,
) BufferCoords {
    var result = BufferCoords{ .row = row, .col = col };
    if (row + 1 < line_break_indices.items.len) {
        const line_len = lineLenFromRow(line_break_indices, row + 1);
        if (line_len - 1 < col)
            result.col = line_len - 1;
        result.row += 1;
    }
    return result;
}

fn cellPFromCoords(
    coords: BufferCoords,
    buffer_points: *ArrayList(c_int),
    line_break_indices: *ArrayList(usize),
    sample_glyph_info: *const rl.GlyphInfo,
    font: *const rl.Font,
) rl.Vector2 {
    var cursor_p = rl.Vector2{ .x = 0.0, .y = @floatFromInt(coords.row * @as(usize, @intCast(font.baseSize))) };
    const point_end = line_break_indices.items[coords.row] + 1;
    const point_start = point_end - lineLenFromRow(line_break_indices, coords.row);
    for (buffer_points.items[point_start .. point_start + coords.col]) |point| {
        if (point == '\t') {
            cursor_p.x += @floatFromInt(sample_glyph_info.image.width * 4);
        } else {
            cursor_p.x += @floatFromInt(sample_glyph_info.image.width);
        }
    }
    return cursor_p;
}

fn DEBUGPrintLineIndices(line_break_indices: *ArrayList(usize), points: *ArrayList(c_int)) void {
    var last_nl_index: usize = 0;
    for (line_break_indices.items, 0..) |nl_index, lbi_index| {
        for (points.items[last_nl_index..nl_index]) |ch| {
            const point_u32: u32 = @intCast(ch);
            std.debug.print("{c}", .{@as(u8, @intCast(point_u32))});
        }
        std.debug.print(":{d}\n", .{nl_index});
        last_nl_index = nl_index + 1;

        if (lbi_index > 10)
            break;
    }
}

fn startPointIndexFromCameraP(
    buffer_points: *const ArrayList(c_int),
    sample_glyph_info: *const rl.GlyphInfo,
    font: *const rl.Font,
    camera_p: rl.Vector2,
) usize {
    _ = sample_glyph_info;
    var point_index: usize = 0;
    const start_row: isize = @intFromFloat(@floor(camera_p.y / @as(f32, @floatFromInt(font.baseSize))));
    var nl_count: usize = 0;
    while (nl_count < start_row - 1 and
        point_index < buffer_points.items.len) : (point_index += 1)
    {
        if (buffer_points.items[point_index] == '\n')
            nl_count += 1;
    }
    return point_index;
}

pub fn main() !void {
    rl.InitWindow(@intCast(screen_width), @intCast(screen_height), "zed");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_HIGHDPI | rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(1000);

    var buffer_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var scratch_arena =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const buffer_ally = buffer_arena.allocator();
    const scratch_ally = scratch_arena.allocator();

    const font = rl.LoadFontEx("ComicMono.ttf", 30, null, 0);
    const sample_glyph_info: rl.GlyphInfo =
        rl.GetGlyphInfo(font, ' ');

    var rows: usize = @divFloor(screen_height, @as(usize, @intCast(font.baseSize)));
    var cols: usize = @divFloor(screen_width, @as(usize, @intCast(sample_glyph_info.image.width)));

    var mode: Mode = .normal;

    var default_buffer = Buffer{
        .cursor_coords = .{
            .row = 0,
            .col = 0,
        },
        .points = ArrayList(c_int).init(buffer_ally),
        .line_break_indices = ArrayList(usize).init(buffer_ally),
        .selection_start = .{
            .row = 0,
            .col = 0,
        },
    };

    var command_points_index: usize = 0;
    var command_points = ArrayList(c_int).init(scratch_ally);

    // NOTE(caleb): DEBUG... Load *.zig into default buffer.
    var buildf = try std.fs.cwd().openFile("src/main.zig", .{});
    var build_reader = buildf.reader();
    while (build_reader.readByte() catch null) |byte| {
        const int_byte: c_int = @intCast(byte);
        try default_buffer.points.append(int_byte);
    }
    buildf.close();

    // Compute line indices
    for (default_buffer.points.items, 0..) |point, point_index|
        if (point == '\n')
            try default_buffer.line_break_indices.append(point_index);

    DEBUGPrintLineIndices(
        &default_buffer.line_break_indices,
        &default_buffer.points,
    );

    var camera = rl.Camera2D{
        .offset = .{ .x = 0.0, .y = 0.0 },
        .target = .{ .x = 0.0, .y = 0.0 },
        .rotation = 0.0,
        .zoom = 1.0,
    };
    var target_p = camera.target;
    var draw_debug_info = false;

    while (!rl.WindowShouldClose()) {
        if (rl.IsWindowResized()) {
            screen_width = @intCast(rl.GetScreenWidth());
            screen_height = @intCast(rl.GetScreenHeight());
            rows = @divFloor(screen_height, @as(usize, @intCast(font.baseSize)));
            cols = @divFloor(screen_width, @as(usize, @intCast(sample_glyph_info.image.width)));
        }

        if (rl.IsKeyPressed(rl.KEY_F1))
            draw_debug_info = !draw_debug_info;

        const ctrl_is_held = rl.IsKeyDown(rl.KEY_LEFT_CONTROL);
        var char_pressed: c_int = rl.GetCharPressed();
        var key_pressed: c_int = rl.GetKeyPressed();
        while (key_pressed != 0 or char_pressed != 0) {
            switch (mode) {
                .normal => {
                    if (key_pressed == rl.KEY_I) {
                        mode = .insert;
                    } else if (key_pressed == rl.KEY_MINUS) {
                        camera.zoom -= 0.1;
                    } else if (key_pressed == rl.KEY_EQUAL) {
                        camera.zoom += 0.1;
                    } else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                        default_buffer.cursor_coords = cursorCoordsUp(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') { // FIXME(caleb): Use math!!!
                        default_buffer.cursor_coords = cursorCoordsDown(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        default_buffer.cursor_coords = cursorCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        default_buffer.cursor_coords = cursorCoordsLeft(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_D) {
                        target_p = rl.Vector2{
                            .x = camera.target.x,
                            .y = camera.target.y + @as(f32, @floatFromInt(font.baseSize * @as(c_int, @intCast(@divFloor(rows, 2))))),
                        };
                        for (0..@divFloor(rows, 2)) |_|
                            default_buffer.cursor_coords = cursorCoordsDown(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                default_buffer.cursor_coords.col,
                            );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_U) {
                        target_p = rl.Vector2{
                            .x = camera.target.x,
                            .y = camera.target.y - @as(f32, @floatFromInt(font.baseSize * @as(c_int, @intCast(@divFloor(rows, 2))))),
                        };
                        for (0..@divFloor(rows, 2)) |_|
                            default_buffer.cursor_coords = cursorCoordsUp(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                default_buffer.cursor_coords.col,
                            );
                    }

                    if (char_pressed == 'v') {
                        default_buffer.selection_start = default_buffer.cursor_coords;
                        mode = .select;
                    } else if (char_pressed == ':') {
                        command_points_index = 0;
                        command_points.clearRetainingCapacity();
                        mode = .command;
                    } else if (char_pressed == 'd') {
                        if (default_buffer.points.items.len > 0)
                            _ = default_buffer.points.orderedRemove(pointIndexFromCoords(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords,
                            ));
                    } else if (char_pressed == 'A') {
                        default_buffer.cursor_coords.col = lineLenFromRow(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                        ) - 1;
                        mode = .insert;
                    } else if (char_pressed == 'a') {
                        // If inserting at end of buffer a second newline should be added as well!
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );

                        if (point_index == default_buffer.points.items.len) {
                            try default_buffer.points.insert(point_index, '\n');
                            for (default_buffer.line_break_indices.items[default_buffer.cursor_coords.row..]) |*lb_index| {
                                lb_index.* += 1;
                            }
                        }
                        default_buffer.cursor_coords = cursorCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                        mode = .insert;
                    } else if (char_pressed == 'x') {
                        default_buffer.selection_start.col = 0;
                        default_buffer.selection_start.row = default_buffer.cursor_coords.row;
                        default_buffer.cursor_coords.col = lineLenFromRow(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                        ) - 1;
                        mode = .select;
                    }
                },
                .insert => {
                    if (char_pressed != 0) {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        try default_buffer.points.insert(point_index, char_pressed);

                        for (default_buffer.line_break_indices.items[default_buffer.cursor_coords.row..]) |*lb_index| {
                            lb_index.* += 1;
                        }
                        default_buffer.cursor_coords = cursorCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    }

                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_BACKSPACE) {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        if (point_index != 0 and
                            default_buffer.points.items.len > point_index - 1)
                        {
                            default_buffer.cursor_coords = cursorCoordsLeft(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                default_buffer.cursor_coords.col,
                            );
                            _ = default_buffer.points.orderedRemove(point_index - 1);
                        }
                    } else if (key_pressed == rl.KEY_ENTER) {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        try default_buffer.points.insert(point_index, '\n');
                        default_buffer.cursor_coords = cursorCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                        // If inserting at end of buffer a second newline should be added as well!
                        if (point_index + 1 == default_buffer.points.items.len)
                            try default_buffer.points.insert(point_index + 1, '\n');
                    } else if (key_pressed == rl.KEY_TAB) {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        try default_buffer.points.insert(point_index, '\t');
                        default_buffer.cursor_coords = cursorCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    }
                },
                .command => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_BACKSPACE) {
                        if (command_points_index != 0 and
                            command_points.items.len > command_points_index - 1)
                        {
                            command_points_index -= 1;
                            _ = command_points.orderedRemove(command_points_index);
                        }
                    }

                    if (char_pressed != 0) {
                        try command_points.insert(command_points_index, char_pressed);
                        command_points_index += 1;
                    }
                },
                .select => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                        default_buffer.cursor_coords = cursorCoordsUp(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') { // FIXME(caleb): Use math!!!
                        default_buffer.cursor_coords = cursorCoordsDown(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        default_buffer.cursor_coords = cursorCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        default_buffer.cursor_coords = cursorCoordsLeft(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (char_pressed == 'x') {
                        default_buffer.selection_start.col = 0;
                        default_buffer.selection_start.row = default_buffer.cursor_coords.row;
                        default_buffer.cursor_coords.col = lineLenFromRow(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                        ) - 1;
                    }

                    if (char_pressed == 'd') {
                        const selection_start_point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.selection_start,
                        );
                        const cursor_coords_point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.selection_start,
                        );

                        const start = @min(selection_start_point_index, cursor_coords_point_index);
                        const end = @max(selection_start_point_index, cursor_coords_point_index) + 1;
                        for (0..end - start) |_|
                            _ = default_buffer.points.orderedRemove(start);
                        // default_buffer.cursor_index = start;
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

        rl.BeginDrawing();

        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });

        rl.BeginMode2D(camera);

        // Draw buffer
        {
            // Figures out start/end cell index to begin drawing from
            const camera_row: isize = @intFromFloat(@divExact(
                @round(camera.target.y),
                @as(f32, @floatFromInt(font.baseSize)),
            ));
            var start_point_index: usize = 0;
            if (camera_row > 0) {
                start_point_index = default_buffer.line_break_indices.items[@intCast(camera_row)] + 1;
            }
            var end_point_index: usize = default_buffer.points.items.len - 1;
            const end_camera_row = @as(usize, @intCast(camera_row)) + rows; // + @divFloor(rows, 4);
            if (end_camera_row < default_buffer.line_break_indices.items.len) {
                end_point_index = default_buffer.line_break_indices.items[end_camera_row] + 1;
            }
            var x_offset: c_int = 0;
            var y_offset: c_int = @intCast(camera_row * @as(isize, @intCast(font.baseSize)));
            for (default_buffer.points.items[start_point_index..end_point_index]) |point| {
                if (point == '\n') {
                    y_offset += font.baseSize;
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
                        .y = @floatFromInt(y_offset),
                    },
                    @floatFromInt(font.baseSize),
                    rl.WHITE,
                );
                x_offset += sample_glyph_info.image.width;
            }
        }

        const cursor_p = cellPFromCoords(
            default_buffer.cursor_coords,
            &default_buffer.points,
            &default_buffer.line_break_indices,
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
        if (mode == .normal) { // Block
            rl.DrawRectangle(
                @as(c_int, @intFromFloat(cursor_p.x)),
                @as(c_int, @intFromFloat(cursor_p.y)),
                sample_glyph_info.image.width,
                font.baseSize,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        } else if (mode == .insert) { // Line
            rl.DrawLineEx(
                cursor_p,
                rl.Vector2{
                    .x = cursor_p.x,
                    .y = cursor_p.y + @as(f32, @floatFromInt(font.baseSize)),
                },
                2.0,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        } else if (mode == .select) { // Underscore
            rl.DrawLineEx(
                rl.Vector2{
                    .x = cursor_p.x,
                    .y = cursor_p.y + @as(f32, @floatFromInt(font.baseSize)),
                },
                rl.Vector2{
                    .x = cursor_p.x + @as(f32, @floatFromInt(sample_glyph_info.image.width)),
                    .y = cursor_p.y + @as(f32, @floatFromInt(font.baseSize)),
                },
                2.0,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        }

        // Draw selection
        if (mode == .select) {
            // const start = @min(default_buffer.selection_start, default_buffer.cursor_index);
            // const end = @max(default_buffer.selection_start, default_buffer.cursor_index);
            // var selection_cell_p = cellPFromIndex(
            //     start,
            //     &default_buffer.points,
            //     &sample_glyph_info,
            //     &font,
            // );
            // var x_offset: c_int = @intFromFloat(@floor(selection_cell_p.x));
            // var y_offset: c_int = @intFromFloat(@floor(selection_cell_p.y));
            // for (default_buffer.points.items[start..(end + 1)], 0..) |point, point_index| {
            //     _ = point_index;

            //     rl.DrawRectangle(
            //         x_offset,
            //         y_offset,
            //         sample_glyph_info.image.width,
            //         font.baseSize,
            //         rl.Color{ .r = 255, .g = 0xa5, .b = 0x00, .a = 128 },
            //     );

            //     if (point == '\n') {
            //         y_offset += font.baseSize;
            //         x_offset = 0;
            //     } else if (point == '\t') {
            //         x_offset += sample_glyph_info.image.width * 4;
            //     } else {
            //         x_offset += sample_glyph_info.image.width;
            //     }
            // }
        }

        rl.EndMode2D();

        // Draw command buffer
        if (mode == .command) {
            rl.DrawRectangle(
                0,
                font.baseSize * @as(c_int, @intCast(rows - 1)),
                @as(c_int, @intCast(cols)) * sample_glyph_info.image.width,
                font.baseSize,
                rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
            );

            rl.DrawTextCodepoint(font, ':', .{
                .x = 0,
                .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(rows - 1))),
            }, @floatFromInt(font.baseSize), rl.WHITE);

            var x_offset: c_int = sample_glyph_info.image.width;
            for (command_points.items) |point| {
                rl.DrawTextCodepoint(font, point, .{
                    .x = @floatFromInt(x_offset),
                    .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(rows - 1))),
                }, @floatFromInt(font.baseSize), rl.WHITE);
                x_offset += sample_glyph_info.image.width;
            }

            rl.DrawRectangle(
                sample_glyph_info.image.width * @as(c_int, @intCast(command_points_index + 1)),
                font.baseSize * @as(c_int, @intCast(rows - 1)),
                sample_glyph_info.image.width,
                font.baseSize,
                rl.Color{
                    .r = 255,
                    .g = 255,
                    .b = 255,
                    .a = 128,
                },
            );
        }

        // Draw debug info
        if (draw_debug_info) {
            const scratch_restore = scratch_arena.state;

            const fpsz = try std.fmt.allocPrintZ(scratch_ally, "fps: {d}", .{rl.GetFPS()});
            rl.DrawTextEx(font, fpsz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 4) * 3),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            // Figures out start/end cell index to begin drawing from
            const camera_row: isize = @intFromFloat(@divExact(
                @round(camera.target.y),
                @as(f32, @floatFromInt(font.baseSize)),
            ));
            var start_point_index: usize = 0;
            if (camera_row > 0) {
                start_point_index = default_buffer.line_break_indices.items[@intCast(camera_row)] + 1;
                // start_point_index -= lineLenFromRow(&default_buffer.line_break_indices, @intCast(camera_row));
            }
            var end_point_index: usize = default_buffer.points.items.len - 1;
            const end_camera_row = @as(usize, @intCast(camera_row)) + rows; // + @divFloor(rows, 4);
            if (end_camera_row < default_buffer.line_break_indices.items.len) {
                end_point_index = default_buffer.line_break_indices.items[end_camera_row] + 1;
            }

            const glyph_draw_countz = try std.fmt.allocPrintZ(
                scratch_ally,
                "glyphs drawn: {d}",
                .{end_point_index - start_point_index},
            );
            rl.DrawTextEx(font, glyph_draw_countz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 4) * 3 + font.baseSize),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            const point_indexz = try std.fmt.allocPrintZ(
                scratch_ally,
                "point index: {d}",
                .{pointIndexFromCoords(
                    &default_buffer.line_break_indices,
                    default_buffer.cursor_coords,
                )},
            );
            rl.DrawTextEx(font, point_indexz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 4) * 3 + font.baseSize * 2),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            const cursor_coordsz = try std.fmt.allocPrintZ(
                scratch_ally,
                "cursor_p: ({d}, {d})",
                .{
                    default_buffer.cursor_coords.row,
                    default_buffer.cursor_coords.col,
                },
            );
            rl.DrawTextEx(font, cursor_coordsz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 4) * 3 + font.baseSize * 3),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            scratch_arena.state = scratch_restore;
        }

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
