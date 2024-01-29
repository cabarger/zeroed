//!
//! base_thread_context.zig
//!
//! Caleb Barger
//! 11/17/2023
//! zig 0.11.0
//!
//! Shamelessly stolen from the raddebugger codebase.
//!

const std = @import("std");

const heap = std.heap;

pub threadlocal var tctx_thread_local: *TCTX = undefined;

pub const TCTX = struct {
    arenas: [2]heap.ArenaAllocator,
};

pub fn tctxInitAndEquip(tctx: *TCTX) void {
    for (&tctx.arenas) |*arena|
        arena.* = heap.ArenaAllocator.init(heap.page_allocator);
    tctx_thread_local = tctx;
}

pub inline fn tctxGetEquipped() *TCTX {
    return tctx_thread_local;
}

pub fn tctxGetScratch(conflicts: ?[*]heap.ArenaAllocator, count: usize) ?*heap.ArenaAllocator {
    var tctx = tctxGetEquipped();

    var result: ?*heap.ArenaAllocator = null;
    for (&tctx.arenas) |*arena_ptr| {
        var has_conflict: bool = false;
        for (0..count) |conflict_arena_index| {
            if (arena_ptr == &conflicts.?[conflict_arena_index]) {
                has_conflict = true;
                break;
            }
        }
        if (!has_conflict) {
            result = arena_ptr;
            break;
        }
    }
    return result;
}
