/*
 * Portable AES-256 (FIPS-197), 32-bit T-table implementation in C99.
 * Tables are generated once by tvc_p_aes_tables_init() (called from the
 * one-time init in tvc_dispatch.c). Unaligned access only through memcpy.
 */
#include <string.h>

#include "tv_crypto.h"

static uint8_t S[256];
static uint8_t IS[256];
static uint32_t Te0[256], Te1[256], Te2[256], Te3[256];
static uint32_t Td0[256], Td1[256], Td2[256], Td3[256];

static uint8_t gmul(uint8_t a, uint8_t b) {
  uint8_t p = 0;
  int i;
  for (i = 0; i < 8; i++) {
    if (b & 1) p ^= a;
    b >>= 1;
    a = (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1B : 0x00));
  }
  return p;
}

static uint8_t rotl8(uint8_t x, int n) {
  return (uint8_t)((x << n) | (x >> (8 - n)));
}

static uint32_t ror32_8(uint32_t x) { return (x >> 8) | (x << 24); }

void tvc_p_aes_tables_init(void) {
  int a, b;
  for (a = 0; a < 256; a++) {
    uint8_t inv = 0;
    uint8_t s;
    if (a != 0) {
      for (b = 1; b < 256; b++) {
        if (gmul((uint8_t)a, (uint8_t)b) == 1) {
          inv = (uint8_t)b;
          break;
        }
      }
    }
    s = (uint8_t)(inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^
                  rotl8(inv, 4) ^ 0x63);
    S[a] = s;
    IS[s] = (uint8_t)a;
  }
  for (a = 0; a < 256; a++) {
    uint8_t s = S[a];
    uint8_t is = IS[a];
    uint32_t te = ((uint32_t)gmul(s, 2) << 24) | ((uint32_t)s << 16) |
                  ((uint32_t)s << 8) | (uint32_t)gmul(s, 3);
    uint32_t td = ((uint32_t)gmul(is, 14) << 24) |
                  ((uint32_t)gmul(is, 9) << 16) |
                  ((uint32_t)gmul(is, 13) << 8) | (uint32_t)gmul(is, 11);
    Te0[a] = te;
    Te1[a] = ror32_8(te);
    Te2[a] = ror32_8(Te1[a]);
    Te3[a] = ror32_8(Te2[a]);
    Td0[a] = td;
    Td1[a] = ror32_8(td);
    Td2[a] = ror32_8(Td1[a]);
    Td3[a] = ror32_8(Td2[a]);
  }
}

