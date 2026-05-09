/* Distância euclidiana² em SoA per-cluster com AVX2.
 *
 * vec_soa layout (per cluster, N candidatos):
 *   dim0[0..N-1], dim1[0..N-1], ..., dim13[0..N-1]   (int16, contíguo)
 *
 * Saída: dists_out[i] = sum_d (vec[i][d] - q[d])², em int64.
 *
 * Overflow analysis (max_diff = ~20000 → max_sq = 4e8):
 *   - 4 dims acumulados → 1.6e9 < INT32_MAX (2.15e9) ✓
 *   - 5+ dims acumulados → estoura int32
 * Solução: 4 acumuladores int32 paralelos, cada um com no máximo 4 dims;
 * depois soma em int64.
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
    for (int d = dim_start; d < dim_end; d++) {
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
