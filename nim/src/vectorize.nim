## Converte payload JSON da requisição em vetor float32[14] normalizado.
##
## Constantes vêm de resources/normalization.json e mcc_risk.json (hardcoded
## aqui para evitar IO no hot path).

import std/[math, options, tables, times]

import jsony

import types

const
  MaxAmount = 10_000.0'f32
  MaxInstallments = 12.0'f32
  AmountVsAvgRatio = 10.0'f32
  MaxMinutes = 1440.0'f32
  MaxKm = 1000.0'f32
  MaxTxCount24h = 20.0'f32
  MaxMerchantAvgAmount = 10_000.0'f32

  ## Tabela MCC → risco (default 0.5 quando não encontrado).
  McRiskTable = {
    "5411": 0.15'f32, "5812": 0.30'f32, "5912": 0.20'f32, "5944": 0.45'f32,
    "7801": 0.80'f32, "7802": 0.75'f32, "7995": 0.85'f32, "4511": 0.35'f32,
    "5311": 0.25'f32, "5999": 0.50'f32,
  }.toTable

  DefaultMccRisk = 0.5'f32


type
  Transaction* = object
    amount*: float32
    installments*: int
    requested_at*: string

  Customer* = object
    avg_amount*: float32
    tx_count_24h*: int
    known_merchants*: seq[string]

  Merchant* = object
    id*: string
    mcc*: string
    avg_amount*: float32

  Terminal* = object
    is_online*: bool
    card_present*: bool
    km_from_home*: float32

  LastTransaction* = object
    timestamp*: string
    km_from_current*: float32

  Payload* = object
    id*: string
    transaction*: Transaction
    customer*: Customer
    merchant*: Merchant
    terminal*: Terminal
    last_transaction*: Option[LastTransaction]


proc clamp01(x: float32): float32 {.inline.} =
  if x < 0: 0.0'f32
  elif x > 1: 1.0'f32
  else: x


proc parseIsoUtc(s: string): DateTime =
  ## Aceita formatos com 'Z' final. As queries da Rinha vêm em UTC.
  parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())


proc parsePayload*(body: string): Payload =
  body.fromJson(Payload)


proc minutesBetween(now, prev: DateTime): float32 =
  float32((now - prev).inMinutes)


proc vectorize*(p: Payload): QueryF32 =
  let txAmount = p.transaction.amount

  # 0: amount
  result[0] = clamp01(txAmount / MaxAmount)

  # 1: installments
  result[1] = clamp01(float32(p.transaction.installments) / MaxInstallments)

  # 2: amount_vs_avg (defendido contra div zero)
  let avg = p.customer.avg_amount
  if avg <= 0.0'f32:
    result[2] = 1.0'f32
  else:
    result[2] = clamp01((txAmount / avg) / AmountVsAvgRatio)

  # 3, 4: hora do dia / dia da semana (UTC)
  let now = parseIsoUtc(p.transaction.requested_at)
  result[3] = float32(now.hour) / 23.0'f32
  # weekday: ord(dMon) = 0, ord(dSun) = 6
  result[4] = float32(ord(now.weekday)) / 6.0'f32

  # 5, 6: minutes_since_last_tx, km_from_last_tx (sentinel -1 se null)
  if p.last_transaction.isSome:
    let lt = p.last_transaction.get
    let prev = parseIsoUtc(lt.timestamp)
    let minutes = minutesBetween(now, prev)
    result[5] = clamp01(minutes / MaxMinutes)
    result[6] = clamp01(lt.km_from_current / MaxKm)
  else:
    result[5] = -1.0'f32
    result[6] = -1.0'f32

  # 7: km_from_home
  result[7] = clamp01(p.terminal.km_from_home / MaxKm)

  # 8: tx_count_24h
  result[8] = clamp01(float32(p.customer.tx_count_24h) / MaxTxCount24h)

  # 9: is_online
  result[9] = if p.terminal.is_online: 1.0'f32 else: 0.0'f32

  # 10: card_present
  result[10] = if p.terminal.card_present: 1.0'f32 else: 0.0'f32

  # 11: unknown_merchant — 1 se merchant.id não está em known_merchants
  var known = false
  for m in p.customer.known_merchants:
    if m == p.merchant.id:
      known = true
      break
  result[11] = if known: 0.0'f32 else: 1.0'f32

  # 12: mcc_risk (lookup, default 0.5)
  result[12] = McRiskTable.getOrDefault(p.merchant.mcc, DefaultMccRisk)

  # 13: merchant_avg_amount
  result[13] = clamp01(p.merchant.avg_amount / MaxMerchantAvgAmount)
