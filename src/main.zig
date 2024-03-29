//!
//! main.zig
//!
//! Caleb Barger
//! 11/17/2023
//! zig 0.11.0
//!

//- cabarger: Use this thing to build itself:
// Port what I already had working [ ]
// "Data loss very bad" now you say "data loss very bad." [ ]
// The empty file... [ ]
// Handle '\r' ??? [ ]

//- cabarger: Approaching usable editor:
// Nav / basic actions [ ]
//  Smart indents on line break [ ]
// Basic history [ ]
//  Registers??
// Scrolling past start and end of text  [ ]

//- cabarger: Eventually..
// VSPLIT
// Move off of raylib

const std = @import("std");
const rl = @import("rl.zig");
const base_thread_context = @import("base_thread_context.zig");

const mem = std.mem;
const heap = std.heap;
const math = std.math;

const TCTX = base_thread_context.TCTX;
const ArrayList = std.ArrayList;
const TailQueue = std.TailQueue;

const Buffer = @import("Buffer.zig");

const Vec2U32 = @Vector(2, u32);
const Vec2I32 = @Vector(2, i32);

const default_font_size = 20;

const background_color = rl.Color{ .r = 30, .g = 30, .b = 30, .a = 255 };

const mode_strs = [_][]const c_int{
    &[_]c_int{ 'N', 'O', 'R' },
    &[_]c_int{ 'I', 'N', 'S' },
    &[_]c_int{ 'C', 'M', 'D' },
    &[_]c_int{ 'S', 'E', 'L' },
};

const Mode = enum(u8) {
    normal,
    insert,
    command,
    select,
};

const BufferCoords = Buffer.BufferCoords;

//- NOTE(cabarger): Play around with this type alias...
// I'll probably change it later.
const BufferLine = TailQueue(TailQueue(u8)).Node;

fn DEBUGPrintLine(line_node: *TailQueue(TailQueue(u8)).Node) void {
    var current_char_node = line_node.data.first;
    while (current_char_node != null) : (current_char_node = current_char_node.?.next) {
        std.debug.print("{c}", .{(current_char_node orelse unreachable).data});
    }
    std.debug.print("\n", .{});
}

const log = std.log;

fn cellPFromCoords(
    coords: BufferCoords,
    lines: *TailQueue(TailQueue(u8)),
    refrence_glyph_info: *const rl.GlyphInfo,
    font: *const rl.Font,
) rl.Vector2 {
    _ = font;
    var cursor_p = rl.Vector2{
        .x = 0.0,
        .y = @floatFromInt(coords.row * @as(usize, @intCast(refrence_glyph_info.image.height))),
    };
    var current_line = lines.first;
    {
        var line_index: usize = 0;
        while (current_line != null) : (current_line = current_line.?.next) {
            if (line_index == coords.row)
                break;
            line_index += 1;
        }
    }
    if (current_line != null) {
        var col_index: usize = 0;
        var current_char_node = current_line.?.data.first;
        while (current_char_node != null) : (current_char_node = current_char_node.?.next) {
            if (col_index == coords.col)
                break;
            const point = current_char_node.?.data;
            if (point == '\t') {
                cursor_p.x += @floatFromInt(refrence_glyph_info.image.width * 4);
            } else {
                cursor_p.x += @floatFromInt(refrence_glyph_info.image.width);
            }
            col_index += 1;
        }
    }
    return cursor_p;
}

