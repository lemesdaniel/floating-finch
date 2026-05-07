## Tipos compartilhados entre preprocess e API runtime.

const
  Dim* = 14                ## Dimensão fixa dos vetores (14 features).
  K* = 5                   ## Top-K do KNN (regulamento Rinha 2026).
  ApprovedThreshold* = 3   ## fraud_count < 3 → approved (equivalente a fraud_score < 0.6).
  QuantScale* = 10_000.0'f32  ## Escala usada na quantização float→int16.

type
  Vec14*[T] = array[Dim, T]
  QueryF32* = Vec14[float32]
  QueryI16* = Vec14[int16]

  Classification* = object
    fraudCount*: uint8     ## 0..5 (faz score = fraudCount * 0.2).
    approved*: bool

const
  ## Respostas pré-formatadas por bucket (k=5 → 6 valores possíveis).
  ## Ordem: índice = fraudCount.
  ResponseByFraudCount* = [
    "{\"approved\":true,\"fraud_score\":0.0}",
    "{\"approved\":true,\"fraud_score\":0.2}",
    "{\"approved\":true,\"fraud_score\":0.4}",
    "{\"approved\":false,\"fraud_score\":0.6}",
    "{\"approved\":false,\"fraud_score\":0.8}",
    "{\"approved\":false,\"fraud_score\":1.0}",
  ]
