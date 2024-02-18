//!
//! main.zig
//!
//! Caleb Barger
//! 11/17/2023
//! zig 0.11.0
//!

//- cabarger: Use this thing to build itself:
// - Port what I already had working [ ]
// - "Data loss very bad" now you say "data loss very bad." [ ]
// - The empty file... [ ]
// - Windows support
//    - handle '\r'

//- cabarger: Approaching usable editor:
// - Nav / basic actions [ ]
//     - Smart indents on line break [ ]
// - Basic history [ ]
//    - Registers??
// - Scrolling past start and end of text  [ ]

//- cabarger: Eventually..
// VSPLIT
// - Move off of raylib

const std = @import("std");
const rl = @import("rl.zig");
const base_thread_context = @import("base_thread_context.zig");

const mem = std.mem;
const heap = std.heap;

const TCTX = base_thread_context.TCTX;
const ArrayList = std.ArrayList;
const TailQueue = std.TailQueue;

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

const BufferCoords = struct {
    row: usize,
    col: usize,
};

const Buffer = struct {
    arena: heap.ArenaAllocator,

    camera_p: @Vector(2, usize),
    selection_coords: BufferCoords,
    cursor_coords: BufferCoords,

    line_nodes_pool: heap.MemoryPool(TailQueue(TailQueue(u8)).Node),
    char_nodes_pool: heap.MemoryPool(TailQueue(u8).Node),

    lines: TailQueue(TailQueue(u8)),

    backed_by_file: bool,
    file_path_buf: [256]u8,
    file_path: []const u8,

    needs_write: bool,
    modified_time: f64,

    active: bool, //- cabarger: Probably can infer this? Also rename this... Possibly loaded or open?
};

fn bufferInit(buffer: *Buffer) void {
    buffer.arena = heap.ArenaAllocator.init(heap.page_allocator);

    buffer.line_nodes_pool =
        heap.MemoryPool(TailQueue(TailQueue(u8)).Node)
        .init(buffer.arena.allocator());

    buffer.char_nodes_pool =
        heap.MemoryPool(TailQueue(u8).Node)
        .init(buffer.arena.allocator());

    buffer.lines = .{};

    buffer.cursor_coords = .{
        .row = 0,
        .col = 0,
    };
    buffer.selection_coords = .{
        .row = 0,
        .col = 0,
    };
    buffer.backed_by_file = false;
    buffer.file_path_buf = undefined;
    buffer.file_path = undefined;
    buffer.needs_write = false;
    buffer.modified_time = 0.0;
    buffer.active = false;
}

fn bufferReset(buffer: *Buffer) void {
    buffer.line_nodes_pool.reset();
    buffer.char_nodes_pool.reset();
    buffer.backed_by_file = false;
    buffer.file_path = undefined;
    buffer.needs_write = false;
    buffer.modified_time = 0.0;
    buffer.camera_p = .{ 0, 0 };
    buffer.cursor_coords = .{ .row = 0, .col = 0 };
    buffer.selection_coords = .{ .row = 0, .col = 0 };
    buffer.active = false;
}

fn DEBUGPrintLine(line_node: *TailQueue(TailQueue(u8)).Node) void {
    var current_char_node = line_node.data.first;
    while (current_char_node != null) : (current_char_node = current_char_node.?.next) {
        std.debug.print("{c}", .{(current_char_node orelse unreachable).data});
    }
    std.debug.print("\n", .{});
}

// NOTE(caleb): It's a bug to write to either of these, is there a way to make them
// read only??
var nil_char_node = TailQueue(u8).Node{
    .prev = null,
    .next = null,
    .data = 0,
};
var nil_line_node = TailQueue(TailQueue(u8)).Node{
    .next = null,
    .prev = null,
    .data = TailQueue(u8){},
};

fn bufferNewCharNode(buffer: *Buffer, char: u8) *TailQueue(u8).Node {
    var char_node = buffer.char_nodes_pool.create() catch return @constCast(&nil_char_node);
    char_node.data = char;
    char_node.next = null;
    return char_node;
}

