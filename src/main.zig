//!
//! main.zig
//!
//! Author: Caleb Barger
//! Date: 11/17/2023
//! Compiler: zig 0.11.0
//!

// - Nav / basic actions - in progress
//     - '<' '>'  indent shifting
//         - move points to u8
//     - Selection highlighting
//     - Scrolling (almost done?!)
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

const heap = std.heap;
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

const shift_width = 4;

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

inline fn cellCoordsRight(
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

inline fn cellCoordsLeft(
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

inline fn cellCoordsUp(
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

inline fn cellCoordsDown(
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
    var cursor_p = rl.Vector2{
        .x = 0.0,
        .y = @floatFromInt(coords.row * @as(usize, @intCast(font.baseSize))),
    };
    var point_start: usize = 0;
    if (coords.row > 0)
        point_start = line_break_indices.items[coords.row - 1] + 1;
    for (buffer_points.items[point_start .. point_start + coords.col]) |point| {
        if (point == '\t') {
            cursor_p.x += @floatFromInt(sample_glyph_info.image.width * 4);
        } else {
            cursor_p.x += @floatFromInt(sample_glyph_info.image.width);
        }
    }
    return cursor_p;
}

inline fn shiftLineBreakIndices(
    lb_indices: *ArrayList(usize),
    start_row: usize,
    shift_amount: isize,
) void {
    for (lb_indices.items[start_row..]) |*point_index|
        point_index.* = @intCast(@as(isize, @intCast(point_index.*)) + shift_amount);
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

inline fn indentPoints(points: *ArrayList(c_int), point_index: usize) !void {
    for (0..shift_width) |shift_width_index|
        try points.insert(point_index + shift_width_index, ' ');
}

fn sanatizePoints(scratch_arena: *std.heap.ArenaAllocator, points: *ArrayList(c_int)) !void {
    var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
    defer _ = temp_arena.reset(.free_all);

    var tab_indices_list = ArrayList(usize).init(temp_arena.allocator());
    for (points.items, 0..) |point, point_index| {
        if (point == '\t')
            try tab_indices_list.append(point_index);
    }
    for (tab_indices_list.items) |tab_index| {
        _ = points.orderedRemove(tab_index);
        try indentPoints(points, tab_index);
    }
}

pub fn main() !void {
    rl.InitWindow(@intCast(screen_width), @intCast(screen_height), "zed");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_HIGHDPI | rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(1000);

    var fba_bytes = try heap.page_allocator.alloc(u8, 1024 * 1024); // 1mb
    var fba = heap.FixedBufferAllocator.init(fba_bytes);

    var buffer_arena =
        heap.ArenaAllocator.init(fba.allocator());
    var scratch_arena =
        heap.ArenaAllocator.init(fba.allocator());

    const font = rl.LoadFontEx("FiraCode-Regular.ttf", 25, null, 0);
    const sample_glyph_info: rl.GlyphInfo =
        rl.GetGlyphInfo(font, ' ');

    var rows: usize = @divTrunc(screen_height, @as(usize, @intCast(font.baseSize)));
    var cols: usize = @divTrunc(screen_width, @as(usize, @intCast(sample_glyph_info.image.width)));

    var mode: Mode = .normal;

    var default_buffer = Buffer{
        .cursor_coords = .{
            .row = 0,
            .col = 0,
        },
        .points = ArrayList(c_int).init(buffer_arena.allocator()),
        .line_break_indices = ArrayList(usize).init(buffer_arena.allocator()),
        .selection_start = .{
            .row = 0,
            .col = 0,
        },
    };

    var command_points_index: usize = 0;
    var command_points = ArrayList(u8).init(scratch_arena.allocator());

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

    try sanatizePoints(
        &scratch_arena,
        &default_buffer.points,
    );

    var camera = rl.Camera2D{
        .offset = .{ .x = 0.0, .y = 0.0 },
        .target = .{ .x = 0.0, .y = 0.0 },
        .rotation = 0,
        .zoom = 1.0,
    };
    var target_rot: f32 = 0.0;
    var target_p = camera.target;
    var draw_debug_info = false;
    var DEBUG_glyphs_drawn_this_frame: usize = 0;

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
                        default_buffer.cursor_coords = cellCoordsUp(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                default_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y < camera.target.y) {
                            target_p = rl.Vector2Subtract(target_p, .{ .x = 0, .y = @floatFromInt(font.baseSize) });
                        }
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                        default_buffer.cursor_coords = cellCoordsDown(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                default_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y > (camera.target.y + @as(f32, @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize)))))) {
                            target_p = rl.Vector2Subtract(cursor_p, .{ .x = 0, .y = @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize))) });
                        }
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        default_buffer.cursor_coords = cellCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        default_buffer.cursor_coords = cellCoordsLeft(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_D) {
                        target_p = rl.Vector2Add(target_p, .{
                            .x = 0,
                            .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(@divFloor(rows, 2)))),
                        });
                        for (0..@divFloor(rows, 2)) |_|
                            default_buffer.cursor_coords = cellCoordsDown(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                default_buffer.cursor_coords.col,
                            );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_U) {
                        target_p = rl.Vector2Subtract(target_p, .{
                            .x = 0,
                            .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(@divFloor(rows, 2)))),
                        });
                        for (0..@divFloor(rows, 2)) |_|
                            default_buffer.cursor_coords = cellCoordsUp(
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
                    } else if (char_pressed == '>') {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        const line_start = point_index - default_buffer.cursor_coords.col;
                        try indentPoints(&default_buffer.points, line_start);
                        shiftLineBreakIndices(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            shift_width,
                        );
                    } else if (char_pressed == '<') {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        const line_start = point_index - default_buffer.cursor_coords.col;
                        var white_space_count: usize = 0;
                        for (default_buffer.points.items[line_start..]) |point| {
                            if (point == ' ')
                                white_space_count += 1;
                            if (white_space_count == shift_width or point != ' ')
                                break;
                        }
                        if (white_space_count > 0) {
                            for (0..white_space_count) |_|
                                _ = default_buffer.points.orderedRemove(line_start);
                            shiftLineBreakIndices(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                -@as(isize, @intCast(white_space_count)),
                            );
                        }
                    } else if (char_pressed == 'd') {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        if (point_index != 0) {
                            shiftLineBreakIndices(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                -1,
                            );
                            if (default_buffer.line_break_indices.items[default_buffer.cursor_coords.row - 1] ==
                                default_buffer.line_break_indices.items[default_buffer.cursor_coords.row])
                                _ = default_buffer.line_break_indices.orderedRemove(default_buffer.cursor_coords.row);
                            _ = default_buffer.points.orderedRemove(point_index);
                        }
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
                            shiftLineBreakIndices(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                1,
                            );
                        }
                        default_buffer.cursor_coords = cellCoordsRight(
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
                        shiftLineBreakIndices(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            1,
                        );

                        default_buffer.cursor_coords = cellCoordsRight(
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
                        if (point_index != 0) {
                            shiftLineBreakIndices(
                                &default_buffer.line_break_indices,
                                default_buffer.cursor_coords.row,
                                -1,
                            );
                            if (default_buffer.line_break_indices.items[default_buffer.cursor_coords.row - 1] ==
                                default_buffer.line_break_indices.items[default_buffer.cursor_coords.row])
                                _ = default_buffer.line_break_indices.orderedRemove(default_buffer.cursor_coords.row);

                            default_buffer.cursor_coords = cellCoordsLeft(
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

                        const old_line_len =
                            lineLenFromRow(&default_buffer.line_break_indices, default_buffer.cursor_coords.row);
                        const increment_len = old_line_len - default_buffer.cursor_coords.col;

                        default_buffer.line_break_indices.items[default_buffer.cursor_coords.row] = point_index;

                        default_buffer.cursor_coords.row += 1;
                        default_buffer.cursor_coords.col = 0;

                        try default_buffer.line_break_indices.insert(default_buffer.cursor_coords.row, point_index + increment_len);
                        shiftLineBreakIndices(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            1,
                        );

                        // FIXME(caleb): If inserting at end of buffer a second newline should be added as well!
                    } else if (key_pressed == rl.KEY_TAB) {
                        const point_index = pointIndexFromCoords(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords,
                        );
                        try indentPoints(&default_buffer.points, point_index);
                        shiftLineBreakIndices(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            shift_width,
                        );
                        default_buffer.cursor_coords.col += shift_width;
                    }
                },
                .command => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_ENTER) { // Evaluate command buffer
                        if (std.mem.eql(u8, command_points.items, "barrel-roll")) {
                            target_rot = 360;
                        }
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
                        try command_points.insert(command_points_index, @intCast(char_pressed));
                        command_points_index += 1;
                    }
                },
                .select => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                        default_buffer.cursor_coords = cellCoordsUp(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                default_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y < camera.target.y) {
                            target_p = rl.Vector2Subtract(target_p, .{ .x = 0, .y = @floatFromInt(font.baseSize) });
                        }
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                        default_buffer.cursor_coords = cellCoordsDown(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                default_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y > (camera.target.y + @as(f32, @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize)))))) {
                            target_p = rl.Vector2Subtract(cursor_p, .{ .x = 0, .y = @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize))) });
                        }
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        default_buffer.cursor_coords = cellCoordsRight(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        default_buffer.cursor_coords = cellCoordsLeft(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                            default_buffer.cursor_coords.col,
                        );
                    }

                    if (char_pressed == 'x') {
                        default_buffer.selection_start.col = 0;
                        default_buffer.selection_start.row = default_buffer.cursor_coords.row;
                        default_buffer.cursor_coords.col = lineLenFromRow(
                            &default_buffer.line_break_indices,
                            default_buffer.cursor_coords.row,
                        ) - 1;
                    } else if (char_pressed == 'd') {
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
                0.05,
            );
        }

        // Barrel roll
        if (@round(camera.rotation) != target_rot) {
            camera.rotation = rl.Lerp(camera.rotation, target_rot, 0.05);
        } else { // Done rolling
            target_rot = 0.0;
            camera.rotation = 0.0;
        }

        DEBUG_glyphs_drawn_this_frame = 0;

        rl.BeginDrawing();

        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });

        rl.BeginMode2D(camera);

        // Draw buffer
        {
            const start_camera_row: usize = @min(
                default_buffer.line_break_indices.items.len - 1,
                @as(usize, @intFromFloat(@divExact(
                    @max(0.0, @round(camera.target.y)),
                    @as(f32, @floatFromInt(font.baseSize)),
                ))),
            );
            const end_camera_row = @min(default_buffer.line_break_indices.items.len, start_camera_row + rows + 2);
            for (start_camera_row..end_camera_row) |row_index| {
                var x_offset: c_int = 0;
                var y_offset: c_int = @intCast(row_index * @as(usize, @intCast(font.baseSize)));

                // Line numbers
                var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
                defer _ = temp_arena.reset(.free_all);

                const line_number_str = try std.fmt.allocPrint(
                    temp_arena.allocator(),
                    "{d: >4}",
                    .{row_index + 1},
                );

                for (line_number_str) |digit_char| {
                    rl.DrawTextCodepoint(
                        font,
                        digit_char,
                        .{
                            .x = @floatFromInt(x_offset),
                            .y = @floatFromInt(y_offset),
                        },
                        @floatFromInt(font.baseSize),
                        rl.WHITE,
                    );
                    DEBUG_glyphs_drawn_this_frame += 1;
                    x_offset += sample_glyph_info.image.width;
                }
                x_offset += sample_glyph_info.image.width;

                var start_point_index: usize = 0;
                if (row_index > 0)
                    start_point_index = default_buffer.line_break_indices.items[row_index - 1] + 1;
                const end_point_index = start_point_index + lineLenFromRow(&default_buffer.line_break_indices, row_index);
                for (default_buffer.points.items[start_point_index..end_point_index]) |point| {
                    if (point == '\n') {
                        y_offset += font.baseSize;
                        x_offset = sample_glyph_info.image.width * 5;
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
                    DEBUG_glyphs_drawn_this_frame += 1;
                    x_offset += sample_glyph_info.image.width;
                }
            }
        }

        var cursor_p = cellPFromCoords(
            default_buffer.cursor_coords,
            &default_buffer.points,
            &default_buffer.line_break_indices,
            &sample_glyph_info,
            &font,
        );
        cursor_p.x += @floatFromInt(sample_glyph_info.image.width * 5);

        // Draw line highlight
        rl.DrawRectangle(
            @as(c_int, @intFromFloat(cursor_p.x)),
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
        if (mode == .select) { // FIXME(caleb): Only draw selections that can be seen
            const cursor_point = pointIndexFromCoords(&default_buffer.line_break_indices, default_buffer.cursor_coords);
            const selection_point = pointIndexFromCoords(&default_buffer.line_break_indices, default_buffer.selection_start);
            const start_point_index = @min(cursor_point, selection_point);
            const end_point_index = @max(cursor_point, selection_point);

            var x_offset: c_int = 0;
            var y_offset: c_int = 0;
            if (start_point_index == cursor_point) {
                x_offset = @as(c_int, @intCast(default_buffer.cursor_coords.col)) * sample_glyph_info.image.width + sample_glyph_info.image.width * 5;
                y_offset = @as(c_int, @intCast(default_buffer.cursor_coords.row)) * font.baseSize;
            } else {
                x_offset = @as(c_int, @intCast(default_buffer.selection_start.col)) * sample_glyph_info.image.width + sample_glyph_info.image.width * 5;
                y_offset = @as(c_int, @intCast(default_buffer.selection_start.row)) * font.baseSize;
            }

            for (default_buffer.points.items[start_point_index .. end_point_index + 1]) |point| {
                rl.DrawRectangle(
                    x_offset,
                    y_offset,
                    sample_glyph_info.image.width,
                    font.baseSize,
                    rl.Color{ .r = 255, .g = 0xa5, .b = 0x00, .a = 128 },
                );

                if (point == '\n') {
                    y_offset += font.baseSize;
                    x_offset = sample_glyph_info.image.width * 4;
                }
                if (point == '\t') {
                    x_offset += sample_glyph_info.image.width * 4;
                } else {
                    x_offset += sample_glyph_info.image.width;
                }
            }
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
            DEBUG_glyphs_drawn_this_frame += 1;

            var x_offset: c_int = sample_glyph_info.image.width;
            for (command_points.items) |point| {
                rl.DrawTextCodepoint(font, point, .{
                    .x = @floatFromInt(x_offset),
                    .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(rows - 1))),
                }, @floatFromInt(font.baseSize), rl.WHITE);
                DEBUG_glyphs_drawn_this_frame += 1;
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
            var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
            defer _ = temp_arena.reset(.free_all);

            const fpsz = try std.fmt.allocPrintZ(temp_arena.allocator(), "fps: {d}", .{rl.GetFPS()});
            rl.DrawTextEx(font, fpsz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 10) * 8),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            const glyph_draw_countz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "glyphs drawn: {d}",
                .{DEBUG_glyphs_drawn_this_frame},
            );
            rl.DrawTextEx(font, glyph_draw_countz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 10) * 8 + font.baseSize),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            const point_indexz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "point index: {d}",
                .{pointIndexFromCoords(
                    &default_buffer.line_break_indices,
                    default_buffer.cursor_coords,
                )},
            );
            rl.DrawTextEx(font, point_indexz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 10) * 8 + font.baseSize * 2),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            const cursor_coordsz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "cursor_p: ({d}, {d})",
                .{
                    default_buffer.cursor_coords.row,
                    default_buffer.cursor_coords.col,
                },
            );
            rl.DrawTextEx(font, cursor_coordsz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 10) * 8 + font.baseSize * 3),
            }, @floatFromInt(font.baseSize), 0, rl.RED);

            const mem_usedz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "mem: {d}/{d}KB",
                .{
                    @divTrunc(fba.end_index, 1024),
                    @divExact(fba.buffer.len, 1024),
                },
            );
            rl.DrawTextEx(font, mem_usedz, .{
                .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * sample_glyph_info.image.width, 4) * 3),
                .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 10) * 8 + font.baseSize * 4),
            }, @floatFromInt(font.baseSize), 0, rl.RED);
        }
        rl.EndDrawing();
    }

    var dumpf = try std.fs.cwd().createFile("delme.cpp", .{});
    var dump_writer = dumpf.writer();
    for (default_buffer.points.items) |point| {
        const point_u32: u32 = @intCast(point);
        try dump_writer.writeByte(@truncate(point_u32));
    }
    dumpf.close();

    rl.CloseWindow();
}