pub fn main() !void {
    runEditor() catch |err| {
        log.err("Program error: {}\n", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.debug.print("EXITING!!!\n", .{});
        std.os.exit(1);
    };
}

pub fn runEditor() !void {
    var screen_width: usize = 800;
    var screen_height: usize = 600;

    var tctx: TCTX = undefined;
    base_thread_context.tctxInitAndEquip(&tctx);
    var scratch_arena = base_thread_context.tctxGetScratch(null, 0) orelse unreachable;

    rl.InitWindow(@intCast(screen_width), @intCast(screen_height), "ZEROED v0.0.1");
    rl.SetWindowIcon(rl.LoadImage("zeroed.png"));
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(144);
    rl.SetExitKey(0);

    var font_size: c_int = default_font_size;
    var font: rl.Font = rl.LoadFontEx("ComicMono.ttf", font_size, null, 0);
    var refrence_glyph_info: rl.GlyphInfo = rl.GetGlyphInfo(font, ' ');

    var rows: usize = @divTrunc(screen_height, @as(usize, @intCast(refrence_glyph_info.image.height)));
    var cols: usize = @divTrunc(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));

    var mode: Mode = .normal;

    //~ cabarger: Buffer init

    //- NOTE(cabarger): Store buffers out of band. Active/Inactive????
    var buffers: [2]Buffer = undefined;
    var buffer_arenas = [2]heap.ArenaAllocator{
        heap.ArenaAllocator.init(heap.page_allocator),
        heap.ArenaAllocator.init(heap.page_allocator),
    };

    for (&buffers, 0..) |*buffer, buffer_idx|
        buffer.* = Buffer.init(&buffer_arenas[buffer_idx]);

    var active_buffer = Buffer.reserve(&buffers) orelse unreachable;

    var last_cursor_p: BufferCoords = .{ .row = 0, .col = 0 };

    var command_points_index: usize = 0;
    var command_points = ArrayList(u8).init(scratch_arena.allocator());

    //- cabarger: DEBUG... Load *.zig into active buffer.
    try active_buffer.loadFile("test_buffer.zig");

    var last_char_pressed: u8 = 0;

    var camera = rl.Camera2D{
        .offset = .{ .x = 0.0, .y = 0.0 },
        .target = .{ .x = 0.0, .y = 0.0 },
        .rotation = 0,
        .zoom = 1.0,
    };

    var target_rot: f32 = 0.0;
    var draw_debug_info = false;
    var DEBUG_draw_nls = false;
    var DEBUG_glyphs_drawn_this_frame: usize = 0;

    main_loop: while (true) {
        if (rl.WindowShouldClose())
            break;

        if (rl.IsWindowResized()) {
            screen_width = @intCast(rl.GetScreenWidth());
            screen_height = @intCast(rl.GetScreenHeight());
            rows = @divFloor(screen_height, @as(usize, @intCast(refrence_glyph_info.image.height)));
            cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
        }

        if (rl.IsKeyPressed(rl.KEY_F1)) {
            draw_debug_info = !draw_debug_info;
            DEBUG_draw_nls = !DEBUG_draw_nls;
        }

        const rows_to_draw = rows - 2;
        last_cursor_p = active_buffer.cursor_coords;

        const alt_is_held = rl.IsKeyDown(rl.KEY_LEFT_ALT);
        const ctrl_is_held = rl.IsKeyDown(rl.KEY_LEFT_CONTROL);
        var char_pressed: u8 = @intCast(rl.GetCharPressed());
        var key_pressed: c_int = rl.GetKeyPressed();
        while (key_pressed != 0 or char_pressed != 0) {
            if (char_pressed > 127)
                unreachable; // FIXME(caleb): utf-8 support

            //- cabarger: Mode agnostic input handling.
            if (key_pressed == rl.KEY_ENTER and alt_is_held) {
                if (!rl.IsWindowMaximized()) rl.MaximizeWindow() else rl.RestoreWindow();
                screen_width = @intCast(rl.GetScreenWidth());
                screen_height = @intCast(rl.GetScreenHeight());
                rows = @divFloor(screen_height, @as(usize, @intCast(refrence_glyph_info.image.height)));
                cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
            } else {
                switch (mode) {
                    .normal => {
                        //- cabarger: UI
                        if (key_pressed == rl.KEY_MINUS) {
                            rl.UnloadFont(font);
                            font_size -= 1;
                            font = rl.LoadFontEx("ComicMono.ttf", font_size, null, 0);
                            refrence_glyph_info = rl.GetGlyphInfo(font, ' ');
                            rows = @divFloor(screen_height, @as(usize, @intCast(refrence_glyph_info.image.height)));
                            cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
                        } else if (key_pressed == rl.KEY_EQUAL) {
                            rl.UnloadFont(font);
                            font_size += 1;
                            font = rl.LoadFontEx("ComicMono.ttf", font_size, null, 0);
                            refrence_glyph_info = rl.GetGlyphInfo(font, ' ');
                            rows = @divFloor(screen_height, @as(usize, @intCast(refrence_glyph_info.image.height)));
                            cols = @divFloor(screen_width, @as(usize, @intCast(refrence_glyph_info.image.width)));
                        }

                        //- cabarger: Move cursor up/down/left/right
                        else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                            active_buffer.cursorMove(.{ 0, -1 });
                        } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                            active_buffer.cursorMove(.{ 0, 1 });
                        } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                            active_buffer.cursorMove(.{ 1, 0 });
                        } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                            active_buffer.cursorMove(.{ -1, 0 });
                        }

                        //- cabarger: Scroll buffer up/down by half a screen
                        else if (ctrl_is_held and key_pressed == rl.KEY_D) {
                            active_buffer.cursorMove(.{ 0, @as(i32, @intCast(@divFloor(rows_to_draw, 2))) });
                        } else if (ctrl_is_held and key_pressed == rl.KEY_U) {
                            active_buffer.cursorMove(.{ 0, -@as(i32, @intCast(@divFloor(rows_to_draw, 2))) });
                        }

                        //- cabarger: Scroll buffer up/down by a screen
                        else if (key_pressed == rl.KEY_PAGE_DOWN) {
                            active_buffer.cursorMove(.{ 0, @as(i32, @intCast(rows_to_draw)) });
                        } else if (key_pressed == rl.KEY_PAGE_UP) {
                            active_buffer.cursorMove(.{ 0, -@as(i32, @intCast(rows_to_draw)) });
                        }

                        //- cabarger: Enter insert mode
                        else if (key_pressed == rl.KEY_I) {
                            mode = .insert;
                        }

                        //- cabarger: Enter visual mode
                        if (char_pressed == 'v') {
                            active_buffer.selection_coords = active_buffer.cursor_coords;
                            mode = .select;
                        }

                        //- cabarger: Command mode? Is this a mode? Whatever.
                        else if (char_pressed == ':') {
                            command_points_index = 0;
                            command_points.clearRetainingCapacity();
                            mode = .command;
                        }

                        //- cabarger: Move to end of line and enter insert mode
                        else if (char_pressed == 'A') {
                            const line_node = active_buffer.currentLine();
                            active_buffer.cursor_coords.col = line_node.data.len - 1;
                            mode = .insert;
                        }

                        //- cabarger: Advance right and enter insert mode
                        else if (char_pressed == 'a') {
                            active_buffer.cursorMove(.{ 1, 0 });
                            mode = .insert;
                        }

                        //- cabarger: Select entire line
                        else if (char_pressed == 'x') {
                            active_buffer.selection_coords.col = 0;
                            active_buffer.selection_coords.row = active_buffer.cursor_coords.row;
                        }

                        //- cabarger: Indent left/right
                        else if (char_pressed == '>') {
                            try active_buffer.indentLine();
                        } else if (char_pressed == '<') {
                            const line_node = active_buffer.currentLine();

                            var white_space_count: usize = 0;
                            {
                                var current_char_node = line_node.data.first;
                                while (current_char_node != null) : (current_char_node = current_char_node.?.next) {
                                    const point = current_char_node.?.data;
                                    if (point == ' ')
                                        white_space_count += 1;
                                    if (white_space_count == Buffer.shift_width or point != ' ')
                                        break;
                                }
                            }
                            if (white_space_count > 0) {
                                for (0..white_space_count) |_|
                                    _ = line_node.data.popFirst();
                            }
                        } else if (char_pressed == 'd') {
                            Buffer.bufferRemoveCharAt(
                                active_buffer,
                                active_buffer.cursor_coords,
                            );
                        }
                    },
                    .insert => {
                        //- cabarger: Insert charcater at cursor position
                        if (char_pressed != 0) {
                            _ = Buffer.bufferInsertCharAt(
                                active_buffer,
                                char_pressed,
                                active_buffer.cursor_coords,
                            );
                            active_buffer.cursorMove(.{ 1, 0 });
                        }

                        if (key_pressed == rl.KEY_CAPS_LOCK or key_pressed == rl.KEY_ESCAPE) {
                            mode = .normal;
                        }

                        //- cabarger: Remove character before current cursor coords.
                        else if (key_pressed == rl.KEY_BACKSPACE) {
                            //- cabarger: No-op if we are at 0,0.
                            if (active_buffer.cursor_coords.row != 0 or active_buffer.cursor_coords.col != 0) {
                                active_buffer.cursorMove(.{ 0, -1 });
                                Buffer.bufferRemoveCharAt(
                                    active_buffer,
                                    active_buffer.cursor_coords,
                                );
                            }
                        } else if (key_pressed == rl.KEY_ENTER) {
                            //- cabarger: Insert newline character
                            var line_node = active_buffer.currentLine();
                            var char_node = Buffer.bufferInsertCharAt(
                                active_buffer,
                                '\n',
                                active_buffer.cursor_coords,
                            );

                            var new_line_node = try active_buffer.line_nodes_pool.create();
                            {
                                new_line_node.data = TailQueue(u8){};
                                new_line_node.next = null;
                                var curr_char_node = char_node.next;
                                while (curr_char_node != null) {
                                    var new_char_node = Buffer.bufferNewCharNode(active_buffer, curr_char_node.?.data);
                                    new_line_node.data.append(new_char_node);

                                    var last = curr_char_node;
                                    curr_char_node = curr_char_node.?.next;
                                    line_node.data.remove(last.?);
                                    active_buffer.char_nodes_pool.destroy(last.?);
                                }
                            }
                            active_buffer.lines.insertAfter(line_node, new_line_node);
                            active_buffer.cursorMove(.{ 1, 0 });
                        } else if (key_pressed == rl.KEY_TAB) {
                            try active_buffer.indentLine();
                            active_buffer.cursor_coords.col += Buffer.shift_width;
                        }
                    },
                    .command => {
                        if (key_pressed == rl.KEY_CAPS_LOCK or key_pressed == rl.KEY_ESCAPE) {
                            mode = .normal;
                        } else if (key_pressed == rl.KEY_ENTER) { // Evaluate command buffer
                            const line_num = std.fmt.parseUnsigned(
                                usize,
                                command_points.items,
                                10,
                            ) catch null;
                            if (line_num != null) {
                                active_buffer.cursor_coords.row = std.math.clamp(line_num.?, 1, active_buffer.lines.len) - 1;
                            } else {
                                var command_buffer_pieces = mem.splitSequence(u8, command_points.items, " ");
                                const command_buffer_first = command_buffer_pieces.first();

                                if (mem.eql(u8, command_buffer_first, "barrel-roll")) {
                                    target_rot = 360.0;
                                } else if (mem.eql(u8, command_buffer_first, "w")) {
                                    if (active_buffer.backed_by_file) {
                                        try Buffer.bufferWriteToDisk(active_buffer);
                                    }
                                } else if (mem.eql(u8, command_buffer_first, "o")) {
                                    const next_piece = command_buffer_pieces.next();
                                    if (next_piece != null) {
                                        var existing_buffer_with_this_path: ?*Buffer = null;
                                        {
                                            for (&buffers) |*buffer| {
                                                if (buffer.active and buffer.backed_by_file) {
                                                    //- cabarger: FIXME this needs more rigour
                                                    if (mem.eql(u8, buffer.file_path, next_piece.?)) {
                                                        existing_buffer_with_this_path = buffer;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        if (existing_buffer_with_this_path == null) {
                                            var new_buffer = Buffer.reserve(&buffers) orelse Buffer.releaseColdest(&buffers) catch unreachable;
                                            try new_buffer.loadFile(next_piece.?);
                                            active_buffer = new_buffer;
                                        } else {
                                            active_buffer = existing_buffer_with_this_path.?;
                                        }
                                    }
                                } else if (mem.eql(u8, command_buffer_first, "q")) {
                                    var all_buffers_saved = true;
                                    for (&buffers) |buffer| {
                                        if (buffer.active and buffer.needs_write) {
                                            all_buffers_saved = false;
                                            break;
                                        }
                                    }
                                    if (all_buffers_saved)
                                        break :main_loop;
                                } else if (mem.eql(u8, command_buffer_first, "q!")) {
                                    break :main_loop;
                                } else if (mem.eql(u8, command_buffer_first, "bn")) {
                                    var next_active_buffer: ?*Buffer = null;
                                    {
                                        var buffer_index: usize = 0;
                                        for (&buffers) |*buffer| {
                                            if (buffer == active_buffer)
                                                break;
                                            buffer_index += 1;
                                        }
                                        while (next_active_buffer == null) {
                                            buffer_index = (buffer_index + 1) % buffers.len;
                                            if (buffers[buffer_index].active)
                                                next_active_buffer = &buffers[buffer_index];
                                        }
                                    }
                                    active_buffer = next_active_buffer orelse unreachable;
                                } else if (mem.eql(u8, command_buffer_first, "bp")) {
                                    var next_active_buffer: ?*Buffer = null;
                                    {
                                        var buffer_index: usize = 0;
                                        for (&buffers) |*buffer| {
                                            if (buffer == active_buffer)
                                                break;
                                            buffer_index += 1;
                                        }
                                        while (next_active_buffer == null) {
                                            buffer_index = @intCast(@mod(@as(isize, @intCast(buffer_index)) - 1, buffers.len));
                                            if (buffers[buffer_index].active)
                                                next_active_buffer = &buffers[buffer_index];
                                        }
                                    }
                                    active_buffer = next_active_buffer orelse unreachable;
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
                        if (key_pressed == rl.KEY_CAPS_LOCK or key_pressed == rl.KEY_ESCAPE) {
                            mode = .normal;
                        } else if (key_pressed == rl.KEY_UP or char_pressed == 'k') {
                            active_buffer.cursorMove(.{ 0, -1 });
                        } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                            active_buffer.cursorMove(.{ 0, 1 });
                        } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                            active_buffer.cursorMove(.{ 1, 0 });
                        } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                            active_buffer.cursorMove(.{ -1, 0 });
                        }

                        if (char_pressed == 'x') {
                            active_buffer.cursor_coords.col = 0;
                            active_buffer.cursor_coords.row = active_buffer.cursor_coords.row;
                        } else if (char_pressed == 'd') {
                            const line = active_buffer.currentLine();
                            _ = line;

                            const cursor_coords_point_index = 0;

                            var selection_start: BufferCoords = undefined;
                            var start_point_index: usize = undefined;
                            var end_point_index: usize = undefined;

                            if (cursor_coords_point_index < cursor_coords_point_index) {
                                selection_start = active_buffer.cursor_coords;
                                start_point_index = cursor_coords_point_index;
                                end_point_index = cursor_coords_point_index;
                            } else {
                                selection_start = active_buffer.cursor_coords;
                                start_point_index = cursor_coords_point_index;
                                end_point_index = cursor_coords_point_index;
                            }
                            active_buffer.cursor_coords = selection_start;
                            mode = .normal;
                        }
                    },
                }
            }
            if (char_pressed != 0)
                last_char_pressed = char_pressed;

            key_pressed = rl.GetKeyPressed();
            char_pressed = @intCast(rl.GetCharPressed());
        }

        //- cabarger: Update camera on cursor move.
        if ((last_cursor_p.row != active_buffer.cursor_coords.row) or
            (last_cursor_p.col != active_buffer.cursor_coords.col))
        {
            if (active_buffer.cursor_coords.row < active_buffer.camera_p[1]) {
                active_buffer.camera_p[1] = active_buffer.cursor_coords.row;
            } else if (active_buffer.cursor_coords.row > active_buffer.camera_p[1] + rows_to_draw - 1) {
                active_buffer.camera_p[1] += active_buffer.cursor_coords.row - (active_buffer.camera_p[1] + rows_to_draw - 1);
            }
        }
        const target_p = rl.Vector2{
            .x = 0.0,
            .y = @floatFromInt(active_buffer.camera_p[1] * @as(usize, @intCast(refrence_glyph_info.image.height))),
        };

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
        rl.ClearBackground(background_color);
        rl.BeginMode2D(camera);

        // Draw buffer
        {
            //- cabarger: I hate this
            const active_buffer_line_count = active_buffer.lines.len;
            const start_camera_row: usize = @min(
                @max(1, active_buffer_line_count) - 1,
                @as(usize, @intFromFloat(@divExact(
                    @max(0.0, @round(camera.target.y)),
                    @as(f32, @floatFromInt(refrence_glyph_info.image.height)),
                ))),
            );
            const end_camera_row = @min(active_buffer_line_count, start_camera_row + rows_to_draw + 1);

            var line_index: usize = 0;
            var current_line = active_buffer.lines.first;
            {
                while (current_line != null) : (current_line = current_line.?.next) {
                    if (line_index == start_camera_row)
                        break;
                    line_index += 1;
                }
            }
            while (current_line != null) : (current_line = current_line.?.next) {
                if (line_index == end_camera_row)
                    break;

                var x_offset: c_int = 0;
                var y_offset: c_int = @intCast(line_index * @as(usize, @intCast(refrence_glyph_info.image.height)));

                // Line numbers
                var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
                defer _ = temp_arena.reset(.free_all);

                const line_number_str = try std.fmt.allocPrint(
                    temp_arena.allocator(),
                    "{d: >4}",
                    .{line_index + 1},
                );
                for (line_number_str) |digit_char| {
                    rl.DrawTextCodepoint(
                        font,
                        digit_char,
                        .{
                            .x = @floatFromInt(x_offset),
                            .y = @floatFromInt(y_offset),
                        },
                        @floatFromInt(refrence_glyph_info.image.height),
                        rl.WHITE,
                    );
                    DEBUG_glyphs_drawn_this_frame += 1;
                    x_offset += refrence_glyph_info.image.width;
                }
                x_offset += refrence_glyph_info.image.width;

                var current_char_node = current_line.?.data.first;
                while (current_char_node != null) : (current_char_node = current_char_node.?.next) {
                    const point = current_char_node.?.data;
                    if (point == '\n') {
                        if (DEBUG_draw_nls) {
                            rl.DrawTextCodepoint(
                                font,
                                '$',
                                .{
                                    .x = @floatFromInt(x_offset),
                                    .y = @floatFromInt(y_offset),
                                },
                                @floatFromInt(refrence_glyph_info.image.height),
                                rl.RED,
                            );
                            DEBUG_glyphs_drawn_this_frame += 1;
                        }
                        y_offset += refrence_glyph_info.image.height;
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
                        @floatFromInt(refrence_glyph_info.image.height),
                        rl.WHITE,
                    );
                    DEBUG_glyphs_drawn_this_frame += 1;
                    x_offset += refrence_glyph_info.image.width;
                }

                line_index += 1;
            }
            rl.DrawTextCodepoint(
                font,
                '~',
                .{
                    .x = @floatFromInt(refrence_glyph_info.image.width * 3),
                    .y = @floatFromInt(end_camera_row * @as(usize, @intCast(refrence_glyph_info.image.height))),
                },
                @floatFromInt(refrence_glyph_info.image.height),
                rl.WHITE,
            );
        }

        var cursor_p = cellPFromCoords(
            active_buffer.cursor_coords,
            &active_buffer.lines,
            &refrence_glyph_info,
            &font,
        );
        cursor_p.x += @floatFromInt(refrence_glyph_info.image.width * 5);

        // Draw line highlight
        rl.DrawRectangle(
            @as(c_int, @intFromFloat(0.0)),
            @as(c_int, @intFromFloat(cursor_p.y)),
            @as(c_int, @intCast(cols)) * refrence_glyph_info.image.width,
            refrence_glyph_info.image.height,
            rl.Color{ .r = 255, .g = 255, .b = 255, .a = 20 },
        );

        // Draw cursor
        if (mode == .normal) { // Block
            rl.DrawRectangle(
                @as(c_int, @intFromFloat(cursor_p.x)),
                @as(c_int, @intFromFloat(cursor_p.y)),
                refrence_glyph_info.image.width,
                refrence_glyph_info.image.height,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        } else if (mode == .insert) { // Line
            rl.DrawLineEx(
                cursor_p,
                rl.Vector2{
                    .x = cursor_p.x,
                    .y = cursor_p.y + @as(f32, @floatFromInt(refrence_glyph_info.image.height)),
                },
                2.0,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        } else if (mode == .select) { // Underscore
            rl.DrawLineEx(
                rl.Vector2{
                    .x = cursor_p.x,
                    .y = cursor_p.y + @as(f32, @floatFromInt(refrence_glyph_info.image.height)),
                },
                rl.Vector2{
                    .x = cursor_p.x + @as(f32, @floatFromInt(refrence_glyph_info.image.width)),
                    .y = cursor_p.y + @as(f32, @floatFromInt(refrence_glyph_info.image.height)),
                },
                2.0,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
            );
        }

        // Draw selection
        if (mode == .select) { //- TODO(caleb): Only draw selections that can be seen
            var x_offset: c_int = 0;
            var y_offset: c_int = 0;

            var start_p: @Vector(2, usize) = @bitCast(active_buffer.cursor_coords);
            var end_p: @Vector(2, usize) = @bitCast(active_buffer.selection_coords);

            var start_row = start_p[0];
            var end_row = end_p[0];
            var start_col = start_p[1];
            var end_col = end_p[1];
            {
                if (start_p[0] > end_p[0]) {
                    const tmp = end_row;
                    end_row = start_row;
                    start_row = tmp;
                }
                if (start_p[1] > end_p[1]) {
                    const tmp = end_col;
                    end_col = start_col;
                    start_col = tmp;
                }
            }

            x_offset = @as(c_int, @intCast(start_col)) * refrence_glyph_info.image.width + refrence_glyph_info.image.width * 5;
            y_offset = @as(c_int, @intCast(start_row)) * refrence_glyph_info.image.height;

            for (0..(end_row - start_row) + 1) |row_count| {
                const is_last_row = row_count == end_row - start_row;

                var selection_width = if (is_last_row)
                    refrence_glyph_info.image.width * @as(c_int, @intCast((end_col - start_col) + 1))
                else
                    refrence_glyph_info.image.width * @as(c_int, @intCast(active_buffer.lineFromRow(
                        start_row + row_count,
                    ).data.len));

                rl.DrawRectangle(
                    x_offset,
                    y_offset + refrence_glyph_info.image.height * @as(c_int, @intCast(row_count)),
                    selection_width,
                    refrence_glyph_info.image.height,
                    rl.Color{ .r = 255, .g = 255, .b = 255, .a = 128 },
                );
            }
        }

        rl.EndMode2D();

        // Draw status bar
        {
            var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
            defer _ = temp_arena.reset(.free_all);

            rl.DrawRectangle(
                0,
                refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 2)),
                @as(c_int, @intCast(cols)) * refrence_glyph_info.image.width,
                refrence_glyph_info.image.height * 2,
                background_color,
            );
            rl.DrawTextCodepoints(
                font,
                @ptrCast(mode_strs[@intFromEnum(mode)]),
                3,
                .{ .x = 0, .y = @floatFromInt(refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 2))) },
                @floatFromInt(font_size),
                0.0,
                rl.WHITE,
            );

            //- cabarger: Buffer name
            const mode_str_dim = rl.MeasureTextEx(font, @ptrCast("NOR"), @floatFromInt(font_size), 0.0);
            const buffer_name = try temp_arena.allocator().alloc(c_int, active_buffer.file_path.len);
            for (active_buffer.file_path, 0..) |char, char_index| {
                buffer_name[char_index] = @intCast(char);
            }
            rl.DrawTextCodepoints(
                font,
                @ptrCast(buffer_name),
                @intCast(buffer_name.len),
                .{
                    .x = mode_str_dim.x + @as(f32, @floatFromInt(refrence_glyph_info.image.width)),
                    .y = @floatFromInt(refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 2))),
                },
                @floatFromInt(font_size),
                0.0,
                rl.WHITE,
            );

            //- cabarger: Cursor coords
            const cursor_coords_str_u8 = try std.fmt.allocPrint(
                temp_arena.allocator(),
                "{d}:{d}",
                .{ active_buffer.cursor_coords.row, active_buffer.cursor_coords.col },
            );
            const cursor_coords_str_points = try temp_arena.allocator().alloc(
                c_int,
                cursor_coords_str_u8.len,
            );
            for (cursor_coords_str_u8, 0..) |char, char_index| {
                cursor_coords_str_points[char_index] = @intCast(char);
            }
            const cursor_coords_str_dim = rl.MeasureTextEx(
                font,
                @ptrCast(cursor_coords_str_points),
                @floatFromInt(font_size),
                0.0,
            );

            rl.DrawTextCodepoints(
                font,
                @ptrCast(cursor_coords_str_points),
                @intCast(cursor_coords_str_points.len),
                .{
                    .x = @as(f32, @floatFromInt(refrence_glyph_info.image.width * @as(c_int, @intCast(cols)))) - cursor_coords_str_dim.x * 10.0,
                    .y = @floatFromInt(refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 2))),
                },
                @floatFromInt(font_size),
                0.0,
                rl.WHITE,
            );
        }

        //- cabarger: Draw command buffer
        if (mode == .command) {
            rl.DrawRectangle(
                0,
                refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 1)),
                @as(c_int, @intCast(cols)) * refrence_glyph_info.image.width,
                refrence_glyph_info.image.height,
                background_color,
            );

            rl.DrawTextCodepoint(font, ':', .{
                .x = 0,
                .y = @floatFromInt(refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 1))),
            }, @floatFromInt(refrence_glyph_info.image.height), rl.WHITE);
            DEBUG_glyphs_drawn_this_frame += 1;

            var x_offset: c_int = refrence_glyph_info.image.width;
            for (command_points.items) |point| {
                rl.DrawTextCodepoint(font, point, .{
                    .x = @floatFromInt(x_offset),
                    .y = @floatFromInt(refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 1))),
                }, @floatFromInt(refrence_glyph_info.image.height), rl.WHITE);
                DEBUG_glyphs_drawn_this_frame += 1;
                x_offset += refrence_glyph_info.image.width;
            }

            rl.DrawRectangle(
                refrence_glyph_info.image.width * @as(c_int, @intCast(command_points_index + 1)),
                refrence_glyph_info.image.height * @as(c_int, @intCast(rows - 1)),
                refrence_glyph_info.image.width,
                refrence_glyph_info.image.height,
                rl.Color{
                    .r = 255,
                    .g = 255,
                    .b = 255,
                    .a = 128,
                },
            );
        }

        //- cabarger: Draw debug info
        if (draw_debug_info) {
            var temp_arena = heap.ArenaAllocator.init(scratch_arena.allocator());
            defer _ = temp_arena.reset(.free_all);

            const fpsz = try std.fmt.allocPrintZ(temp_arena.allocator(), "fps: {d}", .{rl.GetFPS()});
            const glyph_draw_countz = try std.fmt.allocPrintZ(
                temp_arena.allocator(),
                "glyphs drawn: {d}",
                .{DEBUG_glyphs_drawn_this_frame},
            );
            for (&[_][:0]const u8{
                fpsz,
                glyph_draw_countz,
            }, 0..) |textz, debug_text_index| {
                rl.DrawTextEx(font, textz, .{
                    .x = @floatFromInt(@divFloor(@as(c_int, @intCast(cols)) * refrence_glyph_info.image.width, 4) * 3),
                    .y = @floatFromInt(@divFloor(@as(c_int, @intCast(rows)) * refrence_glyph_info.image.height, 10) * 8 + refrence_glyph_info.image.height * @as(c_int, @intCast(debug_text_index))),
                }, @floatFromInt(refrence_glyph_info.image.height), 0, rl.RED);
            }
        }

        rl.EndDrawing();
    }
    rl.CloseWindow();
}
