/* Distância euclidiana² em SoA per-cluster com AVX2 + PMADDWD.
 *
 * vec_soa layout (per cluster, N candidatos):
 *   dim0[0..N-1], dim1[0..N-1], ..., dim13[0..N-1]   (int16, contíguo)
 *
 * Saída: dists_out[i] = sum_d (vec[i][d] - q[d])², em int64.
 *
 * Estratégia PMADDWD: par de dims processado em 1 instrução. Loads 2× i16x8,
 * unpack pra (d,d+1,d,d+1,...), sub i16, madd_epi16(diff,diff) → i32×8 com
 * (v0-q0)² + (v1-q1)² por lane.
 *
 * Overflow analysis (max_diff = ~20000 → max_sq = 4e8):
 *   - madd somma 2 pares por lane = 8e8 max (cabe i32, 2.15e9)
 *   - 4 dims acumulados = 2 madds = 1.6e9 < INT32_MAX ✓
 * Mantém 4 acumuladores int32, cada um com até 4 dims (2 iter madd); soma final em int64.
 */

#include <stdint.h>
#include <string.h>

#define DIM 14

#if defined(__AVX2__) && defined(__x86_64__)
#include <immintrin.h>

static inline __m256i sq_chunk_8(const int16_t* vec_soa, int32_t N, int32_t i,
                                 const int16_t* q, int dim_start, int dim_end)
{
    __m256i acc = _mm256_setzero_si256();
    int d = dim_start;
    /* Pares: 1 madd cobre 2 dims, lane j = (v[d]-q[d])² + (v[d+1]-q[d+1])². */
    for (; d + 1 < dim_end; d += 2) {
        __m128i v0 = _mm_loadu_si128((const __m128i*)(vec_soa + (int64_t)d*N + i));
        __m128i v1 = _mm_loadu_si128((const __m128i*)(vec_soa + (int64_t)(d+1)*N + i));
        /* Interleave (d,d+1) por lane → pares contíguos pro PMADDWD. */
        __m128i lo = _mm_unpacklo_epi16(v0, v1); /* [v0_0,v1_0,...,v0_3,v1_3] */
        __m128i hi = _mm_unpackhi_epi16(v0, v1); /* [v0_4,v1_4,...,v0_7,v1_7] */
        __m256i pairs = _mm256_set_m128i(hi, lo);
        /* Broadcast q[d],q[d+1] como i32 lanes = (uint16)q[d] | ((uint16)q[d+1] << 16). */
        int32_t q_pack = ((int32_t)(uint16_t)q[d])
                       | (((int32_t)(uint16_t)q[d+1]) << 16);
        __m256i q_b  = _mm256_set1_epi32(q_pack);
        __m256i diff = _mm256_sub_epi16(pairs, q_b);
        __m256i sq   = _mm256_madd_epi16(diff, diff);
        acc = _mm256_add_epi32(acc, sq);
    }
    /* Dim sobrando (chunk ímpar): fallback escalar→vetor via cvt+mullo. */
    for (; d < dim_end; d++) {
        __m128i v16  = _mm_loadu_si128((const __m128i*)(vec_soa + (int64_t)d*N + i));
        __m256i v32  = _mm256_cvtepi16_epi32(v16);
        __m256i q32  = _mm256_set1_epi32((int32_t)q[d]);
        __m256i diff = _mm256_sub_epi32(v32, q32);
        __m256i sq   = _mm256_mullo_epi32(diff, diff);
        acc = _mm256_add_epi32(acc, sq);
    }
    return acc;
}

void floating_finch_dists_soa_avx2(const int16_t* vec_soa, int32_t N,
                                   const int16_t* q, int64_t* dists_out)
{
    int32_t i = 0;

    for (; i + 8 <= N; i += 8) {
        __m256i a0 = sq_chunk_8(vec_soa, N, i, q, 0, 4);
        __m256i a1 = sq_chunk_8(vec_soa, N, i, q, 4, 8);
        __m256i a2 = sq_chunk_8(vec_soa, N, i, q, 8, 12);
        __m256i a3 = sq_chunk_8(vec_soa, N, i, q, 12, 14);

        int32_t b0[8] __attribute__((aligned(32)));
        int32_t b1[8] __attribute__((aligned(32)));
        int32_t b2[8] __attribute__((aligned(32)));
        int32_t b3[8] __attribute__((aligned(32)));
        _mm256_store_si256((__m256i*)b0, a0);
        _mm256_store_si256((__m256i*)b1, a1);
        _mm256_store_si256((__m256i*)b2, a2);
        _mm256_store_si256((__m256i*)b3, a3);
        for (int j = 0; j < 8; j++) {
            dists_out[i + j] = (int64_t)b0[j] + (int64_t)b1[j]
                             + (int64_t)b2[j] + (int64_t)b3[j];
        }
    }

    /* Tail escalar */
    for (; i < N; i++) {
        int64_t s = 0;
        for (int32_t d = 0; d < DIM; d++) {
            int32_t diff = (int32_t)vec_soa[(int64_t)d*N + i] - (int32_t)q[d];
            s += (int64_t)diff * (int64_t)diff;
        }
        dists_out[i] = s;
    }
}

#else  /* sem AVX2: fallback escalar puro */

void floating_finch_dists_soa_avx2(const int16_t* vec_soa, int32_t N,
                                   const int16_t* q, int64_t* dists_out)
{
    for (int32_t i = 0; i < N; i++) {
        int64_t s = 0;
        for (int32_t d = 0; d < DIM; d++) {
            int32_t diff = (int32_t)vec_soa[(int64_t)d*N + i] - (int32_t)q[d];
            s += (int64_t)diff * (int64_t)diff;
        }
        dists_out[i] = s;
    }
}

#endif
