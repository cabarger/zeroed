//!
//! main.zig
//!
//! Caleb Barger
//! 11/17/2023
//! zig 0.11.0
//!

//- cabarger: Use this thing to build itself:
// - "Data loss very bad" now you say "data loss very bad." [ ]
// - Scrolling (almost done?!) [ ]
//    - Give scrolling to line number second pass [ ]
// - Command buffer
//    - Draw command buffer
//    - 'w' command
//        - Write a buffer to a file
//    - 'o' command
//        - New buffer from file
//    - Switch buffers
// - Windows support
//    - handle '\r'

//- cabarger: Approaching usable editor:
// - Nav / basic actions [ ]
//     - Smart indents on line break [ ]
// - Basic history [ ]
//    - Registers??

//- cabarger: Eventually..
// - Move off of raylib's key input

const std = @import("std");
const rl = @import("rl.zig");

const mem = std.mem;
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
    arena: heap.ArenaAllocator,
    selection_coords: BufferCoords,
    cursor_coords: BufferCoords,
    points: ArrayList(u8),
    line_break_indices: ArrayList(usize),
    backed_by_file: bool,
    file_path_buf: [256]u8,
    file_path: []const u8,
    modified: bool,
    modified_time: usize,
    available: bool, //- cabarger: Probably can infer this?
};

fn bufferInit(buffer: *Buffer) void {
    buffer.arena = heap.ArenaAllocator.init(heap.page_allocator);
    buffer.cursor_coords = .{
        .row = 0,
        .col = 0,
    };
    buffer.points = ArrayList(u8).init(buffer.arena.allocator());
    buffer.line_break_indices = ArrayList(usize).init(buffer.arena.allocator());
    buffer.selection_coords = .{
        .row = 0,
        .col = 0,
    };
    buffer.backed_by_file = false;
    buffer.file_path_buf = undefined;
    buffer.file_path = undefined;
    buffer.modified = false;
    buffer.modified_time = 0;
    buffer.available = true;
}

fn bufferReset(buffer: *Buffer) void {
    buffer.backed_by_file = false;
    buffer.file_path = undefined;
    buffer.modified = false;
    buffer.modified_time = 0;
    buffer.cursor_coords = .{ .row = 0, .col = 0 };
    buffer.selection_coords = .{ .row = 0, .col = 0 };
    buffer.line_break_indices.clearRetainingCapacity();
    buffer.points.clearRetainingCapacity();
    buffer.available = true;
}

/// Assumes buffer is has been RESET
fn bufferLoadFile(buffer: *Buffer, scratch_arena: *heap.ArenaAllocator, path: []const u8) !void {
    if (!buffer.available)
        unreachable;
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var reader = f.reader();
    while (reader.readByte() catch null) |byte|
        try buffer.points.append(byte);

    replaceTabsWithSpaces(
        scratch_arena,
        &buffer.points,
    );

    // Compute line indices
    for (buffer.points.items, 0..) |point, point_index|
        if (point == '\n')
            buffer.line_break_indices.append(point_index) catch unreachable;

    for (path, 0..) |path_byte, path_byte_index|
        buffer.file_path_buf[path_byte_index] = path_byte;
    buffer.file_path = buffer.file_path_buf[0..path.len];
    buffer.backed_by_file = true;
    buffer.available = false;
}

fn buffersGetAvail(buffers: []Buffer) ?*Buffer {
    for (buffers) |*buffer| {
        if (buffer.available) {
            return buffer;
        }
    }
    return null;
}

fn buffersReleaseColdest(buffers: []Buffer) !*Buffer {
    var coldest_buffer: *Buffer = undefined;
    {
        var coldest_buffer_index: usize = 0;
        for (buffers, 0..) |*buffer, buffer_index| {
            if (buffer.modified_time < buffers[coldest_buffer_index].modified_time) {
                coldest_buffer_index = buffer_index;
            }
        }
        coldest_buffer = &buffers[coldest_buffer_index];
    }
    if (coldest_buffer.backed_by_file) {
        var f = try std.fs.cwd().createFile(coldest_buffer.file_path, .{});
        defer f.close();
        var writer = f.writer();
        for (coldest_buffer.points.items) |point| {
            const point_u32: u32 = @intCast(point);
            try writer.writeByte(@truncate(point_u32));
        }
    }
    bufferReset(coldest_buffer);
    return coldest_buffer;
}

