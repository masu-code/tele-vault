/*
 * AES-256 with ARMv8 Crypto Extensions (AArch64), ACLE intrinsics.
 * Compiled only when TVC_HAVE_ARMV8 (aarch64 Android/Linux, clang or gcc).
 * Selected at runtime only if getauxval(AT_HWCAP) has HWCAP_AES and the
 * init self-test matches the portable implementation.
 */
#include "tv_crypto.h"

#if TVC_HAVE_ARMV8

#include <arm_neon.h>
#include <string.h>
#include <sys/auxv.h>

#ifndef AT_HWCAP
#define AT_HWCAP 16
#endif
#ifndef HWCAP_AES
#define HWCAP_AES (1UL << 3)
#endif

#if defined(__clang__)
#define TVC_TARGET_ARM_AES __attribute__((target("aes")))
#else
#define TVC_TARGET_ARM_AES __attribute__((target("+crypto")))
#endif

int tvc_armv8_aes_avail(void) {
  return (getauxval(AT_HWCAP) & HWCAP_AES) != 0;
}

TVC_TARGET_ARM_AES static void load_keys(const uint8_t* b, uint8x16_t rk[15]) {
  int i;
  for (i = 0; i < 15; i++) rk[i] = vld1q_u8(b + 16 * i);
}

/* AESE(s,k) = SubBytes(ShiftRows(s ^ k)); AESMC = MixColumns. */
TVC_TARGET_ARM_AES static uint8x16_t enc1(uint8x16_t s,
                                          const uint8x16_t rk[15]) {
  int r;
  for (r = 0; r < 13; r++) s = vaesmcq_u8(vaeseq_u8(s, rk[r]));
  s = vaeseq_u8(s, rk[13]);
  return veorq_u8(s, rk[14]);
}

/* AESD(s,k) = InvSubBytes(InvShiftRows(s ^ k)); AESIMC = InvMixColumns.
 * dk is the equivalent inverse cipher schedule (dk[0] = rk14,
 * dk[i] = InvMixColumns(rk[14-i]), dk[14] = rk0). */
TVC_TARGET_ARM_AES static uint8x16_t dec1(uint8x16_t s,
                                          const uint8x16_t dk[15]) {
  int r;
  for (r = 0; r < 13; r++) s = vaesimcq_u8(vaesdq_u8(s, dk[r]));
  s = vaesdq_u8(s, dk[13]);
  return veorq_u8(s, dk[14]);
}

TVC_TARGET_ARM_AES void tvc_armv8_aes_ige(int encrypt, const tvc_aes256_key* k,
                                          const uint8_t iv32[32],
                                          const uint8_t* in, uint8_t* out,
                                          size_t nblocks) {
  uint8x16_t rk[15];
  uint8x16_t x = vld1q_u8(iv32);      /* c_prev */
  uint8x16_t y = vld1q_u8(iv32 + 16); /* p_prev */
  size_t i;
  if (encrypt) {
    load_keys(k->ekb, rk);
    for (i = 0; i < nblocks; i++) {
      uint8x16_t p = vld1q_u8(in + 16 * i);
      uint8x16_t c = veorq_u8(enc1(veorq_u8(p, x), rk), y);
      vst1q_u8(out + 16 * i, c);
      x = c;
      y = p;
    }
  } else {
    load_keys(k->dkb, rk);
    for (i = 0; i < nblocks; i++) {
      uint8x16_t c = vld1q_u8(in + 16 * i);
      uint8x16_t p = veorq_u8(dec1(veorq_u8(c, y), rk), x);
      vst1q_u8(out + 16 * i, p);
      x = c;
      y = p;
    }
  }
}

TVC_TARGET_ARM_AES void tvc_armv8_aes_ctr(const tvc_aes256_key* k,
                                          uint8_t ctr[16], const uint8_t* in,
                                          uint8_t* out, size_t nblocks) {
  uint8x16_t rk[15];
  uint8_t cb[64];
  size_t i = 0;
  int r, j;
  load_keys(k->ekb, rk);
  for (; i + 4 <= nblocks; i += 4) {
    uint8x16_t s0, s1, s2, s3;
    for (j = 0; j < 4; j++) {
      memcpy(cb + 16 * j, ctr, 16);
      tvc_ctr_inc(ctr);
    }
    s0 = vld1q_u8(cb);
    s1 = vld1q_u8(cb + 16);
    s2 = vld1q_u8(cb + 32);
    s3 = vld1q_u8(cb + 48);
    for (r = 0; r < 13; r++) {
      s0 = vaesmcq_u8(vaeseq_u8(s0, rk[r]));
      s1 = vaesmcq_u8(vaeseq_u8(s1, rk[r]));
      s2 = vaesmcq_u8(vaeseq_u8(s2, rk[r]));
      s3 = vaesmcq_u8(vaeseq_u8(s3, rk[r]));
    }
    s0 = veorq_u8(vaeseq_u8(s0, rk[13]), rk[14]);
    s1 = veorq_u8(vaeseq_u8(s1, rk[13]), rk[14]);
    s2 = veorq_u8(vaeseq_u8(s2, rk[13]), rk[14]);
    s3 = veorq_u8(vaeseq_u8(s3, rk[13]), rk[14]);
    vst1q_u8(out + 16 * i, veorq_u8(s0, vld1q_u8(in + 16 * i)));
    vst1q_u8(out + 16 * i + 16, veorq_u8(s1, vld1q_u8(in + 16 * i + 16)));
    vst1q_u8(out + 16 * i + 32, veorq_u8(s2, vld1q_u8(in + 16 * i + 32)));
    vst1q_u8(out + 16 * i + 48, veorq_u8(s3, vld1q_u8(in + 16 * i + 48)));
  }
  for (; i < nblocks; i++) {
    uint8x16_t s = enc1(vld1q_u8(ctr), rk);
    tvc_ctr_inc(ctr);
    vst1q_u8(out + 16 * i, veorq_u8(s, vld1q_u8(in + 16 * i)));
  }
}

#else
typedef int tvc_aes_armv8_unused;
#endif /* TVC_HAVE_ARMV8 */
