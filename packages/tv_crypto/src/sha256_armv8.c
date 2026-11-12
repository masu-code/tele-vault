/*
 * SHA-256 compression with ARMv8 Crypto Extensions (AArch64), ACLE
 * intrinsics. Compiled only when TVC_HAVE_ARMV8. Selected at runtime only
 * if getauxval(AT_HWCAP) has HWCAP_SHA2 and the init self-test matches the
 * portable implementation.
 */
#include "tv_crypto.h"

#if TVC_HAVE_ARMV8

#include <arm_neon.h>
#include <sys/auxv.h>

#ifndef AT_HWCAP
#define AT_HWCAP 16
#endif
#ifndef HWCAP_SHA2
#define HWCAP_SHA2 (1UL << 6)
#endif

#if defined(__clang__)
#define TVC_TARGET_ARM_SHA2 __attribute__((target("sha2")))
#else
#define TVC_TARGET_ARM_SHA2 __attribute__((target("+crypto")))
#endif

int tvc_armv8_sha2_avail(void) {
  return (getauxval(AT_HWCAP) & HWCAP_SHA2) != 0;
}

/* st[0..3] = a,b,c,d ; st[4..7] = e,f,g,h (SHA256H/SHA256H2 layout). */
TVC_TARGET_ARM_SHA2 void tvc_armv8_sha256_blocks(uint32_t st[8],
                                                 const uint8_t* data,
                                                 size_t nblocks) {
  uint32x4_t abcd = vld1q_u32(st);
  uint32x4_t efgh = vld1q_u32(st + 4);
  size_t n;
  int i;
  for (n = 0; n < nblocks; n++) {
    const uint8_t* p = data + 64 * n;
    uint32x4_t abcd_save = abcd, efgh_save = efgh;
    uint32x4_t w[4];
    w[0] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(p)));
    w[1] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(p + 16)));
    w[2] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(p + 32)));
    w[3] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(p + 48)));
    for (i = 0; i < 16; i++) {
      /* Rounds 4i..4i+3 use W[4i..4i+3] = w[i & 3]. */
      uint32x4_t wk = vaddq_u32(w[i & 3], vld1q_u32(tvc_sha256_k + 4 * i));
      uint32x4_t abcd_old = abcd;
      abcd = vsha256hq_u32(abcd, efgh, wk);
      efgh = vsha256h2q_u32(efgh, abcd_old, wk);
      if (i < 12) {
        /* W[4i+16..4i+19] from W[4i..], W[4i+4..], W[4i+8..], W[4i+12..]. */
        w[i & 3] = vsha256su1q_u32(vsha256su0q_u32(w[i & 3], w[(i + 1) & 3]),
                                   w[(i + 2) & 3], w[(i + 3) & 3]);
      }
    }
    abcd = vaddq_u32(abcd, abcd_save);
    efgh = vaddq_u32(efgh, efgh_save);
  }
  vst1q_u32(st, abcd);
  vst1q_u32(st + 4, efgh);
}

#else
typedef int tvc_sha256_armv8_unused;
#endif /* TVC_HAVE_ARMV8 */