const shift_width = 4;
const default_font_size = 25;

/// From line break indices get a point index from these cell coords.
fn pointIndexFromCoords(
    line_break_indices: *ArrayList(usize),
    coords: BufferCoords,
) usize {
    var result = coords.col;
    if (coords.row > 0)
        result += line_break_indices.items[coords.row - 1] + 1;
    return result;
}

fn lineLenFromRow(
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
    buffer_points: *ArrayList(u8),
    line_break_indices: *ArrayList(usize),
    refrence_glyph_info: *const rl.GlyphInfo,
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
            cursor_p.x += @floatFromInt(refrence_glyph_info.image.width * 4);
        } else {
            cursor_p.x += @floatFromInt(refrence_glyph_info.image.width);
        }
    }
    return cursor_p;
}

fn shiftLBIndices(
    scratch_arena: *heap.ArenaAllocator,
    lb_indices: *ArrayList(usize),
    start_row: usize,
    shift_amount: isize,
) !void {
    _ = scratch_arena;

    for (lb_indices.items[start_row..]) |*lb_index| {
        const shifted_lb_index: isize =
            @as(isize, @intCast(lb_index.*)) + shift_amount;
        if (shifted_lb_index < 0)
            unreachable;
        lb_index.* = @intCast(shifted_lb_index);
    }
}

