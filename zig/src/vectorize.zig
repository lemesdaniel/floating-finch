//! Parse JSON payload + extração das 14 features (espelha vectorize.nim).

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

const Transaction = struct {
    amount: f32,
    installments: i32,
    requested_at: []const u8,
};

const Customer = struct {
    avg_amount: f32,
    tx_count_24h: i32,
    known_merchants: []const []const u8,
};

const Merchant = struct {
    id: []const u8,
    mcc: []const u8,
    avg_amount: f32,
};

const Terminal = struct {
    is_online: bool,
    card_present: bool,
    km_from_home: f32,
};

const LastTransaction = struct {
    timestamp: []const u8,
    km_from_current: f32,
};

const Payload = struct {
    id: []const u8,
    transaction: Transaction,
    customer: Customer,
    merchant: Merchant,
    terminal: Terminal,
    last_transaction: ?LastTransaction = null,
};

pub const VectorizeError = error{ ParseFailure, BadDate };

pub fn vectorizeBody(body: []const u8, allocator: std.mem.Allocator) !types.QueryF32 {
    const parsed = std.json.parseFromSlice(Payload, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.ParseFailure;
    defer parsed.deinit();
    const p = parsed.value;
    var out: types.QueryF32 = undefined;

    out[0] = clamp01(p.transaction.amount / MaxAmount);
    out[1] = clamp01(@as(f32, @floatFromInt(p.transaction.installments)) / MaxInstallments);

    if (p.customer.avg_amount <= 0.0) {
        out[2] = 1.0;
    } else {
        out[2] = clamp01((p.transaction.amount / p.customer.avg_amount) / AmountVsAvgRatio);
    }

    const now_t = datetime.parseIso(p.transaction.requested_at) catch return error.BadDate;
    out[3] = @as(f32, @floatFromInt(now_t.hour)) / 23.0;
    out[4] = @as(f32, @floatFromInt(datetime.weekday(now_t))) / 6.0;

    if (p.last_transaction) |lt| {
        const prev_t = datetime.parseIso(lt.timestamp) catch return error.BadDate;
        const minutes = @as(f32, @floatFromInt(@divFloor(
            datetime.epochSeconds(now_t) - datetime.epochSeconds(prev_t),
            60,
        )));
        out[5] = clamp01(minutes / MaxMinutes);
        out[6] = clamp01(lt.km_from_current / MaxKm);
    } else {
        out[5] = -1.0;
        out[6] = -1.0;
    }

    out[7] = clamp01(p.terminal.km_from_home / MaxKm);
    out[8] = clamp01(@as(f32, @floatFromInt(p.customer.tx_count_24h)) / MaxTxCount24h);
    out[9] = if (p.terminal.is_online) 1.0 else 0.0;
    out[10] = if (p.terminal.card_present) 1.0 else 0.0;

    var known = false;
    for (p.customer.known_merchants) |m| {
        if (std.mem.eql(u8, m, p.merchant.id)) {
            known = true;
            break;
        }
    }
    out[11] = if (known) 0.0 else 1.0;

    out[12] = lookupMccRisk(p.merchant.mcc);
    out[13] = clamp01(p.merchant.avg_amount / MaxMerchantAvgAmount);

    return out;
}
