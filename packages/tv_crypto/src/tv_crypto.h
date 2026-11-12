/*
 * tv_crypto: AES-256 (IGE, CTR) and SHA-256 for TeleVault (MTProto).
 *
 * Public C API (exported) plus the internal interface shared by the
 * implementation files. All public functions are reentrant; the only global
 * state is the one-time initialisation (tables + self-test) and the
 * force-portable test flag.
 */
#ifndef TV_CRYPTO_H_
#define TV_CRYPTO_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define TVC_API __declspec(dllexport)
#else
#define TVC_API __attribute__((visibility("default")))
#endif

#if defined(_MSC_VER)
#define TVC_INLINE __inline
#else
#define TVC_INLINE inline
#endif

/* ------------------------------------------------------------------------ */
/* Public API                                                                */
/* ------------------------------------------------------------------------ */

#define TVC_VERSION 0x00010000u

/* tvc_info() bits. */
#define TVC_INFO_AES_ACCEL_AVAIL 0x01u  /* CPU has AES instructions          */
#define TVC_INFO_AES_ACCEL_ACTIVE 0x02u /* ...and they are in use            */
#define TVC_INFO_SHA_ACCEL_AVAIL 0x04u  /* CPU has SHA-256 instructions      */
#define TVC_INFO_SHA_ACCEL_ACTIVE 0x08u /* ...and they are in use            */
#define TVC_INFO_SELF_TEST_FAILED 0x10u /* some self-test failed             */
#define TVC_INFO_PORTABLE_FAILED 0x20u  /* portable KAT failed: do not use   */

TVC_API uint32_t tvc_version(void);
/* Lazy, thread-safe one-time init + self-test. */
TVC_API uint32_t tvc_info(void);
/* TESTS ONLY: process-wide switch that disables the accelerated paths. */
TVC_API void tvc_force_portable(int32_t on);
/* len % 16 == 0; in == out allowed (otherwise buffers must not overlap).
 * iv32 = c_prev(16) || p_prev(16). Returns 0 ok, -1 bad args. */
TVC_API int32_t tvc_aes256_ige(int32_t encrypt, const uint8_t* key32,
                               const uint8_t* iv32, const uint8_t* in,
                               uint8_t* out, size_t len);
TVC_API size_t tvc_aes256_ctr_ctx_size(void);
/* Returns 0 ok, -1 bad args. ctx must be tvc_aes256_ctr_ctx_size() bytes. */
TVC_API int32_t tvc_aes256_ctr_init(void* ctx, const uint8_t* key32,
                                    const uint8_t* iv16);
/* Byte-granular keystream continuation, 128-bit big-endian counter.
 * in == out allowed. */
TVC_API void tvc_aes256_ctr_xor(void* ctx, const uint8_t* in, uint8_t* out,
                                size_t len);
TVC_API void tvc_sha256(const uint8_t* in, size_t len, uint8_t* out32);
/* sha256(a || b) */
TVC_API void tvc_sha256_2(const uint8_t* a, size_t alen, const uint8_t* b,
                          size_t blen, uint8_t* out32);

/* ------------------------------------------------------------------------ */
/* Internal interface                                                        */
/* ------------------------------------------------------------------------ */

/* Which accelerated implementations are compiled in. */
#if defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__)) && \
    (defined(__ANDROID__) || defined(__linux__))
#define TVC_HAVE_ARMV8 1
#else
#define TVC_HAVE_ARMV8 0
#endif

/* x86_64 AES-NI: Windows (MSVC) and non-Android clang/gcc. Android x86_64
 * (emulator only) builds the portable path. */
#if (defined(_MSC_VER) && defined(_M_X64)) || \
    (defined(__x86_64__) && !defined(__ANDROID__) && \
     (defined(__clang__) || defined(__GNUC__)))
#define TVC_HAVE_X86AES 1
#else
#define TVC_HAVE_X86AES 0
#endif

/* Expanded AES-256 key. Words are big-endian packed bytes (FIPS-197 order);
 * *_b are the same round keys serialised as bytes for the AES instructions.
 * dk is the equivalent-inverse-cipher schedule (InvMixColumns applied to
 * round keys 1..13, order reversed). */
typedef struct {
  uint32_t ek[60];
  uint32_t dk[60];
  uint8_t ekb[240];
  uint8_t dkb[240];
} tvc_aes256_key;

typedef struct {
  tvc_aes256_key key;
  uint8_t ctr[16];
  uint8_t ks[16];
  uint32_t ks_used; /* bytes of ks already consumed, 16 = none left */
  uint32_t magic;
} tvc_ctr_ctx;

/* aes_portable.c */
void tvc_p_aes_tables_init(void);
void tvc_p_aes256_expand(tvc_aes256_key* k, const uint8_t key32[32]);
void tvc_p_aes_enc_block(const tvc_aes256_key* k, const uint8_t in[16],
                         uint8_t out[16]);
void tvc_p_aes_dec_block(const tvc_aes256_key* k, const uint8_t in[16],
                         uint8_t out[16]);
void tvc_p_aes_ige(int encrypt, const tvc_aes256_key* k, const uint8_t iv32[32],
                   const uint8_t* in, uint8_t* out, size_t nblocks);
/* XORs nblocks of keystream starting at ctr; ctr is advanced. */
void tvc_p_aes_ctr(const tvc_aes256_key* k, uint8_t ctr[16], const uint8_t* in,
                   uint8_t* out, size_t nblocks);

/* sha256_portable.c */
void tvc_p_sha256_blocks(uint32_t st[8], const uint8_t* data, size_t nblocks);
extern const uint32_t tvc_sha256_k[64];

/* Shared helpers. */
static TVC_INLINE void tvc_ctr_inc(uint8_t ctr[16]) {
  int i;
  for (i = 15; i >= 0; i--) {
    ctr[i] = (uint8_t)(ctr[i] + 1);
    if (ctr[i] != 0) break;
  }
}

#if TVC_HAVE_ARMV8
/* aes_armv8.c / sha256_armv8.c (aarch64 only) */
int tvc_armv8_aes_avail(void);
int tvc_armv8_sha2_avail(void);
void tvc_armv8_aes_ige(int encrypt, const tvc_aes256_key* k,
                       const uint8_t iv32[32], const uint8_t* in, uint8_t* out,
                       size_t nblocks);
void tvc_armv8_aes_ctr(const tvc_aes256_key* k, uint8_t ctr[16],
                       const uint8_t* in, uint8_t* out, size_t nblocks);
void tvc_armv8_sha256_blocks(uint32_t st[8], const uint8_t* data,
                             size_t nblocks);
#endif

#if TVC_HAVE_X86AES
/* aes_x86.c (x86_64 only) */
int tvc_x86_aes_avail(void);
void tvc_x86_aes_ige(int encrypt, const tvc_aes256_key* k,
                     const uint8_t iv32[32], const uint8_t* in, uint8_t* out,
                     size_t nblocks);
void tvc_x86_aes_ctr(const tvc_aes256_key* k, uint8_t ctr[16],
                     const uint8_t* in, uint8_t* out, size_t nblocks);
#endif

#ifdef __cplusplus
}
#endif

#endif /* TV_CRYPTO_H_ */
