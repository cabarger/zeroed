//!
//! rl.zig
//!
//! Author: Caleb Barger
//! Date: 11/17/2023
//! Compiler: zig 0.11.0
//!
//! Imports raylib headers under "rl" namespace.
//!

pub usingnamespace @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
});
