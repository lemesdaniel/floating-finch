//! Parser JSON positional fast-path pros 14 campos fixos da Rinha 2026.
//!
//! Schema (ordem fixa pelo gerador test-data.json):
//!   {"id":"X","transaction":{"amount":N,"installments":N,"requested_at":"ISO"},
//!    "customer":{"avg_amount":N,"tx_count_24h":N,"known_merchants":["..."]},
//!    "merchant":{"id":"M","mcc":"X","avg_amount":N},
//!    "terminal":{"is_online":B,"card_present":B,"km_from_home":N},
//!    "last_transaction":null|{"timestamp":"ISO","km_from_current":N}}
//!
//! Zero alloc, single-pass, slices sobre o buffer original.

const std = @import("std");
const types = @import("types.zig");
const datetime = @import("datetime.zig");

const MaxAmount: f32 = 10_000.0;
const MaxInstallments: f32 = 12.0;
const AmountVsAvgRatio: f32 = 10.0;
const MaxMinutes: f32 = 1440.0;
const MaxKm: f32 = 1000.0;
const MaxTxCount24h: f32 = 20.0;
const MaxMerchantAvgAmount: f32 = 10_000.0;
const DefaultMccRisk: f32 = 0.5;

const McRiskEntry = struct { mcc: []const u8, risk: f32 };
const McRiskTable = [_]McRiskEntry{
    .{ .mcc = "5411", .risk = 0.15 },
    .{ .mcc = "5812", .risk = 0.30 },
    .{ .mcc = "5912", .risk = 0.20 },
    .{ .mcc = "5944", .risk = 0.45 },
    .{ .mcc = "7801", .risk = 0.80 },
    .{ .mcc = "7802", .risk = 0.75 },
    .{ .mcc = "7995", .risk = 0.85 },
    .{ .mcc = "4511", .risk = 0.35 },
    .{ .mcc = "5311", .risk = 0.25 },
    .{ .mcc = "5999", .risk = 0.50 },
};

fn lookupMccRisk(mcc: []const u8) f32 {
    for (McRiskTable) |e| {
        if (std.mem.eql(u8, e.mcc, mcc)) return e.risk;
    }
    return DefaultMccRisk;
}

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

const ParseError = error{ BadFormat, BadDate };

