//! Mini parser ISO-8601 UTC ("yyyy-mm-ddTHH:MM:SSZ") + epoch / weekday.
//!
//! Usado para extrair hora-do-dia, dia-da-semana e diff em minutos no hot path.

const std = @import("std");

pub const ParsedTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn parseIso(s: []const u8) !ParsedTime {
    if (s.len < 19) return error.TooShort; // "yyyy-mm-ddTHH:MM:SS" no mínimo
    return ParsedTime{
        .year = try std.fmt.parseUnsigned(u16, s[0..4], 10),
        .month = try std.fmt.parseUnsigned(u8, s[5..7], 10),
        .day = try std.fmt.parseUnsigned(u8, s[8..10], 10),
        .hour = try std.fmt.parseUnsigned(u8, s[11..13], 10),
        .minute = try std.fmt.parseUnsigned(u8, s[14..16], 10),
        .second = try std.fmt.parseUnsigned(u8, s[17..19], 10),
    };
}

/// Howard Hinnant civil_from_days inverse: days from civil(y,m,d).
/// Reference: http://howardhinnant.github.io/date_algorithms.html#days_from_civil
fn daysFromCivil(y_in: i32, m: u32, d: u32) i64 {
    const y: i32 = if (m <= 2) y_in - 1 else y_in;
    const era: i32 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const doy: u32 = (153 * (m + (if (m > 2) @as(u32, 0) else 12) - 3) + 2) / 5 + d - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return @as(i64, era) * 146_097 + @as(i64, doe) - 719_468;
}

pub fn epochSeconds(t: ParsedTime) i64 {
    const days = daysFromCivil(@intCast(t.year), t.month, t.day);
    return days * 86_400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + @as(i64, t.second);
}

/// 0 = Mon, 6 = Sun (igual ao `ord(dMon)..ord(dSun)` do Nim).
pub fn weekday(t: ParsedTime) u8 {
    const days = daysFromCivil(@intCast(t.year), t.month, t.day);
    // 1970-01-01 was a Thursday (Mon=0). Thursday = 3.
    // days_since_epoch + 3 → mod 7
    const w = @mod(days + 3, 7);
    return @intCast(w);
}