static TVC_INLINE uint32_t load_be32(const uint8_t* p) {
  uint8_t b[4];
  memcpy(b, p, 4);
  return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
         ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

static TVC_INLINE void store_be32(uint8_t* p, uint32_t v) {
  uint8_t b[4];
  b[0] = (uint8_t)(v >> 24);
  b[1] = (uint8_t)(v >> 16);
  b[2] = (uint8_t)(v >> 8);
  b[3] = (uint8_t)v;
  memcpy(p, b, 4);
}

static uint32_t sub_word(uint32_t w) {
  return ((uint32_t)S[w >> 24] << 24) | ((uint32_t)S[(w >> 16) & 0xff] << 16) |
         ((uint32_t)S[(w >> 8) & 0xff] << 8) | (uint32_t)S[w & 0xff];
}

static uint32_t inv_mix_word(uint32_t w) {
  return Td0[S[w >> 24]] ^ Td1[S[(w >> 16) & 0xff]] ^
         Td2[S[(w >> 8) & 0xff]] ^ Td3[S[w & 0xff]];
}

void tvc_p_aes256_expand(tvc_aes256_key* k, const uint8_t key32[32]) {
  static const uint32_t rcon[8] = {0x01000000u, 0x02000000u, 0x04000000u,
                                   0x08000000u, 0x10000000u, 0x20000000u,
                                   0x40000000u, 0x80000000u};
  uint32_t* w = k->ek;
  int i, r, c;
  for (i = 0; i < 8; i++) w[i] = load_be32(key32 + 4 * i);
  for (i = 8; i < 60; i++) {
    uint32_t t = w[i - 1];
    if (i % 8 == 0) {
      t = sub_word((t << 8) | (t >> 24)) ^ rcon[i / 8 - 1];
    } else if (i % 8 == 4) {
      t = sub_word(t);
    }
    w[i] = w[i - 8] ^ t;
  }
  /* Equivalent inverse cipher schedule. */
  for (c = 0; c < 4; c++) {
    k->dk[c] = w[56 + c];
    k->dk[56 + c] = w[c];
  }
  for (r = 1; r < 14; r++) {
    for (c = 0; c < 4; c++) k->dk[4 * r + c] = inv_mix_word(w[4 * (14 - r) + c]);
  }
  for (i = 0; i < 60; i++) {
    store_be32(k->ekb + 4 * i, k->ek[i]);
    store_be32(k->dkb + 4 * i, k->dk[i]);
  }
}

static TVC_INLINE void enc_words(const uint32_t* rk, uint32_t s[4]) {
  uint32_t s0 = s[0] ^ rk[0], s1 = s[1] ^ rk[1], s2 = s[2] ^ rk[2],
           s3 = s[3] ^ rk[3];
  uint32_t t0, t1, t2, t3;
  int r;
  for (r = 1; r < 14; r++) {
    const uint32_t* k = rk + 4 * r;
    t0 = Te0[s0 >> 24] ^ Te1[(s1 >> 16) & 0xff] ^ Te2[(s2 >> 8) & 0xff] ^
         Te3[s3 & 0xff] ^ k[0];
    t1 = Te0[s1 >> 24] ^ Te1[(s2 >> 16) & 0xff] ^ Te2[(s3 >> 8) & 0xff] ^
         Te3[s0 & 0xff] ^ k[1];
    t2 = Te0[s2 >> 24] ^ Te1[(s3 >> 16) & 0xff] ^ Te2[(s0 >> 8) & 0xff] ^
         Te3[s1 & 0xff] ^ k[2];
    t3 = Te0[s3 >> 24] ^ Te1[(s0 >> 16) & 0xff] ^ Te2[(s1 >> 8) & 0xff] ^
         Te3[s2 & 0xff] ^ k[3];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;
  }
  rk += 56;
  s[0] = (((uint32_t)S[s0 >> 24] << 24) | ((uint32_t)S[(s1 >> 16) & 0xff] << 16) |
          ((uint32_t)S[(s2 >> 8) & 0xff] << 8) | (uint32_t)S[s3 & 0xff]) ^
         rk[0];
  s[1] = (((uint32_t)S[s1 >> 24] << 24) | ((uint32_t)S[(s2 >> 16) & 0xff] << 16) |
          ((uint32_t)S[(s3 >> 8) & 0xff] << 8) | (uint32_t)S[s0 & 0xff]) ^
         rk[1];
  s[2] = (((uint32_t)S[s2 >> 24] << 24) | ((uint32_t)S[(s3 >> 16) & 0xff] << 16) |
          ((uint32_t)S[(s0 >> 8) & 0xff] << 8) | (uint32_t)S[s1 & 0xff]) ^
         rk[2];
  s[3] = (((uint32_t)S[s3 >> 24] << 24) | ((uint32_t)S[(s0 >> 16) & 0xff] << 16) |
          ((uint32_t)S[(s1 >> 8) & 0xff] << 8) | (uint32_t)S[s2 & 0xff]) ^
         rk[3];
}

static TVC_INLINE void dec_words(const uint32_t* rk, uint32_t s[4]) {
  uint32_t s0 = s[0] ^ rk[0], s1 = s[1] ^ rk[1], s2 = s[2] ^ rk[2],
           s3 = s[3] ^ rk[3];
  uint32_t t0, t1, t2, t3;
  int r;
  for (r = 1; r < 14; r++) {
    const uint32_t* k = rk + 4 * r;
    t0 = Td0[s0 >> 24] ^ Td1[(s3 >> 16) & 0xff] ^ Td2[(s2 >> 8) & 0xff] ^
         Td3[s1 & 0xff] ^ k[0];
    t1 = Td0[s1 >> 24] ^ Td1[(s0 >> 16) & 0xff] ^ Td2[(s3 >> 8) & 0xff] ^
         Td3[s2 & 0xff] ^ k[1];
    t2 = Td0[s2 >> 24] ^ Td1[(s1 >> 16) & 0xff] ^ Td2[(s0 >> 8) & 0xff] ^
         Td3[s3 & 0xff] ^ k[2];
    t3 = Td0[s3 >> 24] ^ Td1[(s2 >> 16) & 0xff] ^ Td2[(s1 >> 8) & 0xff] ^
         Td3[s0 & 0xff] ^ k[3];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;
  }
  rk += 56;
  s[0] = (((uint32_t)IS[s0 >> 24] << 24) | ((uint32_t)IS[(s3 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s2 >> 8) & 0xff] << 8) | (uint32_t)IS[s1 & 0xff]) ^
         rk[0];
  s[1] = (((uint32_t)IS[s1 >> 24] << 24) | ((uint32_t)IS[(s0 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s3 >> 8) & 0xff] << 8) | (uint32_t)IS[s2 & 0xff]) ^
         rk[1];
  s[2] = (((uint32_t)IS[s2 >> 24] << 24) | ((uint32_t)IS[(s1 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s0 >> 8) & 0xff] << 8) | (uint32_t)IS[s3 & 0xff]) ^
         rk[2];
  s[3] = (((uint32_t)IS[s3 >> 24] << 24) | ((uint32_t)IS[(s2 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s1 >> 8) & 0xff] << 8) | (uint32_t)IS[s0 & 0xff]) ^
         rk[3];
}

static TVC_INLINE void load_block(const uint8_t* p, uint32_t s[4]) {
  s[0] = load_be32(p);
  s[1] = load_be32(p + 4);
  s[2] = load_be32(p + 8);
  s[3] = load_be32(p + 12);
}

static TVC_INLINE void store_block(uint8_t* p, const uint32_t s[4]) {
  store_be32(p, s[0]);
  store_be32(p + 4, s[1]);
  store_be32(p + 8, s[2]);
  store_be32(p + 12, s[3]);
}

void tvc_p_aes_enc_block(const tvc_aes256_key* k, const uint8_t in[16],
                         uint8_t out[16]) {
  uint32_t s[4];
  load_block(in, s);
  enc_words(k->ek, s);
  store_block(out, s);
}

void tvc_p_aes_dec_block(const tvc_aes256_key* k, const uint8_t in[16],
                         uint8_t out[16]) {
  uint32_t s[4];
  load_block(in, s);
  dec_words(k->dk, s);
  store_block(out, s);
}

void tvc_p_aes_ige(int encrypt, const tvc_aes256_key* k, const uint8_t iv32[32],
                   const uint8_t* in, uint8_t* out, size_t nblocks) {
  /* x = previous ciphertext (c_prev), y = previous plaintext (p_prev). */
  uint32_t x[4], y[4], cur[4], t[4];
  size_t i;
  int j;
  load_block(iv32, x);
  load_block(iv32 + 16, y);
  if (encrypt) {
    for (i = 0; i < nblocks; i++) {
      load_block(in + 16 * i, cur); /* P */
      for (j = 0; j < 4; j++) t[j] = cur[j] ^ x[j];
      enc_words(k->ek, t);
      for (j = 0; j < 4; j++) t[j] ^= y[j]; /* C */
      store_block(out + 16 * i, t);
      for (j = 0; j < 4; j++) {
        x[j] = t[j];
        y[j] = cur[j];
      }
    }
  } else {
    for (i = 0; i < nblocks; i++) {
      load_block(in + 16 * i, cur); /* C */
      for (j = 0; j < 4; j++) t[j] = cur[j] ^ y[j];
      dec_words(k->dk, t);
      for (j = 0; j < 4; j++) t[j] ^= x[j]; /* P */
      store_block(out + 16 * i, t);
      for (j = 0; j < 4; j++) {
        x[j] = cur[j];
        y[j] = t[j];
      }
    }
  }
}

void tvc_p_aes_ctr(const tvc_aes256_key* k, uint8_t ctr[16], const uint8_t* in,
                   uint8_t* out, size_t nblocks) {
  uint32_t s[4], d[4];
  size_t i;
  int j;
  for (i = 0; i < nblocks; i++) {
    load_block(ctr, s);
    enc_words(k->ek, s);
    load_block(in + 16 * i, d);
    for (j = 0; j < 4; j++) d[j] ^= s[j];
    store_block(out + 16 * i, d);
    tvc_ctr_inc(ctr);
  }
}
