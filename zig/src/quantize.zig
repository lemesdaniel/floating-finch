//! Quantização float32 → int16 do query (espelho de quantize.nim).

const std = @import("std");
const types = @import("types.zig");

const SentinelFloat: f32 = -1.0;
const SentinelInt16: i16 = -10_000;

pub fn quantizeQuery(q: types.QueryF32) types.QueryI16 {
    var out: types.QueryI16 = undefined;
    inline for (0..types.Dim) |i| {
        const v = q[i];
        if (v == SentinelFloat) {
            out[i] = SentinelInt16;
        } else {
            const c = std.math.clamp(v, 0.0, 1.0);
            out[i] = @intFromFloat(@round(c * types.QuantScale));
        }
    }
    return out;
}
