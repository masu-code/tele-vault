/*
 * Public entry points, one-time init + self-test, runtime dispatch between
 * the portable and the accelerated implementations, SHA-256 padding.
 */
#include <string.h>

#include "tv_crypto.h"

/* ------------------------------------------------------------------------ */
/* Atomics: C11 on clang/gcc, Interlocked on MSVC.                           */
/* ------------------------------------------------------------------------ */
#if defined(_MSC_VER)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static volatile LONG g_state; /* 0 = not started, 1 = running, 2 = done */
static volatile LONG g_force_portable;
static int state_load(void) {
  return (int)InterlockedCompareExchange(&g_state, 0, 0);
}
static int state_claim(void) {
  return InterlockedCompareExchange(&g_state, 1, 0) == 0;
}
static void state_done(void) { InterlockedExchange(&g_state, 2); }
static void cpu_yield(void) { SwitchToThread(); }
static int force_load(void) { return (int)g_force_portable; }
static void force_store(int v) { InterlockedExchange(&g_force_portable, v); }
#else
#include <sched.h>
#include <stdatomic.h>
static atomic_int g_state;
static atomic_int g_force_portable;
static int state_load(void) {
  return atomic_load_explicit(&g_state, memory_order_acquire);
}
static int state_claim(void) {
  int expected = 0;
  return atomic_compare_exchange_strong_explicit(
      &g_state, &expected, 1, memory_order_acq_rel, memory_order_acquire);
}
static void state_done(void) {
  atomic_store_explicit(&g_state, 2, memory_order_release);
}
static void cpu_yield(void) { sched_yield(); }
static int force_load(void) {
  return atomic_load_explicit(&g_force_portable, memory_order_relaxed);
}
static void force_store(int v) {
  atomic_store_explicit(&g_force_portable, v, memory_order_relaxed);
}
#endif

/* Written once during init, published by state_done(). */
#define ACCEL_NONE 0
#define ACCEL_ARMV8 1
#define ACCEL_X86 2
static int g_aes_accel = ACCEL_NONE;
static int g_sha_accel = ACCEL_NONE;
static uint32_t g_info_static = 0; /* avail + failure bits */

#define CTR_MAGIC 0x54564343u /* "TVCC" */

static void secure_zero(void* p, size_t n) {
  volatile uint8_t* v = (volatile uint8_t*)p;
  while (n--) *v++ = 0;
}

/* ------------------------------------------------------------------------ */
/* SHA-256 streaming over a block function.                                  */
/* ------------------------------------------------------------------------ */
typedef void (*sha_blocks_fn)(uint32_t st[8], const uint8_t* data,
                              size_t nblocks);

typedef struct {
  uint32_t st[8];
  uint8_t buf[64];
  size_t buflen;
  uint64_t total;
  sha_blocks_fn blocks;
} sha_ctx;

static void sha_init(sha_ctx* c, sha_blocks_fn fn) {
  static const uint32_t iv[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u,
                                 0xa54ff53au, 0x510e527fu, 0x9b05688cu,
                                 0x1f83d9abu, 0x5be0cd19u};
  memcpy(c->st, iv, sizeof(iv));
  c->buflen = 0;
  c->total = 0;
  c->blocks = fn;
}

static void sha_update(sha_ctx* c, const uint8_t* p, size_t n) {
  size_t nb;
  c->total += n;
  if (c->buflen > 0) {
    size_t take = 64 - c->buflen;
    if (take > n) take = n;
    memcpy(c->buf + c->buflen, p, take);
    c->buflen += take;
    p += take;
    n -= take;
    if (c->buflen < 64) return;
    c->blocks(c->st, c->buf, 1);
    c->buflen = 0;
  }
  nb = n / 64;
  if (nb > 0) {
    c->blocks(c->st, p, nb);
    p += 64 * nb;
    n -= 64 * nb;
  }
  if (n > 0) {
    memcpy(c->buf, p, n);
    c->buflen = n;
  }
}