fn bufferLoadFile(
    buffer: *Buffer,
    scratch_arena: *heap.ArenaAllocator,
    path: []const u8,
) !void {
    bufferReset(buffer); //- cabarger: This is a waste for the initial buffer but whatever.
    _ = scratch_arena;
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
    defer f.close();
    var reader = f.reader();
    {
        var char_list = TailQueue(u8){};
        while (reader.readByte() catch null) |byte| {
            var char_node = try buffer.char_nodes_pool.create();
            char_node.data = byte;
            char_node.next = null;
            char_list.append(char_node);
            if (byte == '\n') {
                var line_node = try buffer.line_nodes_pool.create();
                line_node.data = char_list;
                line_node.next = null;
                buffer.lines.append(line_node);
                char_list = TailQueue(u8){};
            }
        }
        if (char_list.first != null) {
            var line_node = try buffer.line_nodes_pool.create();
            line_node.data = char_list;
            buffer.lines.append(line_node);
        }
    }

    for (path, 0..) |path_byte, path_byte_index|
        buffer.file_path_buf[path_byte_index] = path_byte;
    buffer.file_path = buffer.file_path_buf[0..path.len];
    buffer.backed_by_file = true;

    buffer.active = true; //- cabarger: I don't know where this should happen... Here is fine for now.
}

fn bufferWriteToDisk(buffer: *Buffer) !void {
    var f = try std.fs.cwd().createFile(buffer.file_path, .{});
    defer f.close();
    var writer = f.writer();
    var current_line_node = buffer.lines.first;
    while (current_line_node != null) : (current_line_node = current_line_node.?.next) {
        var current_char_node = current_line_node.?.data.first;
        while (current_char_node != null) : (current_char_node = current_char_node.?.next)
            try writer.writeByte(current_char_node.?.data);
    }
    buffer.needs_write = false;
}

