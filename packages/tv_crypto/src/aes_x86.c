/*
 * AES-256 with AES-NI (x86_64). Compiled only when TVC_HAVE_X86AES.
 * MSVC: intrinsics need no flags. clang/gcc: per-function target attribute.
 * Selected at runtime only if CPUID reports AES (and SSE4.1, which the
 * target attribute allows the compiler to use).
 */
#include "tv_crypto.h"

#if TVC_HAVE_X86AES

#include <string.h>

#if defined(_MSC_VER)
#include <intrin.h>
#include <wmmintrin.h>
#include <emmintrin.h>
#define TVC_TARGET_AESNI
#else
#include <cpuid.h>
#include <immintrin.h>
#define TVC_TARGET_AESNI __attribute__((target("aes,sse4.1")))
#endif

int tvc_x86_aes_avail(void) {
  unsigned int ecx;
#if defined(_MSC_VER)
  int regs[4];
  __cpuid(regs, 0);
  if (regs[0] < 1) return 0;
  __cpuid(regs, 1);
  ecx = (unsigned int)regs[2];
#else
  unsigned int eax, ebx, edx;
  if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
#endif
  /* bit 25 AES-NI, bit 19 SSE4.1 */
  return ((ecx >> 25) & 1u) && ((ecx >> 19) & 1u);
}

TVC_TARGET_AESNI static void load_keys(const uint8_t* b, __m128i rk[15]) {
  int i;
  for (i = 0; i < 15; i++) rk[i] = _mm_loadu_si128((const __m128i*)(b + 16 * i));
}

TVC_TARGET_AESNI static __m128i enc1(__m128i s, const __m128i rk[15]) {
  int r;
  s = _mm_xor_si128(s, rk[0]);
  for (r = 1; r < 14; r++) s = _mm_aesenc_si128(s, rk[r]);
  return _mm_aesenclast_si128(s, rk[14]);
}

TVC_TARGET_AESNI static __m128i dec1(__m128i s, const __m128i dk[15]) {
  int r;
  s = _mm_xor_si128(s, dk[0]);
  for (r = 1; r < 14; r++) s = _mm_aesdec_si128(s, dk[r]);
  return _mm_aesdeclast_si128(s, dk[14]);
}

TVC_TARGET_AESNI void tvc_x86_aes_ige(int encrypt, const tvc_aes256_key* k,
                                      const uint8_t iv32[32], const uint8_t* in,
                                      uint8_t* out, size_t nblocks) {
  __m128i rk[15];
  __m128i x = _mm_loadu_si128((const __m128i*)iv32);        /* c_prev */
  __m128i y = _mm_loadu_si128((const __m128i*)(iv32 + 16)); /* p_prev */
  size_t i;
  if (encrypt) {
    load_keys(k->ekb, rk);
    for (i = 0; i < nblocks; i++) {
      __m128i p = _mm_loadu_si128((const __m128i*)(in + 16 * i));
      __m128i c = _mm_xor_si128(enc1(_mm_xor_si128(p, x), rk), y);
      _mm_storeu_si128((__m128i*)(out + 16 * i), c);
      x = c;
      y = p;
    }
  } else {
    load_keys(k->dkb, rk);
    for (i = 0; i < nblocks; i++) {
      __m128i c = _mm_loadu_si128((const __m128i*)(in + 16 * i));
      __m128i p = _mm_xor_si128(dec1(_mm_xor_si128(c, y), rk), x);
      _mm_storeu_si128((__m128i*)(out + 16 * i), p);
      x = c;
      y = p;
    }
  }
}

TVC_TARGET_AESNI void tvc_x86_aes_ctr(const tvc_aes256_key* k, uint8_t ctr[16],
                                      const uint8_t* in, uint8_t* out,
                                      size_t nblocks) {
  __m128i rk[15];
  uint8_t cb[64];
  size_t i = 0;
  int r, j;
  load_keys(k->ekb, rk);
  for (; i + 4 <= nblocks; i += 4) {
    __m128i s0, s1, s2, s3;
    for (j = 0; j < 4; j++) {
      memcpy(cb + 16 * j, ctr, 16);
      tvc_ctr_inc(ctr);
    }
    s0 = _mm_xor_si128(_mm_loadu_si128((const __m128i*)cb), rk[0]);
    s1 = _mm_xor_si128(_mm_loadu_si128((const __m128i*)(cb + 16)), rk[0]);
    s2 = _mm_xor_si128(_mm_loadu_si128((const __m128i*)(cb + 32)), rk[0]);
    s3 = _mm_xor_si128(_mm_loadu_si128((const __m128i*)(cb + 48)), rk[0]);
    for (r = 1; r < 14; r++) {
      s0 = _mm_aesenc_si128(s0, rk[r]);
      s1 = _mm_aesenc_si128(s1, rk[r]);
      s2 = _mm_aesenc_si128(s2, rk[r]);
      s3 = _mm_aesenc_si128(s3, rk[r]);
    }
    s0 = _mm_aesenclast_si128(s0, rk[14]);
    s1 = _mm_aesenclast_si128(s1, rk[14]);
    s2 = _mm_aesenclast_si128(s2, rk[14]);
    s3 = _mm_aesenclast_si128(s3, rk[14]);
    s0 = _mm_xor_si128(s0, _mm_loadu_si128((const __m128i*)(in + 16 * i)));
    s1 = _mm_xor_si128(s1, _mm_loadu_si128((const __m128i*)(in + 16 * i + 16)));
    s2 = _mm_xor_si128(s2, _mm_loadu_si128((const __m128i*)(in + 16 * i + 32)));
    s3 = _mm_xor_si128(s3, _mm_loadu_si128((const __m128i*)(in + 16 * i + 48)));
    _mm_storeu_si128((__m128i*)(out + 16 * i), s0);
    _mm_storeu_si128((__m128i*)(out + 16 * i + 16), s1);
    _mm_storeu_si128((__m128i*)(out + 16 * i + 32), s2);
    _mm_storeu_si128((__m128i*)(out + 16 * i + 48), s3);
  }
  for (; i < nblocks; i++) {
    __m128i s = enc1(_mm_loadu_si128((const __m128i*)ctr), rk);
    tvc_ctr_inc(ctr);
    s = _mm_xor_si128(s, _mm_loadu_si128((const __m128i*)(in + 16 * i)));
    _mm_storeu_si128((__m128i*)(out + 16 * i), s);
  }
}

#else
typedef int tvc_aes_x86_unused;
#endif /* TVC_HAVE_X86AES */