static void sha_final(sha_ctx* c, uint8_t out[32]) {
  uint64_t bits = c->total * 8u;
  int i;
  c->buf[c->buflen++] = 0x80;
  if (c->buflen > 56) {
    memset(c->buf + c->buflen, 0, 64 - c->buflen);
    c->blocks(c->st, c->buf, 1);
    c->buflen = 0;
  }
  memset(c->buf + c->buflen, 0, 56 - c->buflen);
  for (i = 0; i < 8; i++) c->buf[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
  c->blocks(c->st, c->buf, 1);
  for (i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(c->st[i] >> 24);
    out[4 * i + 1] = (uint8_t)(c->st[i] >> 16);
    out[4 * i + 2] = (uint8_t)(c->st[i] >> 8);
    out[4 * i + 3] = (uint8_t)c->st[i];
  }
  secure_zero(c, sizeof(*c));
}

static void sha_two(sha_blocks_fn fn, const uint8_t* a, size_t alen,
                    const uint8_t* b, size_t blen, uint8_t out[32]) {
  sha_ctx c;
  sha_init(&c, fn);
  if (alen > 0) sha_update(&c, a, alen);
  if (blen > 0) sha_update(&c, b, blen);
  sha_final(&c, out);
}

/* ------------------------------------------------------------------------ */
/* Implementation selection.                                                 */
/* ------------------------------------------------------------------------ */
typedef void (*ige_fn)(int, const tvc_aes256_key*, const uint8_t*,
                       const uint8_t*, uint8_t*, size_t);
typedef void (*ctr_fn)(const tvc_aes256_key*, uint8_t*, const uint8_t*,
                       uint8_t*, size_t);

static ige_fn ige_for(int accel) {
#if TVC_HAVE_ARMV8
  if (accel == ACCEL_ARMV8) return tvc_armv8_aes_ige;
#endif
#if TVC_HAVE_X86AES
  if (accel == ACCEL_X86) return tvc_x86_aes_ige;
#endif
  (void)accel;
  return tvc_p_aes_ige;
}

static ctr_fn ctr_for(int accel) {
#if TVC_HAVE_ARMV8
  if (accel == ACCEL_ARMV8) return tvc_armv8_aes_ctr;
#endif
#if TVC_HAVE_X86AES
  if (accel == ACCEL_X86) return tvc_x86_aes_ctr;
#endif
  (void)accel;
  return tvc_p_aes_ctr;
}

static sha_blocks_fn sha_for(int accel) {
#if TVC_HAVE_ARMV8
  if (accel == ACCEL_ARMV8) return tvc_armv8_sha256_blocks;
#endif
  (void)accel;
  return tvc_p_sha256_blocks;
}

/* ------------------------------------------------------------------------ */
/* Self-test.                                                                */
/* ------------------------------------------------------------------------ */
static const uint8_t kFipsKey[32] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
    0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
    0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f};
static const uint8_t kFipsPt[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
                                    0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
                                    0xcc, 0xdd, 0xee, 0xff};
static const uint8_t kFipsCt[16] = {0x8e, 0xa2, 0xb7, 0xca, 0x51, 0x67,
                                    0x45, 0xbf, 0xea, 0xfc, 0x49, 0x90,
                                    0x4b, 0x49, 0x60, 0x89};
