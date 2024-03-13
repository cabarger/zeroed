//!
//! Buffer.zig
//!
//! Caleb Barger
//! 03/03/2024
//! zig 0.11.0
//!

const std = @import("std");

const heap = std.heap;
const math = std.math;

const ArrayList = std.ArrayList;
const TailQueue = std.TailQueue;

const Vec2U32 = @Vector(2, u32);
const Vec2I32 = @Vector(2, i32);

const Buffer = @This();

//- NOTE(cabarger): Play around with this type alias...
// I'll probably change it later.
const BufferLine = TailQueue(TailQueue(u8)).Node;

//- NOTE(cabarger): It's a bug to write to either of these, is there a way to make them
// read only??
// I think the solution is define a readonly segment and store these values there.
var nil_char_node = TailQueue(u8).Node{
    .prev = null,
    .next = null,
    .data = 0,
};
var nil_line_node = BufferLine{
    .next = null,
    .prev = null,
    .data = TailQueue(u8){},
};

pub const BufferCoords = packed struct {
    col: usize,
    row: usize,
};

arena: *heap.ArenaAllocator,

line_nodes_pool: heap.MemoryPool(BufferLine),
char_nodes_pool: heap.MemoryPool(TailQueue(u8).Node),

camera_p: @Vector(2, usize) = .{ 0, 0 },
selection_coords: BufferCoords = .{ .row = 0, .col = 0 },
cursor_coords: BufferCoords = .{ .row = 0, .col = 0 },

lines: TailQueue(TailQueue(u8)) = .{},

backed_by_file: bool = false,
file_path_buf: [256]u8 = undefined,
file_path: []const u8 = undefined,

needs_write: bool = false,
modified_time: f64 = 0.0,

active: bool = false, //- cabarger: Probably can infer this? Also rename this... Possibly loaded or open?

