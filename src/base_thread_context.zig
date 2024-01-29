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

const ArenaAllocator = std.heap.ArenaAllocator;

pub const ThreadContext = struct {
    arenas: [2]*ArenaAllocator,
};

tctxInitAndEquip(ThreadContext* tctx) {
    var arenas: []*ArenaAllocator = &tctx.arenas;
    
}