static const uint8_t kShaAbc[32] = {
    0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
    0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
    0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
/* SHA-256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") */
static const uint8_t kSha448[32] = {
    0x24, 0x8d, 0x6a, 0x61, 0xd2, 0x06, 0x38, 0xb8, 0xe5, 0xc0, 0x26,
    0x93, 0x0c, 0x3e, 0x60, 0x39, 0xa3, 0x3c, 0xe4, 0x59, 0x64, 0xff,
    0x21, 0x67, 0xf6, 0xec, 0xed, 0xd4, 0x19, 0xdb, 0x06, 0xc1};

#define ST_LEN 320 /* 20 AES blocks, 5 SHA blocks */

static void fill_pattern(uint8_t* p, size_t n, uint32_t seed) {
  size_t i;
  uint32_t x = seed;
  for (i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    p[i] = (uint8_t)(x >> 24);
  }
}

static int portable_kat_ok(void) {
  tvc_aes256_key k;
  uint8_t out[32];
  static const char* m448 =
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  int ok = 1;
  tvc_p_aes256_expand(&k, kFipsKey);
  tvc_p_aes_enc_block(&k, kFipsPt, out);
  if (memcmp(out, kFipsCt, 16) != 0) ok = 0;
  tvc_p_aes_dec_block(&k, kFipsCt, out);
  if (memcmp(out, kFipsPt, 16) != 0) ok = 0;
  sha_two(tvc_p_sha256_blocks, (const uint8_t*)"abc", 3, NULL, 0, out);
  if (memcmp(out, kShaAbc, 32) != 0) ok = 0;
  sha_two(tvc_p_sha256_blocks, (const uint8_t*)m448, 20, (const uint8_t*)m448 + 20,
          36, out);
  if (memcmp(out, kSha448, 32) != 0) ok = 0;
  secure_zero(&k, sizeof(k));
  return ok;
}

/* Accelerated AES vs portable: IGE enc/dec (incl. FIPS block through a zero
 * IV, where IGE == ECB for the first block) and CTR across a counter wrap. */
static int aes_accel_matches(int accel) {
  tvc_aes256_key k;
  uint8_t key[32], iv[32], pt[ST_LEN], a[ST_LEN], b[ST_LEN];
  uint8_t ca[16], cb[16];
  ige_fn ige = ige_for(accel);
  ctr_fn ctr = ctr_for(accel);
  int ok = 1;

  memset(iv, 0, sizeof(iv));
  tvc_p_aes256_expand(&k, kFipsKey);
  ige(1, &k, iv, kFipsPt, a, 1);
  if (memcmp(a, kFipsCt, 16) != 0) ok = 0;
  ige(0, &k, iv, kFipsCt, a, 1);
  if (memcmp(a, kFipsPt, 16) != 0) ok = 0;

  fill_pattern(key, sizeof(key), 0x1234567u);
  fill_pattern(iv, sizeof(iv), 0x89abcdeu);
  fill_pattern(pt, sizeof(pt), 0x2468aceu);
  tvc_p_aes256_expand(&k, key);
  tvc_p_aes_ige(1, &k, iv, pt, a, ST_LEN / 16);
  ige(1, &k, iv, pt, b, ST_LEN / 16);
  if (memcmp(a, b, ST_LEN) != 0) ok = 0;
  tvc_p_aes_ige(0, &k, iv, pt, a, ST_LEN / 16);
  ige(0, &k, iv, pt, b, ST_LEN / 16);
  if (memcmp(a, b, ST_LEN) != 0) ok = 0;

  memset(ca, 0xff, 16);
  ca[15] = 0xfd; /* wraps to zero after 3 blocks */
  memcpy(cb, ca, 16);
  tvc_p_aes_ctr(&k, ca, pt, a, 7);
  ctr(&k, cb, pt, b, 7);
  if (memcmp(a, b, 7 * 16) != 0 || memcmp(ca, cb, 16) != 0) ok = 0;
  secure_zero(&k, sizeof(k));
  return ok;
}

static int sha_accel_matches(int accel) {
  uint8_t data[ST_LEN], a[32], b[32];
  sha_blocks_fn fn = sha_for(accel);
  size_t lens[6] = {0, 3, 55, 64, 119, ST_LEN};
  int i, ok = 1;
  fill_pattern(data, sizeof(data), 0x13579bdu);
  for (i = 0; i < 6; i++) {
    sha_two(tvc_p_sha256_blocks, data, lens[i], NULL, 0, a);
    sha_two(fn, data, lens[i], NULL, 0, b);
    if (memcmp(a, b, 32) != 0) ok = 0;
  }
  sha_two(fn, (const uint8_t*)"abc", 3, NULL, 0, b);
  if (memcmp(b, kShaAbc, 32) != 0) ok = 0;
  return ok;
}

static void do_init(void) {
  uint32_t info = 0;
  int aes = ACCEL_NONE, sha = ACCEL_NONE;
  tvc_p_aes_tables_init();
  if (!portable_kat_ok()) {
    g_info_static = TVC_INFO_SELF_TEST_FAILED | TVC_INFO_PORTABLE_FAILED;
    return;
  }
#if TVC_HAVE_ARMV8
  if (tvc_armv8_aes_avail()) {
    info |= TVC_INFO_AES_ACCEL_AVAIL;
    aes = ACCEL_ARMV8;
  }
  if (tvc_armv8_sha2_avail()) {
    info |= TVC_INFO_SHA_ACCEL_AVAIL;
    sha = ACCEL_ARMV8;
  }
#endif
#if TVC_HAVE_X86AES
  if (tvc_x86_aes_avail()) {
    info |= TVC_INFO_AES_ACCEL_AVAIL;
    aes = ACCEL_X86;
  }
#endif
  if (aes != ACCEL_NONE && !aes_accel_matches(aes)) {
    aes = ACCEL_NONE;
    info |= TVC_INFO_SELF_TEST_FAILED;
  }
  if (sha != ACCEL_NONE && !sha_accel_matches(sha)) {
    sha = ACCEL_NONE;
    info |= TVC_INFO_SELF_TEST_FAILED;
  }
  g_aes_accel = aes;
  g_sha_accel = sha;
  g_info_static = info;
}

static void ensure_init(void) {
  if (state_load() == 2) return;
  if (state_claim()) {
    do_init();
    state_done();
    return;
  }
  while (state_load() != 2) cpu_yield();
}

static int aes_impl(void) { return force_load() ? ACCEL_NONE : g_aes_accel; }
static int sha_impl(void) { return force_load() ? ACCEL_NONE : g_sha_accel; }

/* ------------------------------------------------------------------------ */
/* Public API.                                                               */
/* ------------------------------------------------------------------------ */
TVC_API uint32_t tvc_version(void) { return TVC_VERSION; }

TVC_API uint32_t tvc_info(void) {
  uint32_t info;
  ensure_init();
  info = g_info_static;
  if (aes_impl() != ACCEL_NONE) info |= TVC_INFO_AES_ACCEL_ACTIVE;
  if (sha_impl() != ACCEL_NONE) info |= TVC_INFO_SHA_ACCEL_ACTIVE;
  return info;
}

TVC_API void tvc_force_portable(int32_t on) {
  ensure_init();
  force_store(on ? 1 : 0);
}

TVC_API int32_t tvc_aes256_ige(int32_t encrypt, const uint8_t* key32,
                               const uint8_t* iv32, const uint8_t* in,
                               uint8_t* out, size_t len) {
  tvc_aes256_key k;
  if (key32 == NULL || iv32 == NULL || (len % 16) != 0) return -1;
  if (len > 0 && (in == NULL || out == NULL)) return -1;
  ensure_init();
  if (len == 0) return 0;
  tvc_p_aes256_expand(&k, key32);
  ige_for(aes_impl())(encrypt ? 1 : 0, &k, iv32, in, out, len / 16);
  secure_zero(&k, sizeof(k));
  return 0;
}

TVC_API size_t tvc_aes256_ctr_ctx_size(void) { return sizeof(tvc_ctr_ctx); }

TVC_API int32_t tvc_aes256_ctr_init(void* ctx, const uint8_t* key32,
                                    const uint8_t* iv16) {
  tvc_ctr_ctx* c = (tvc_ctr_ctx*)ctx;
  if (c == NULL || key32 == NULL || iv16 == NULL) return -1;
  ensure_init();
  tvc_p_aes256_expand(&c->key, key32);
  memcpy(c->ctr, iv16, 16);
  memset(c->ks, 0, 16);
  c->ks_used = 16;
  c->magic = CTR_MAGIC;
  return 0;
}

TVC_API void tvc_aes256_ctr_xor(void* ctx, const uint8_t* in, uint8_t* out,
                                size_t len) {
  static const uint8_t zero[16] = {0};
  tvc_ctr_ctx* c = (tvc_ctr_ctx*)ctx;
  size_t nb;
  ctr_fn fn;
  if (c == NULL || in == NULL || out == NULL || len == 0) return;
  if (c->magic != CTR_MAGIC || c->ks_used > 16) return;
  ensure_init();
  while (len > 0 && c->ks_used < 16) {
    *out++ = (uint8_t)(*in++ ^ c->ks[c->ks_used++]);
    len--;
  }
  if (len == 0) return;
  fn = ctr_for(aes_impl());
  nb = len / 16;
  if (nb > 0) {
    fn(&c->key, c->ctr, in, out, nb);
    in += 16 * nb;
    out += 16 * nb;
    len -= 16 * nb;
  }
  if (len > 0) {
    size_t i;
    fn(&c->key, c->ctr, zero, c->ks, 1);
    for (i = 0; i < len; i++) out[i] = (uint8_t)(in[i] ^ c->ks[i]);
    c->ks_used = (uint32_t)len;
  }
}

TVC_API void tvc_sha256(const uint8_t* in, size_t len, uint8_t* out32) {
  if (out32 == NULL || (in == NULL && len > 0)) return;
  ensure_init();
  sha_two(sha_for(sha_impl()), in, len, NULL, 0, out32);
}

TVC_API void tvc_sha256_2(const uint8_t* a, size_t alen, const uint8_t* b,
                          size_t blen, uint8_t* out32) {
  if (out32 == NULL || (a == NULL && alen > 0) || (b == NULL && blen > 0)) {
    return;
  }
  ensure_init();
  sha_two(sha_for(sha_impl()), a, alen, b, blen, out32);
}