fn buffersGetAvail(buffers: []Buffer) ?*Buffer {
    for (buffers) |*buffer| {
        if (!buffer.active) {
            buffer.active = true;
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
    if (coldest_buffer.backed_by_file) { //- cabarger: Possible data loss here.
        try bufferWriteToDisk(coldest_buffer);
    }
    bufferReset(coldest_buffer);
    return coldest_buffer;
}

inline fn isValidCursorP(
    lines: *TailQueue(TailQueue(u8)),
    p: @Vector(2, isize),
) bool {
    var result = false;
    if (@reduce(.And, (p >= @Vector(2, isize){ 0, 0 }))) {
        var line_node = lineNodeFromRow(lines, @intCast(p[1]));
        var char_node = charNodeFromLineAndCol(line_node, @intCast(p[0]));
        result = (char_node.data != 0);
    }
    return result;
}

const shift_width = 4;
const default_font_size = 20;

fn charNodeFromLineAndCol(
    line_node: *TailQueue(TailQueue(u8)).Node,
    col: usize,
) *TailQueue(u8).Node {
    var result = line_node.data.first;
    var char_node_index: usize = 0;
    while (result != null) : (result = result.?.next) {
        if (char_node_index == col)
            return result.?;
        char_node_index += 1;
    }
    return &nil_char_node;
}

inline fn lineNodeFromRow(
    lines: *TailQueue(TailQueue(u8)),
    row: usize,
) *TailQueue(TailQueue(u8)).Node {
    var result = lines.first;
    var line_index: usize = 0;
    while (result != null) : (result = result.?.next) {
        if (line_index == row)
            return result.?;
        line_index += 1;
    }
    return &nil_line_node;
}

inline fn cursorRight(
    lines: *TailQueue(TailQueue(u8)),
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (isValidCursorP(lines, result + @Vector(2, isize){ 1, 0 })) {
        result[0] += 1;
    } else if (isValidCursorP(lines, @Vector(2, isize){ 0, result[1] + 1 })) {
        result = .{ 0, result[1] + 1 };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

inline fn cursorLeft(
    lines: *TailQueue(TailQueue(u8)),
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (isValidCursorP(lines, result - @Vector(2, isize){ 1, 0 })) {
        result[0] -= 1;
    } else if (isValidCursorP(lines, @Vector(2, isize){ 0, result[1] - 1 })) {
        var line_node = lineNodeFromRow(lines, @intCast(result[1] - 1));
        result = .{ @intCast(line_node.data.len - 1), @intCast(result[1] - 1) };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

fn bufferInsertCharAt(buffer: *Buffer, char: u8, cursor_coords: BufferCoords) *TailQueue(u8).Node {
    var line_node = lineNodeFromRow(
        &buffer.lines,
        cursor_coords.row,
    );
    const char_node = charNodeFromLineAndCol(
        line_node,
        cursor_coords.col,
    );
    var new_char_node = bufferNewCharNode(buffer, char);
    line_node.data.insertBefore(char_node, new_char_node);

    //- FIXME(cabarger): Check a hash on attempt to quit??
    //- I don't like these lines sprinkled everywhere.
    buffer.needs_write = true;
    buffer.modified_time = rl.GetTime();

    return new_char_node;
}

fn bufferRemoveCharAt(buffer: *Buffer, cursor_coords: BufferCoords) void {
    var current_line_node = lineNodeFromRow(
        &buffer.lines,
        cursor_coords.row,
    );
    const char_node = charNodeFromLineAndCol(
        current_line_node,
        cursor_coords.col,
    );
    if (char_node.data != 0) {
        //- cabarger: Do stuff because we are removing a new line
        if (char_node.data == '\n') {
            var next_line_node = current_line_node.next;
            if (next_line_node != null) {

                //- cabarger: Append next lines contents to current line
                while (next_line_node.?.data.popFirst()) |next_line_char_node|
                    current_line_node.data.append(next_line_char_node);

                //- Remove next line
                buffer.lines.remove(next_line_node.?);
                buffer.line_nodes_pool.destroy(next_line_node.?);
            }
        }

        //- cabarger: Remove the char
        current_line_node.data.remove(char_node);
        buffer.char_nodes_pool.destroy(char_node);

        //- cabarger: Is THIS line empty? If so remove it.
        if (current_line_node.data.first == null) {
            buffer.lines.remove(current_line_node);
            buffer.line_nodes_pool.destroy(current_line_node);
        }
    }
}

inline fn cursorUp(
    lines: *TailQueue(TailQueue(u8)),
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (isValidCursorP(lines, result - @Vector(2, isize){ 0, 1 })) {
        result[1] -= 1;
    } else if (isValidCursorP(lines, @Vector(2, isize){ 0, result[1] - 1 })) {
        var line_node = lineNodeFromRow(lines, @intCast(result[1] - 1));
        result = .{ @intCast(line_node.data.len - 1), @intCast(result[1] - 1) };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

inline fn cursorDown(
    lines: *TailQueue(TailQueue(u8)),
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (isValidCursorP(lines, result + @Vector(2, isize){ 0, 1 })) {
        result[1] += 1;
    } else if (isValidCursorP(lines, @Vector(2, isize){ 0, result[1] + 1 })) {
        var line_node = lineNodeFromRow(lines, @intCast(result[1] + 1));
        result = .{ @intCast(line_node.data.len - 1), @intCast(result[1] + 1) };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

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

inline fn indentChars(
    char_nodes_pool: *heap.MemoryPool(TailQueue(u8).Node),
    char_node_list: *TailQueue(u8),
    char_node_start: ?*TailQueue(u8).Node,
) !void {
    if (char_node_start != null) {
        for (0..shift_width) |_| {
            var char_node = try char_nodes_pool.create();
            char_node.data = ' ';
            char_node_list.insertBefore(char_node_start.?, char_node);
        }
    }
}

pub fn main() !void {
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

    //- cabarger: Store buffers out of band. Active/Inactive
    var buffers: [2]Buffer = undefined;
    for (&buffers) |*buffer|
        bufferInit(buffer);
    var active_buffer = buffersGetAvail(&buffers) orelse unreachable;

    var last_cursor_p: BufferCoords = .{ .row = 0, .col = 0 };

    var command_points_index: usize = 0;
    var command_points = ArrayList(u8).init(scratch_arena.allocator());

    //- cabarger: DEBUG... Load *.zig into default buffer.
    try bufferLoadFile(active_buffer, scratch_arena, "test_buffer.zig");

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
                            active_buffer.cursor_coords = cursorUp(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                            active_buffer.cursor_coords = cursorDown(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                            active_buffer.cursor_coords = cursorRight(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                            active_buffer.cursor_coords = cursorLeft(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                        }

                        //- cabarger: Scroll buffer up/down by half a screen
                        else if (ctrl_is_held and key_pressed == rl.KEY_D) {
                            for (0..@divFloor(rows_to_draw, 2)) |_|
                                active_buffer.cursor_coords = cursorDown(
                                    &active_buffer.lines,
                                    .{
                                        active_buffer.cursor_coords.col,
                                        active_buffer.cursor_coords.row,
                                    },
                                );
                        } else if (ctrl_is_held and key_pressed == rl.KEY_U) {
                            for (0..@divFloor(rows_to_draw, 2)) |_|
                                active_buffer.cursor_coords = cursorUp(
                                    &active_buffer.lines,

                                    .{
                                        active_buffer.cursor_coords.col,
                                        active_buffer.cursor_coords.row,
                                    },
                                );
                        }

                        //- cabarger: Scroll buffer up/down by a screen
                        else if (key_pressed == rl.KEY_PAGE_DOWN) {
                            for (0..rows_to_draw) |_|
                                active_buffer.cursor_coords = cursorDown(
                                    &active_buffer.lines,
                                    .{
                                        active_buffer.cursor_coords.col,
                                        active_buffer.cursor_coords.row,
                                    },
                                );
                        } else if (key_pressed == rl.KEY_PAGE_UP) {
                            for (0..rows_to_draw) |_|
                                active_buffer.cursor_coords = cursorUp(
                                    &active_buffer.lines,

                                    .{
                                        active_buffer.cursor_coords.col,
                                        active_buffer.cursor_coords.row,
                                    },
                                );
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
                            const line_node = lineNodeFromRow(
                                &active_buffer.lines,
                                active_buffer.cursor_coords.row,
                            );
                            active_buffer.cursor_coords.col = line_node.data.len - 1;
                            mode = .insert;
                        }

                        //- cabarger: Advance right and enter insert mode
                        else if (char_pressed == 'a') {
                            active_buffer.cursor_coords = cursorRight(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                            mode = .insert;
                        }

                        //- cabarger: Select entire line
                        else if (char_pressed == 'x') {
                            active_buffer.selection_coords.col = 0;
                            active_buffer.selection_coords.row = active_buffer.cursor_coords.row;
                        }

                        //- cabarger: Indent left/right
                        else if (char_pressed == '>') {
                            const line_node = lineNodeFromRow(
                                &active_buffer.lines,
                                active_buffer.cursor_coords.row,
                            );
                            try indentChars(
                                &active_buffer.char_nodes_pool,
                                &line_node.data,
                                line_node.data.first,
                            );
                        } else if (char_pressed == '<') {
                            const line_node = lineNodeFromRow(
                                &active_buffer.lines,
                                active_buffer.cursor_coords.row,
                            );

                            var white_space_count: usize = 0;
                            {
                                var current_char_node = line_node.data.first;
                                while (current_char_node != null) : (current_char_node = current_char_node.?.next) {
                                    const point = current_char_node.?.data;
                                    if (point == ' ')
                                        white_space_count += 1;
                                    if (white_space_count == shift_width or point != ' ')
                                        break;
                                }
                            }
                            if (white_space_count > 0) {
                                for (0..white_space_count) |_|
                                    _ = line_node.data.popFirst();
                            }
                        } else if (char_pressed == 'd') {
                            bufferRemoveCharAt(
                                active_buffer,
                                active_buffer.cursor_coords,
                            );
                        }
                    },
                    .insert => {
                        //- cabarger: Insert charcater at cursor position
                        if (char_pressed != 0) {
                            _ = bufferInsertCharAt(
                                active_buffer,
                                char_pressed,
                                active_buffer.cursor_coords,
                            );
                            active_buffer.cursor_coords = cursorRight(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                        }

                        if (key_pressed == rl.KEY_CAPS_LOCK or key_pressed == rl.KEY_ESCAPE) {
                            mode = .normal;
                        }

                        //- cabarger: Remove character before current cursor coords.
                        else if (key_pressed == rl.KEY_BACKSPACE) {
                            //- cabarger: No-op if we are at 0,0.
                            if (active_buffer.cursor_coords.row != 0 or active_buffer.cursor_coords.col != 0) {
                                active_buffer.cursor_coords = cursorLeft(
                                    &active_buffer.lines,

                                    .{
                                        active_buffer.cursor_coords.col,
                                        active_buffer.cursor_coords.row,
                                    },
                                );
                                bufferRemoveCharAt(
                                    active_buffer,
                                    active_buffer.cursor_coords,
                                );
                            }
                        } else if (key_pressed == rl.KEY_ENTER) {
                            //- cabarger: Insert newline character
                            var line_node = lineNodeFromRow(
                                &active_buffer.lines,
                                active_buffer.cursor_coords.row,
                            );
                            var char_node = bufferInsertCharAt(
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
                                    var new_char_node = bufferNewCharNode(active_buffer, curr_char_node.?.data);
                                    new_line_node.data.append(new_char_node);

                                    var last = curr_char_node;
                                    curr_char_node = curr_char_node.?.next;
                                    line_node.data.remove(last.?);
                                    active_buffer.char_nodes_pool.destroy(last.?);
                                }
                            }
                            active_buffer.lines.insertAfter(line_node, new_line_node);

                            active_buffer.cursor_coords = cursorRight(
                                &active_buffer.lines,
                                .{
                                    active_buffer.cursor_coords.col,
                                    active_buffer.cursor_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_TAB) {
                            const line_node = lineNodeFromRow(
                                &active_buffer.lines,
                                active_buffer.cursor_coords.row,
                            );
                            try indentChars(
                                &active_buffer.char_nodes_pool,
                                &line_node.data,
                                line_node.data.first,
                            );
                            active_buffer.cursor_coords.col += shift_width;
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
                                        try bufferWriteToDisk(active_buffer);
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
                                            var new_buffer = buffersGetAvail(&buffers) orelse buffersReleaseColdest(&buffers) catch unreachable;
                                            try bufferLoadFile(new_buffer, scratch_arena, next_piece.?);
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
                            active_buffer.selection_coords = cursorUp(
                                &active_buffer.lines,
                                .{
                                    active_buffer.selection_coords.col,
                                    active_buffer.selection_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_DOWN or char_pressed == 'j') {
                            active_buffer.selection_coords = cursorDown(
                                &active_buffer.lines,
                                .{
                                    active_buffer.selection_coords.col,
                                    active_buffer.selection_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_RIGHT or char_pressed == 'l') {
                            active_buffer.selection_coords = cursorRight(
                                &active_buffer.lines,
                                .{
                                    active_buffer.selection_coords.col,
                                    active_buffer.selection_coords.row,
                                },
                            );
                        } else if (key_pressed == rl.KEY_LEFT or char_pressed == 'h') {
                            active_buffer.selection_coords = cursorLeft(
                                &active_buffer.lines,

                                .{
                                    active_buffer.selection_coords.col,
                                    active_buffer.selection_coords.row,
                                },
                            );
                        }

                        if (char_pressed == 'x') {
                            active_buffer.selection_coords.col = 0;
                            active_buffer.selection_coords.row = active_buffer.cursor_coords.row;
                        } else if (char_pressed == 'd') {
                            const selection_coords_point_index = 0;
                            const cursor_coords_point_index = 0;

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
            const end_camera_row = @min(active_buffer_line_count, start_camera_row + rows_to_draw);

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

            x_offset = @as(c_int, @intCast(active_buffer.cursor_coords.col)) * refrence_glyph_info.image.width + refrence_glyph_info.image.width * 5;
            y_offset = @as(c_int, @intCast(active_buffer.cursor_coords.row)) * refrence_glyph_info.image.height;

            rl.DrawRectangle(
                x_offset,
                y_offset,
                refrence_glyph_info.image.width * @as(c_int, @intCast(active_buffer.selection_coords.col)),
                refrence_glyph_info.image.height,
                rl.Color{ .r = 0, .g = 255, .b = 255, .a = 128 },
            );
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
                refrence_glyph_info.image.height,
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