fn DEBUGPrintLineIndices(line_break_indices: *ArrayList(usize), points: *ArrayList(u8)) void {
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
    buffer_points: *const ArrayList(u8),
    refrence_glyph_info: *const rl.GlyphInfo,
    font: *const rl.Font,
    camera_p: rl.Vector2,
) usize {
    _ = refrence_glyph_info;
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

inline fn indentPoints(points: *ArrayList(u8), point_index: usize) void {
    for (0..shift_width) |shift_width_index|
        points.insert(point_index + shift_width_index, ' ') catch unreachable;
}

fn replaceTabsWithSpaces(scratch_arena: *std.heap.ArenaAllocator, points: *ArrayList(u8)) void {
    var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
    defer _ = temp_arena.reset(.free_all);

    var tab_indices_list = ArrayList(usize).init(temp_arena.allocator());
    for (points.items, 0..) |point, point_index| {
        if (point == '\t')
            tab_indices_list.append(point_index) catch unreachable;
    }
    for (tab_indices_list.items) |tab_index| {
        _ = points.orderedRemove(tab_index);
        indentPoints(points, tab_index);
    }
}

const base_thread_context = @import("base_thread_context.zig");
const TCTX = base_thread_context.TCTX;

pub fn main() !void {
    var screen_width: usize = 800;
    var screen_height: usize = 600;

    var tctx: TCTX = undefined;
    base_thread_context.tctxInitAndEquip(&tctx);
    var scratch_arena = base_thread_context.tctxGetScratch(null, 0) orelse unreachable;

    rl.InitWindow(@intCast(screen_width), @intCast(screen_height), "Zeroed");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_HIGHDPI | rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(120);
    rl.SetExitKey(0);

    var font_size: c_int = default_font_size;
    var font: rl.Font = rl.LoadFontEx("ComicMono.ttf", font_size, null, 0);
    var refrence_glyph_info: rl.GlyphInfo = rl.GetGlyphInfo(font, ' ');

    var rows: usize = @divTrunc(screen_height, @as(usize, @intCast(font.baseSize)));
    var cols: usize = @divTrunc(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));

    var mode: Mode = .normal;

    var buffers: [2]Buffer = undefined;
    for (&buffers) |*buffer|
        bufferInit(buffer);
    var active_buffer = buffersGetAvail(&buffers) orelse unreachable;

    var command_points_index: usize = 0;
    var command_points = ArrayList(u8).init(scratch_arena.allocator());

    //- cabarger: DEBUG... Load *.zig into default buffer.
    try bufferLoadFile(active_buffer, scratch_arena, "src/test_buffer.zig");

    var last_char_pressed: u8 = 0;

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

    main_loop: while (true) { //- cabarger: main loop
        if (rl.WindowShouldClose())
            break;
        if (rl.IsWindowResized()) {
            screen_width = @intCast(rl.GetScreenWidth());
            screen_height = @intCast(rl.GetScreenHeight());
            rows = @divFloor(screen_height, @as(usize, @intCast(font.baseSize)));
            cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
        }

        if (rl.IsKeyPressed(rl.KEY_F1))
            draw_debug_info = !draw_debug_info;

        const ctrl_is_held = rl.IsKeyDown(rl.KEY_LEFT_CONTROL);
        var char_pressed: u8 = @intCast(rl.GetCharPressed());
        var key_pressed: c_int = rl.GetKeyPressed();
        while (key_pressed != 0 or char_pressed != 0) {
            if (char_pressed > 127)
                unreachable; // FIXME(caleb): utf-8 support
            switch (mode) {
                .normal => {
                    if (key_pressed == rl.KEY_I) {
                        mode = .insert;
                    } else if (key_pressed == rl.KEY_MINUS) {
                        rl.UnloadFont(font);
                        font_size -= 1;
                        font = rl.LoadFontEx("ComicMono.ttf", font_size, null, 0);
                        refrence_glyph_info = rl.GetGlyphInfo(font, ' ');
                        rows = @divFloor(screen_height, @as(usize, @intCast(font.baseSize)));
                        cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
                    } else if (key_pressed == rl.KEY_EQUAL) {
                        rl.UnloadFont(font);
                        font_size += 1;
                        font = rl.LoadFontEx("ComicMono.ttf", font_size, null, 0);
                        refrence_glyph_info = rl.GetGlyphInfo(font, ' ');
                        rows = @divFloor(screen_height, @as(usize, @intCast(font.baseSize)));
                        cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
                    } else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                        active_buffer.cursor_coords = cellCoordsUp(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                active_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y < camera.target.y) {
                            target_p = rl.Vector2Subtract(target_p, .{ .x = 0, .y = @floatFromInt(font.baseSize) });
                        }
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                        active_buffer.cursor_coords = cellCoordsDown(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                active_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y > (camera.target.y + @as(f32, @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize)))))) {
                            target_p = rl.Vector2Subtract(cursor_p, .{ .x = 0, .y = @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize))) });
                        }
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        active_buffer.cursor_coords = cellCoordsRight(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        active_buffer.cursor_coords = cellCoordsLeft(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_D) {
                        target_p = rl.Vector2Add(target_p, .{
                            .x = 0,
                            .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(@divFloor(rows, 2)))),
                        });
                        for (0..@divFloor(rows, 2)) |_|
                            active_buffer.cursor_coords = cellCoordsDown(
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                active_buffer.cursor_coords.col,
                            );
                    } else if (ctrl_is_held and key_pressed == rl.KEY_U) {
                        target_p = rl.Vector2Subtract(target_p, .{
                            .x = 0,
                            .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(@divFloor(rows, 2)))),
                        });
                        for (0..@divFloor(rows, 2)) |_|
                            active_buffer.cursor_coords = cellCoordsUp(
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                active_buffer.cursor_coords.col,
                            );
                    }

                    if (char_pressed == 'v') {
                        active_buffer.selection_coords = active_buffer.cursor_coords;
                        mode = .select;
                    } else if (char_pressed == ':') {
                        command_points_index = 0;
                        command_points.clearRetainingCapacity();
                        mode = .command;
                    } else if (char_pressed == '>') {
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );
                        const line_start = point_index - active_buffer.cursor_coords.col;
                        indentPoints(&active_buffer.points, line_start);
                        try shiftLBIndices(
                            scratch_arena,
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            shift_width,
                        );
                    } else if (char_pressed == '<') {
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );
                        const line_start = point_index - active_buffer.cursor_coords.col;
                        var white_space_count: usize = 0;
                        for (active_buffer.points.items[line_start..]) |point| {
                            if (point == ' ')
                                white_space_count += 1;
                            if (white_space_count == shift_width or point != ' ')
                                break;
                        }
                        if (white_space_count > 0) {
                            for (0..white_space_count) |_|
                                _ = active_buffer.points.orderedRemove(line_start);
                            try shiftLBIndices(
                                scratch_arena,
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                -@as(isize, @intCast(white_space_count)),
                            );
                        }
                    } else if (char_pressed == 'd') {
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );
                        if (active_buffer.points.items.len > 0) {
                            const removed_point = active_buffer.points.orderedRemove(point_index);
                            if (removed_point == '\n') {
                                active_buffer.line_break_indices.items[active_buffer.cursor_coords.row] +=
                                    lineLenFromRow(&active_buffer.line_break_indices, active_buffer.cursor_coords.row + 1);
                                _ = active_buffer.line_break_indices.orderedRemove(active_buffer.cursor_coords.row + 1);
                            }
                            try shiftLBIndices(
                                scratch_arena,
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                -1,
                            );
                        }
                    } else if (char_pressed == 'A') {
                        active_buffer.cursor_coords.col = lineLenFromRow(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                        ) - 1;
                        mode = .insert;
                    } else if (char_pressed == 'a') {
                        // If inserting at end of buffer a second newline should be added as well!
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );

                        if (point_index == active_buffer.points.items.len) {
                            try active_buffer.points.insert(point_index, '\n');
                            try shiftLBIndices(
                                scratch_arena,
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                1,
                            );
                        }
                        active_buffer.cursor_coords = cellCoordsRight(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                        mode = .insert;
                    } else if (char_pressed == 'x') {
                        active_buffer.selection_coords.col = 0;
                        active_buffer.selection_coords.row = active_buffer.cursor_coords.row;
                        active_buffer.cursor_coords.col = lineLenFromRow(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                        ) - 1;
                        mode = .select;
                    }
                },
                .insert => {
                    if (char_pressed != 0) {
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );
                        try active_buffer.points.insert(point_index, char_pressed);
                        try shiftLBIndices(
                            scratch_arena,
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            1,
                        );

                        active_buffer.cursor_coords = cellCoordsRight(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                    }

                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_BACKSPACE) {
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );
                        if (point_index != 0) {
                            //- cabarger: Can I/Should I couple point removals/insertions and line
                            // break index updates???
                            const removed_point =
                                active_buffer.points.orderedRemove(point_index - 1);
                            try shiftLBIndices(
                                scratch_arena,
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                -1,
                            );
                            if (removed_point == '\n') { // When hitting a newline
                                const nuked_line_len = lineLenFromRow( // Get remaining line len
                                    &active_buffer.line_break_indices,
                                    active_buffer.cursor_coords.row,
                                );
                                _ = active_buffer.line_break_indices.orderedRemove(
                                    active_buffer.cursor_coords.row,
                                );
                                active_buffer.line_break_indices.items[active_buffer.cursor_coords.row - 1] += nuked_line_len;
                            }
                            active_buffer.cursor_coords = cellCoordsLeft(
                                &active_buffer.line_break_indices,
                                active_buffer.cursor_coords.row,
                                active_buffer.cursor_coords.col,
                            );
                        }
                    } else if (key_pressed == rl.KEY_ENTER) {
                        // Where is this in the points buffer
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );

                        // Line length prior to newline insertion
                        const old_line_len =
                            lineLenFromRow(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                        );

                        // How much to increment line break indices
                        const increment_len = old_line_len - active_buffer.cursor_coords.col;

                        // Set current row to newline point index
                        active_buffer.line_break_indices.items[active_buffer.cursor_coords.row] = point_index;
                        try active_buffer.line_break_indices.insert(active_buffer.cursor_coords.row + 1, point_index + increment_len - 1);
                        try shiftLBIndices(
                            scratch_arena,
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row + 1,
                            1,
                        );

                        // Insert the newline
                        try active_buffer.points.insert(point_index, '\n');

                        active_buffer.cursor_coords = cellCoordsRight(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );

                        // FIXME(caleb): If inserting at end of buffer a second newline should be added as well!
                        DEBUGPrintLineIndices(&active_buffer.line_break_indices, &active_buffer.points);
                    } else if (key_pressed == rl.KEY_TAB) {
                        const point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );
                        indentPoints(&active_buffer.points, point_index);
                        try shiftLBIndices(
                            scratch_arena,
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            shift_width,
                        );
                        active_buffer.cursor_coords.col += shift_width;
                    }
                },
                .command => {
                    if (key_pressed == rl.KEY_CAPS_LOCK) {
                        mode = .normal;
                    } else if (key_pressed == rl.KEY_ENTER) { // Evaluate command buffer
                        const line_num = std.fmt.parseUnsigned(
                            usize,
                            command_points.items,
                            10,
                        ) catch null;
                        if (line_num != null) {
                            active_buffer.cursor_coords.row = line_num.? - 1;
                            const cursor_p = rl.Vector2{
                                .x = camera.target.x, // FIXME(caleb)
                                .y = @as(f32, @floatFromInt(
                                    active_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                                )),
                            };
                            if (cursor_p.y > (camera.target.y + @as(f32, @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize)))))) {
                                target_p = rl.Vector2Subtract(cursor_p, .{ .x = 0, .y = @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize))) });
                            }
                        } else {
                            var command_buffer_pieces = mem.splitSequence(u8, command_points.items, " ");
                            const command_buffer_first = command_buffer_pieces.first();

                            if (std.mem.eql(u8, command_buffer_first, "barrel-roll")) {
                                target_rot = 360.0;
                            } else if (std.mem.eql(u8, command_buffer_first, "w")) {
                                if (active_buffer.backed_by_file) {
                                    var dumpf = try std.fs.cwd().createFile(active_buffer.file_path, .{});
                                    var dump_writer = dumpf.writer();
                                    for (active_buffer.points.items) |point| {
                                        const point_u32: u32 = @intCast(point);
                                        try dump_writer.writeByte(@truncate(point_u32));
                                    }
                                    dumpf.close();
                                }
                            } else if (std.mem.eql(u8, command_buffer_first, "o")) {
                                const next_piece = command_buffer_pieces.next();
                                if (next_piece != null) {
                                    var new_buffer = buffersGetAvail(&buffers) orelse buffersReleaseColdest(&buffers) catch unreachable;
                                    try bufferLoadFile(new_buffer, scratch_arena, next_piece.?);
                                    active_buffer = new_buffer;
                                }
                            } else if (std.mem.eql(u8, command_buffer_first, "q")) {
                                break :main_loop;
                            }
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
                        active_buffer.cursor_coords = cellCoordsUp(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                active_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y < camera.target.y) {
                            target_p = rl.Vector2Subtract(target_p, .{ .x = 0, .y = @floatFromInt(font.baseSize) });
                        }
                    } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                        active_buffer.cursor_coords = cellCoordsDown(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                        const cursor_p = rl.Vector2{
                            .x = camera.target.x, // FIXME(caleb)
                            .y = @as(f32, @floatFromInt(
                                active_buffer.cursor_coords.row * @as(usize, @intCast(font.baseSize)),
                            )),
                        };
                        if (cursor_p.y > (camera.target.y + @as(f32, @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize)))))) {
                            target_p = rl.Vector2Subtract(cursor_p, .{ .x = 0, .y = @floatFromInt((rows - 1) * @as(usize, @intCast(font.baseSize))) });
                        }
                    } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                        active_buffer.cursor_coords = cellCoordsRight(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                    } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                        active_buffer.cursor_coords = cellCoordsLeft(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                            active_buffer.cursor_coords.col,
                        );
                    }

                    if (char_pressed == 'x') {
                        active_buffer.selection_coords.col = 0;
                        active_buffer.selection_coords.row = active_buffer.cursor_coords.row;
                        active_buffer.cursor_coords.col = lineLenFromRow(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords.row,
                        ) - 1;
                    } else if (char_pressed == 'd') {
                        const selection_coords_point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.selection_coords,
                        );
                        const cursor_coords_point_index = pointIndexFromCoords(
                            &active_buffer.line_break_indices,
                            active_buffer.cursor_coords,
                        );

                        var selection_start: BufferCoords = undefined;
                        var start_point_index: usize = undefined;
                        var end_point_index: usize = undefined;

                        if (cursor_coords_point_index < selection_coords_point_index) {
                            selection_start = active_buffer.cursor_coords;
                            start_point_index = cursor_coords_point_index;
                            end_point_index = selection_coords_point_index;
                        } else {
                            selection_start = active_buffer.selection_coords;
                            start_point_index = selection_coords_point_index;
                            end_point_index = cursor_coords_point_index;
                        }
                        const selection_len = (end_point_index + 1) - start_point_index;
                        for (0..selection_len) |_| {
                            const removed_point = active_buffer.points.orderedRemove(start_point_index);
                            if (removed_point == '\n') {
                                active_buffer.line_break_indices.items[selection_start.row] +=
                                    lineLenFromRow(&active_buffer.line_break_indices, selection_start.row + 1);
                                _ = active_buffer.line_break_indices.orderedRemove(selection_start.row + 1);
                            }
                        }
                        try shiftLBIndices(
                            scratch_arena,
                            &active_buffer.line_break_indices,
                            selection_start.row,
                            -@as(isize, @intCast(selection_len)),
                        );
                        active_buffer.cursor_coords = selection_start;
                        mode = .normal;
                    }
                },
            }

            if (char_pressed != 0)
                last_char_pressed = char_pressed;

            key_pressed = rl.GetKeyPressed();
            char_pressed = @intCast(rl.GetCharPressed());
        }

        // Lerp camera to target pos
        if (rl.Vector2Equals(camera.target, target_p) == 0) {
            camera.target = rl.Vector2Lerp(
                camera.target,
                target_p,
                0.2,
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
                active_buffer.line_break_indices.items.len - 1,
                @as(usize, @intFromFloat(@divExact(
                    @max(0.0, @round(camera.target.y)),
                    @as(f32, @floatFromInt(font.baseSize)),
                ))),
            );
            const end_camera_row = @min(active_buffer.line_break_indices.items.len, start_camera_row + rows + 2);
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
                    x_offset += refrence_glyph_info.image.width;
                }
                x_offset += refrence_glyph_info.image.width;

                var start_point_index =
                    if (row_index > 0) active_buffer.line_break_indices.items[row_index - 1] + 1 else 0;
                const end_point_index =
                    start_point_index + lineLenFromRow(
                    &active_buffer.line_break_indices,
                    row_index,
                );
                for (active_buffer.points.items[start_point_index..end_point_index]) |point| {
                    if (point == '\n') {
                        y_offset += font.baseSize;
                        x_offset = refrence_glyph_info.image.width * 5;
                        continue;
                    }
                    if (point == '\t') {
                        x_offset += refrence_glyph_info.image.width * 4;
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
                    x_offset += refrence_glyph_info.image.width;
                }
            }
        }

        var cursor_p = cellPFromCoords(
            active_buffer.cursor_coords,
            &active_buffer.points,
            &active_buffer.line_break_indices,
            &refrence_glyph_info,
            &font,
        );
        cursor_p.x += @floatFromInt(refrence_glyph_info.image.width * 5);

        // Draw line highlight
        rl.DrawRectangle(
            @as(c_int, @intFromFloat(cursor_p.x)),
            @as(c_int, @intFromFloat(cursor_p.y)),
            @as(c_int, @intCast(cols)) * refrence_glyph_info.image.width,
            font.baseSize,
            rl.Color{ .r = 255, .g = 255, .b = 255, .a = 20 },
        );

        // Draw cursor
        if (mode == .normal) { // Block
            rl.DrawRectangle(
                @as(c_int, @intFromFloat(cursor_p.x)),
                @as(c_int, @intFromFloat(cursor_p.y)),
                refrence_glyph_info.image.width,
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
                    .x = cursor_p.x + @as(f32, @floatFromInt(refrence_glyph_info.image.width)),
                    .y = cursor_p.y + @as(f32, @floatFromInt(font.baseSize)),
                },
                2.0,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        }

        // Draw selection
        if (mode == .select) { // FIXME(caleb): Only draw selections that can be seen
            const cursor_point = pointIndexFromCoords(&active_buffer.line_break_indices, active_buffer.cursor_coords);
            const selection_point = pointIndexFromCoords(&active_buffer.line_break_indices, active_buffer.selection_coords);
            const start_point_index = @min(cursor_point, selection_point);
            const end_point_index = @max(cursor_point, selection_point);

            var x_offset: c_int = 0;
            var y_offset: c_int = 0;
            if (start_point_index == cursor_point) {
                x_offset = @as(c_int, @intCast(active_buffer.cursor_coords.col)) * refrence_glyph_info.image.width + refrence_glyph_info.image.width * 5;
                y_offset = @as(c_int, @intCast(active_buffer.cursor_coords.row)) * font.baseSize;
            } else {
                x_offset = @as(c_int, @intCast(active_buffer.selection_coords.col)) * refrence_glyph_info.image.width + refrence_glyph_info.image.width * 5;
                y_offset = @as(c_int, @intCast(active_buffer.selection_coords.row)) * font.baseSize;
            }

            for (active_buffer.points.items[start_point_index .. end_point_index + 1]) |point| {
                rl.DrawRectangle(
                    x_offset,
                    y_offset,
                    refrence_glyph_info.image.width,
                    font.baseSize,
                    rl.Color{ .r = 255, .g = 0xa5, .b = 0x00, .a = 128 },
                );

                if (point == '\n') {
                    y_offset += font.baseSize;
                    x_offset = refrence_glyph_info.image.width * 4;
                }
                if (point == '\t') {
                    x_offset += refrence_glyph_info.image.width * 4;
                } else {
                    x_offset += refrence_glyph_info.image.width;
                }
            }
        }

        rl.EndMode2D();

        // Draw command buffer
        if (mode == .command) {
            rl.DrawRectangle(
                0,
                font.baseSize * @as(c_int, @intCast(rows - 1)),
                @as(c_int, @intCast(cols)) * refrence_glyph_info.image.width,
                font.baseSize,
                rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
            );

            rl.DrawTextCodepoint(font, ':', .{
                .x = 0,
                .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(rows - 1))),
            }, @floatFromInt(font.baseSize), rl.WHITE);
            DEBUG_glyphs_drawn_this_frame += 1;

            var x_offset: c_int = refrence_glyph_info.image.width;
            for (command_points.items) |point| {
                rl.DrawTextCodepoint(font, point, .{
                    .x = @floatFromInt(x_offset),
                    .y = @floatFromInt(font.baseSize * @as(c_int, @intCast(rows - 1))),
                }, @floatFromInt(font.baseSize), rl.WHITE);
                DEBUG_glyphs_drawn_this_frame += 1;
                x_offset += refrence_glyph_info.image.width;
            }

            rl.DrawRectangle(
                refrence_glyph_info.image.width * @as(c_int, @intCast(command_points_index + 1)),
                font.baseSize * @as(c_int, @intCast(rows - 1)),
                refrence_glyph_info.image.width,
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
            const glyph_draw_countz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "glyphs drawn: {d}",
                .{DEBUG_glyphs_drawn_this_frame},
            );
            const point_indexz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "point index: {d}",
                .{pointIndexFromCoords(
                    &active_buffer.line_break_indices,
                    active_buffer.cursor_coords,
                )},
            );
            const cursor_coordsz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "cursor_p: ({d}, {d})",
                .{
                    active_buffer.cursor_coords.col,
                    active_buffer.cursor_coords.row,
                },
            );
            for (&[_][:0]const u8{
                fpsz,
                glyph_draw_countz,
                point_indexz,
                cursor_coordsz,
            }, 0..) |textz, debug_text_index| {
                rl.DrawTextEx(font, textz, .{
                    .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * refrence_glyph_info.image.width, 4) * 3),
                    .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * font.baseSize, 10) * 8 + font.baseSize * @as(c_int, @intCast(debug_text_index))),
                }, @floatFromInt(font.baseSize), 0, rl.RED);
            }
        }
        rl.EndDrawing();
    }

    rl.CloseWindow();
}
