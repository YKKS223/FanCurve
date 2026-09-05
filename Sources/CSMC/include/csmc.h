#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* AppleSMC user-client wrapper.
   Reading works as a normal user; writing requires root. */

#define CSMC_OK              0
#define CSMC_ERR_NO_SERVICE -1
#define CSMC_ERR_OPEN       -2
#define CSMC_ERR_NOT_OPEN   -3
#define CSMC_ERR_CALL       -4
#define CSMC_ERR_SIZE       -5

/* Attribute bits reported by the SMC for a key. */
#define CSMC_ATTR_READABLE  0x80
#define CSMC_ATTR_WRITABLE  0x40

int  csmc_open(void);

/* Calls the AppleSMC user client's "open" selector (index 0). Some firmware only
   accepts writes after this; harmless when it is not required. Returns the
   kern_return_t as an int, 0 on success. */
int  csmc_user_client_open(void);
int  csmc_user_client_close(void);
void csmc_close(void);
int  csmc_is_open(void);

/* Number of keys the SMC exposes (value of the "#KEY" key). */
int  csmc_key_count(uint32_t *out_count);

/* 4-char key at the given enumeration index; out_key must hold 5 bytes. */
int  csmc_key_at_index(uint32_t index, char *out_key);

/* Metadata for a key. Any out pointer may be NULL. */
int  csmc_key_info(const char *key, uint32_t *out_type, uint32_t *out_size, uint8_t *out_attr);

/* Raw read. out_bytes must hold at least 32 bytes. */
int  csmc_read(const char *key, uint32_t *out_type, uint32_t *out_size, uint8_t *out_bytes);

/* Raw write. size must match the key's declared size. Requires root. */
int  csmc_write(const char *key, uint32_t size, const uint8_t *bytes);

/* The `result` byte the SMC returned for the most recent call. 0 = success.
   Non-zero values are firmware status codes (0x84 = key not found,
   0x85 = not writable / not permitted, 0x89 = bad argument). */
uint8_t csmc_last_result(void);

/* Non-zero when the most recent failure came from IOConnectCallStructMethod
   itself rather than from a firmware status code. */
int  csmc_last_kern_failed(void);

/* Convenience: decode a raw value into a double using its SMC type code. */
double csmc_decode(uint32_t type, uint32_t size, const uint8_t *bytes);

/* Type code helpers. */
uint32_t csmc_type_from_string(const char *s);
void     csmc_type_to_string(uint32_t type, char *out5);

#ifdef __cplusplus
}
#endif
#endif