inline fn cursorRight(
    buffer: *Buffer,
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (buffer.isValidCursorP(result + @Vector(2, isize){ 1, 0 })) {
        result[0] += 1;
    } else if (buffer.isValidCursorP(@Vector(2, isize){ 0, result[1] + 1 })) {
        result = .{ 0, result[1] + 1 };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

inline fn cursorLeft(
    buffer: *Buffer,
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (buffer.isValidCursorP(result - @Vector(2, isize){ 1, 0 })) {
        result[0] -= 1;
    } else if (buffer.isValidCursorP(@Vector(2, isize){ 0, result[1] - 1 })) {
        var line_node = buffer.lineFromRow(@intCast(result[1] - 1));
        result = .{ @intCast(line_node.data.len - 1), @intCast(result[1] - 1) };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

inline fn cursorUp(
    buffer: *Buffer,
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (buffer.isValidCursorP(result - @Vector(2, isize){ 0, 1 })) {
        result[1] -= 1;
    } else if (buffer.isValidCursorP(@Vector(2, isize){ 0, result[1] - 1 })) {
        var line_node = buffer.lineFromRow(@intCast(result[1] - 1));
        result = .{ @intCast(line_node.data.len - 1), @intCast(result[1] - 1) };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

inline fn cursorDown(
    buffer: *Buffer,
    p: @Vector(2, usize),
) BufferCoords {
    var result: @Vector(2, isize) = @intCast(p);
    if (buffer.isValidCursorP(result + @Vector(2, isize){ 0, 1 })) {
        result[1] += 1;
    } else if (buffer.isValidCursorP(@Vector(2, isize){ 0, result[1] + 1 })) {
        var line_node = buffer.lineFromRow(@intCast(result[1] + 1));
        result = .{ @intCast(line_node.data.len - 1), @intCast(result[1] + 1) };
    }
    return BufferCoords{ .row = @intCast(result[1]), .col = @intCast(result[0]) };
}

pub fn cursorMove(buffer: *Buffer, cursor_delta: Vec2I32) void {
    const component_wise_is_positive = cursor_delta >= Vec2I32{ 0, 0 };
    for (0..@as(usize, @intCast(math.absInt(cursor_delta[0]) catch unreachable))) |_| {
        buffer.cursor_coords = if (component_wise_is_positive[0])
            buffer.cursorRight(@bitCast(buffer.cursor_coords))
        else
            buffer.cursorLeft(@bitCast(buffer.cursor_coords));
    }
    for (0..@as(usize, @intCast(math.absInt(cursor_delta[1]) catch unreachable))) |_| {
        buffer.cursor_coords = if (component_wise_is_positive[1])
            buffer.cursorDown(@bitCast(buffer.cursor_coords))
        else
            buffer.cursorUp(@bitCast(buffer.cursor_coords));
    }
}

pub inline fn isValidCursorP(buffer: *Buffer, p: @Vector(2, isize)) bool {
    var result = false;
    if (@reduce(.And, (p >= @Vector(2, isize){ 0, 0 }))) {
        var line_node = buffer.lineFromRow(@intCast(p[1]));
        var char_node = charNodeFromLineAndCol(line_node, @intCast(p[0]));
        result = (char_node.data != 0);
    }
    return result;
}

pub fn lineFromRow(buffer: *Buffer, row: usize) *BufferLine {
    var result = buffer.lines.first;
    var line_index: usize = 0;
    while (result != null) : (result = result.?.next) {
        if (line_index == row)
            return result.?;
        line_index += 1;
    }
    return &nil_line_node;
}

pub fn currentLine(buffer: *Buffer) *BufferLine {
    return buffer.lineFromRow(buffer.cursor_coords.row);
}

pub fn init(arena: *heap.ArenaAllocator) Buffer {
    return Buffer{
        .arena = arena,
        .line_nodes_pool = heap.MemoryPool(BufferLine)
            .init(arena.allocator()),
        .char_nodes_pool = heap.MemoryPool(TailQueue(u8).Node)
            .init(arena.allocator()),
    };
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

pub fn charNodeFromLineAndCol(
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

pub fn bufferNewCharNode(buffer: *Buffer, char: u8) *TailQueue(u8).Node {
    var char_node = buffer.char_nodes_pool.create() catch return @constCast(&nil_char_node);
    char_node.data = char;
    char_node.next = null;
    return char_node;
}

////////////////////////////////
//~ cabarger: Buffer management functions

pub fn loadFile(
    buffer: *Buffer,
    path: []const u8,
) !void {
    bufferReset(buffer); //- cabarger: This is a waste for the initial buffer but whatever.
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

pub fn bufferWriteToDisk(buffer: *Buffer) !void {
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

///- TODO(cabarger): Return nil buffer???
pub fn reserve(buffers: []Buffer) ?*Buffer {
    for (buffers) |*buffer| {
        if (!buffer.active) {
            buffer.active = true;
            return buffer;
        }
    }
    return null;
}

pub fn releaseColdest(buffers: []Buffer) !*Buffer {
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

pub const shift_width = 4;

pub fn bufferInsertCharAt(buffer: *Buffer, char: u8, cursor_coords: BufferCoords) *TailQueue(u8).Node {
    var line_node = buffer.currentLine();
    const char_node = charNodeFromLineAndCol(
        line_node,
        cursor_coords.col,
    );
    var new_char_node = bufferNewCharNode(buffer, char);
    line_node.data.insertBefore(char_node, new_char_node);

    //- FIXME(cabarger): Check a hash on attempt to quit??
    //- I don't like these lines sprinkled everywhere.
    buffer.needs_write = true;

    return new_char_node;
}

pub fn bufferRemoveCharAt(buffer: *Buffer, cursor_coords: BufferCoords) void {
    var current_line_node = buffer.currentLine();
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

pub fn indentLine(buffer: *Buffer) !void {
    const line = buffer.currentLine();
    try indentChars(&buffer.char_nodes_pool, &line.data, line.data.first);
}

pub inline fn indentChars(
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
