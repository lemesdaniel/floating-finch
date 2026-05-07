//! Constantes compartilhadas entre módulos.

pub const Dim: usize = 14;
pub const K: usize = 5;
pub const ApprovedThreshold: u8 = 3;
pub const QuantScale: f32 = 10_000.0;

pub const QueryF32 = [Dim]f32;
pub const QueryI16 = [Dim]i16;

/// Respostas pré-formatadas (k=5 → fraud_count ∈ [0,5] → 6 strings).
/// Indexar por fraud_count: ResponseByFraudCount[fc].
pub const ResponseByFraudCount = [_][]const u8{
    "{\"approved\":true,\"fraud_score\":0.0}",
    "{\"approved\":true,\"fraud_score\":0.2}",
    "{\"approved\":true,\"fraud_score\":0.4}",
    "{\"approved\":false,\"fraud_score\":0.6}",
    "{\"approved\":false,\"fraud_score\":0.8}",
    "{\"approved\":false,\"fraud_score\":1.0}",
};