const Parser = struct {
    s: []const u8,
    p: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.p < self.s.len) : (self.p += 1) {
            const c = self.s[self.p];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return;
        }
    }

    fn expect(self: *Parser, c: u8) !void {
        self.skipWs();
        if (self.p >= self.s.len or self.s[self.p] != c) return error.BadFormat;
        self.p += 1;
    }

    /// Pula até depois de `,"name":` (ou `"name":` se for o primeiro campo).
    fn skipKey(self: *Parser, name: []const u8) !void {
        self.skipWs();
        // pula vírgula opcional
        if (self.p < self.s.len and self.s[self.p] == ',') self.p += 1;
        self.skipWs();
        // espera "
        try self.expect('"');
        if (self.p + name.len > self.s.len) return error.BadFormat;
        if (!std.mem.eql(u8, self.s[self.p .. self.p + name.len], name)) return error.BadFormat;
        self.p += name.len;
        try self.expect('"');
        self.skipWs();
        try self.expect(':');
    }

    /// Le string `"..."`. Retorna slice sobre o buffer (sem escapes — payloads
    /// da Rinha não usam escapes nos campos relevantes).
    fn readString(self: *Parser) ![]const u8 {
        self.skipWs();
        try self.expect('"');
        const start = self.p;
        while (self.p < self.s.len and self.s[self.p] != '"') : (self.p += 1) {}
        if (self.p >= self.s.len) return error.BadFormat;
        const slice = self.s[start..self.p];
        self.p += 1; // consume "
        return slice;
    }

    /// Pula uma string `"..."` sem retornar.
    fn skipString(self: *Parser) !void {
        _ = try self.readString();
    }

    fn readFloat(self: *Parser) !f32 {
        self.skipWs();
        const start = self.p;
        while (self.p < self.s.len) : (self.p += 1) {
            const c = self.s[self.p];
            if (c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r' or c == '\t') break;
        }
        return std.fmt.parseFloat(f32, self.s[start..self.p]) catch error.BadFormat;
    }

    fn readInt(self: *Parser) !i32 {
        self.skipWs();
        const start = self.p;
        while (self.p < self.s.len) : (self.p += 1) {
            const c = self.s[self.p];
            if (c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r' or c == '\t') break;
        }
        return std.fmt.parseInt(i32, self.s[start..self.p], 10) catch error.BadFormat;
    }

    fn readBool(self: *Parser) !bool {
        self.skipWs();
        if (self.p + 4 <= self.s.len and std.mem.eql(u8, self.s[self.p .. self.p + 4], "true")) {
            self.p += 4;
            return true;
        }
        if (self.p + 5 <= self.s.len and std.mem.eql(u8, self.s[self.p .. self.p + 5], "false")) {
            self.p += 5;
            return false;
        }
        return error.BadFormat;
    }

    fn isNull(self: *Parser) bool {
        self.skipWs();
        if (self.p + 4 <= self.s.len and std.mem.eql(u8, self.s[self.p .. self.p + 4], "null")) {
            self.p += 4;
            return true;
        }
        return false;
    }

    /// Pula um array `[...]` arbitrário (assume sem strings escapadas).
    fn skipArray(self: *Parser) !void {
        self.skipWs();
        try self.expect('[');
        var depth: i32 = 1;
        while (self.p < self.s.len and depth > 0) : (self.p += 1) {
            const c = self.s[self.p];
            switch (c) {
                '[' => depth += 1,
                ']' => depth -= 1,
                '"' => {
                    self.p += 1;
                    while (self.p < self.s.len and self.s[self.p] != '"') : (self.p += 1) {}
                },
                else => {},
            }
        }
    }
};

pub fn vectorizeBody(body: []const u8, _: std.mem.Allocator) !types.QueryF32 {
    var pr = Parser{ .s = body };
    var out: types.QueryF32 = undefined;

    try pr.expect('{');

    try pr.skipKey("id");
    try pr.skipString();

    // transaction
    try pr.skipKey("transaction");
    try pr.expect('{');
    try pr.skipKey("amount");
    const tx_amount = try pr.readFloat();
    try pr.skipKey("installments");
    const installments = try pr.readInt();
    try pr.skipKey("requested_at");
    const requested_at = try pr.readString();
    try pr.expect('}');

    // customer
    try pr.skipKey("customer");
    try pr.expect('{');
    try pr.skipKey("avg_amount");
    const customer_avg = try pr.readFloat();
    try pr.skipKey("tx_count_24h");
    const tx_count = try pr.readInt();
    try pr.skipKey("known_merchants");
    // Vamos varrer manualmente pra coletar strings (precisamos comparar com merchant.id depois).
    // Em vez de alocar, guardamos slices em buffer fixo no stack.
    pr.skipWs();
    try pr.expect('[');
    var known_buf: [16][]const u8 = undefined;
    var known_count: usize = 0;
    pr.skipWs();
    if (pr.p < pr.s.len and pr.s[pr.p] != ']') {
        while (true) {
            const s = try pr.readString();
            if (known_count < known_buf.len) {
                known_buf[known_count] = s;
                known_count += 1;
            }
            pr.skipWs();
            if (pr.p < pr.s.len and pr.s[pr.p] == ',') {
                pr.p += 1;
                continue;
            }
            break;
        }
    }
    try pr.expect(']');
    try pr.expect('}');

    // merchant
    try pr.skipKey("merchant");
    try pr.expect('{');
    try pr.skipKey("id");
    const merchant_id = try pr.readString();
    try pr.skipKey("mcc");
    const mcc = try pr.readString();
    try pr.skipKey("avg_amount");
    const merchant_avg = try pr.readFloat();
    try pr.expect('}');

    // terminal
    try pr.skipKey("terminal");
    try pr.expect('{');
    try pr.skipKey("is_online");
    const is_online = try pr.readBool();
    try pr.skipKey("card_present");
    const card_present = try pr.readBool();
    try pr.skipKey("km_from_home");
    const km_from_home = try pr.readFloat();
    try pr.expect('}');

    // last_transaction (null ou {timestamp, km_from_current})
    try pr.skipKey("last_transaction");
    var has_last = false;
    var last_timestamp: []const u8 = "";
    var last_km: f32 = 0.0;
    if (!pr.isNull()) {
        try pr.expect('{');
        try pr.skipKey("timestamp");
        last_timestamp = try pr.readString();
        try pr.skipKey("km_from_current");
        last_km = try pr.readFloat();
        try pr.expect('}');
        has_last = true;
    }

    // Calcula vetor
    out[0] = clamp01(tx_amount / MaxAmount);
    out[1] = clamp01(@as(f32, @floatFromInt(installments)) / MaxInstallments);
    if (customer_avg <= 0.0) {
        out[2] = 1.0;
    } else {
        out[2] = clamp01((tx_amount / customer_avg) / AmountVsAvgRatio);
    }

    const now_t = datetime.parseIso(requested_at) catch return error.BadDate;
    out[3] = @as(f32, @floatFromInt(now_t.hour)) / 23.0;
    out[4] = @as(f32, @floatFromInt(datetime.weekday(now_t))) / 6.0;

    if (has_last) {
        const prev_t = datetime.parseIso(last_timestamp) catch return error.BadDate;
        const minutes = @as(f32, @floatFromInt(@divFloor(
            datetime.epochSeconds(now_t) - datetime.epochSeconds(prev_t),
            60,
        )));
        out[5] = clamp01(minutes / MaxMinutes);
        out[6] = clamp01(last_km / MaxKm);
    } else {
        out[5] = -1.0;
        out[6] = -1.0;
    }

    out[7] = clamp01(km_from_home / MaxKm);
    out[8] = clamp01(@as(f32, @floatFromInt(tx_count)) / MaxTxCount24h);
    out[9] = if (is_online) 1.0 else 0.0;
    out[10] = if (card_present) 1.0 else 0.0;

    var known = false;
    for (known_buf[0..known_count]) |m| {
        if (std.mem.eql(u8, m, merchant_id)) {
            known = true;
            break;
        }
    }
    out[11] = if (known) 0.0 else 1.0;

    out[12] = lookupMccRisk(mcc);
    out[13] = clamp01(merchant_avg / MaxMerchantAvgAmount);

    return out;
}
