#include "include/csmc.h"

#include <string.h>
#include <IOKit/IOKitLib.h>

/* --- AppleSMC user-client structures (stable across macOS releases) --- */

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

/* data8 selectors understood by the AppleSMC user client. */
enum {
    kSMCUserClientOpen   = 0,
    kSMCUserClientClose  = 1,
    kSMCHandleYPCEvent   = 2,   /* index of the struct method */
    kSMCReadKey          = 5,
    kSMCWriteKey         = 6,
    kSMCGetKeyFromIndex  = 8,
    kSMCGetKeyInfo       = 9,
};

static io_connect_t g_conn = 0;
static uint8_t g_last_result = 0;
static int     g_last_kern_failed = 0;

uint8_t csmc_last_result(void)   { return g_last_result; }
int csmc_last_kern_failed(void)  { return g_last_kern_failed; }

static uint32_t key_from_string(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |  (uint32_t)(uint8_t)s[3];
}

uint32_t csmc_type_from_string(const char *s) { return key_from_string(s); }

void csmc_type_to_string(uint32_t t, char *out5) {
    out5[0] = (char)((t >> 24) & 0xff);
    out5[1] = (char)((t >> 16) & 0xff);
    out5[2] = (char)((t >> 8) & 0xff);
    out5[3] = (char)(t & 0xff);
    out5[4] = '\0';
}

static int smc_call(SMCParamStruct *in, SMCParamStruct *out) {
    if (!g_conn) return CSMC_ERR_NOT_OPEN;
    g_last_result = 0;
    g_last_kern_failed = 0;
    size_t outSize = sizeof(SMCParamStruct);
    kern_return_t r = IOConnectCallStructMethod(g_conn, kSMCHandleYPCEvent,
                                                in, sizeof(SMCParamStruct),
                                                out, &outSize);
    if (r != KERN_SUCCESS) { g_last_kern_failed = 1; return CSMC_ERR_CALL; }
    g_last_result = out->result;
    if (out->result != 0) return CSMC_ERR_CALL;
    return CSMC_OK;
}

int csmc_open(void) {
    if (g_conn) return CSMC_OK;
    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
    if (!svc) return CSMC_ERR_NO_SERVICE;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (r != KERN_SUCCESS) { g_conn = 0; return CSMC_ERR_OPEN; }
    return CSMC_OK;
}

int csmc_user_client_open(void) {
    if (!g_conn) return CSMC_ERR_NOT_OPEN;
    return (int)IOConnectCallScalarMethod(g_conn, kSMCUserClientOpen, NULL, 0, NULL, NULL);
}

int csmc_user_client_close(void) {
    if (!g_conn) return CSMC_ERR_NOT_OPEN;
    return (int)IOConnectCallScalarMethod(g_conn, kSMCUserClientClose, NULL, 0, NULL, NULL);
}

void csmc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

int csmc_is_open(void) { return g_conn != 0; }

int csmc_key_info(const char *key, uint32_t *out_type, uint32_t *out_size, uint8_t *out_attr) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_from_string(key);
    in.data8 = kSMCGetKeyInfo;
    int rc = smc_call(&in, &out);
    if (rc != CSMC_OK) return rc;
    if (out_type) *out_type = out.keyInfo.dataType;
    if (out_size) *out_size = out.keyInfo.dataSize;
    if (out_attr) *out_attr = out.keyInfo.dataAttributes;
    return CSMC_OK;
}

int csmc_key_count(uint32_t *out_count) {
    uint32_t type = 0, size = 0;
    uint8_t buf[32];
    int rc = csmc_read("#KEY", &type, &size, buf);
    if (rc != CSMC_OK) return rc;
    if (size != 4) return CSMC_ERR_SIZE;
    *out_count = ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) |
                 ((uint32_t)buf[2] << 8)  |  (uint32_t)buf[3];
    return CSMC_OK;
}

int csmc_key_at_index(uint32_t index, char *out_key) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8  = kSMCGetKeyFromIndex;
    in.data32 = index;
    int rc = smc_call(&in, &out);
    if (rc != CSMC_OK) return rc;
    csmc_type_to_string(out.key, out_key);
    return CSMC_OK;
}

int csmc_read(const char *key, uint32_t *out_type, uint32_t *out_size, uint8_t *out_bytes) {
    uint32_t type = 0, size = 0;
    int rc = csmc_key_info(key, &type, &size, NULL);
    if (rc != CSMC_OK) return rc;
    if (size == 0 || size > 32) return CSMC_ERR_SIZE;

    SMCParamStruct in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_from_string(key);
    in.keyInfo.dataSize = size;
    in.data8 = kSMCReadKey;
    rc = smc_call(&in, &out);
    if (rc != CSMC_OK) return rc;

    memcpy(out_bytes, out.bytes, size);
    if (out_type) *out_type = type;
    if (out_size) *out_size = size;
    return CSMC_OK;
}

int csmc_write(const char *key, uint32_t size, const uint8_t *bytes) {
    if (size == 0 || size > 32) return CSMC_ERR_SIZE;
    uint32_t declared = 0, declaredType = 0;
    int rc = csmc_key_info(key, &declaredType, &declared, NULL);
    if (rc != CSMC_OK) return rc;
    if (declared != size) return CSMC_ERR_SIZE;

    SMCParamStruct in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_from_string(key);
    in.keyInfo.dataSize = size;
    in.keyInfo.dataType = declaredType;
    in.data8 = kSMCWriteKey;
    memcpy(in.bytes, bytes, size);
    return smc_call(&in, &out);
}

static int hexdigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

double csmc_decode(uint32_t type, uint32_t size, const uint8_t *b) {
    char t[5];
    csmc_type_to_string(type, t);

    if (!strcmp(t, "flt ") && size == 4) {
        float f;
        memcpy(&f, b, 4);           /* SMC floats are little-endian */
        return (double)f;
    }
    if (!strncmp(t, "ui", 2)) {     /* unsigned, big-endian */
        uint64_t v = 0;
        for (uint32_t i = 0; i < size && i < 8; i++) v = (v << 8) | b[i];
        return (double)v;
    }
    if (!strncmp(t, "si", 2)) {     /* signed, big-endian */
        int64_t v = (int8_t)b[0];
        for (uint32_t i = 1; i < size && i < 8; i++) v = (v << 8) | b[i];
        return (double)v;
    }
    if (!strncmp(t, "fp", 2) && size == 2) {   /* fpXY: X int bits, Y fraction bits */
        int frac = hexdigit(t[3]);
        if (frac < 0) return 0.0;
        uint16_t raw = (uint16_t)((b[0] << 8) | b[1]);
        return (double)raw / (double)(1u << frac);
    }
    if (!strncmp(t, "sp", 2) && size == 2) {   /* spXY: sign + X int bits + Y fraction bits */
        int frac = hexdigit(t[3]);
        if (frac < 0) return 0.0;
        int16_t raw = (int16_t)((b[0] << 8) | b[1]);
        return (double)raw / (double)(1u << frac);
    }
    return 0.0;
}
