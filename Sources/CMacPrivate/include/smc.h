#ifndef CMACPRIVATE_SMC_H
#define CMACPRIVATE_SMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

// AppleSMC user client. Layout matches the kernel's SMCParamStruct (80 bytes).
static const uint32_t kCSMCHandleYPCEvent = 2;
static const uint8_t kCSMCCmdReadBytes = 5;
static const uint8_t kCSMCCmdWriteBytes = 6;
static const uint8_t kCSMCCmdReadIndex = 8;
static const uint8_t kCSMCCmdReadKeyInfo = 9;
static const kern_return_t kCSMCNotPrivileged = (kern_return_t)0xE00002C1; // kIOReturnNotPrivileged
static const kern_return_t kCSMCNotFound = (kern_return_t)0xE00002F0;      // kIOReturnNotFound

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} CSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} CSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} CSMCKeyInfo;

typedef struct {
    uint32_t key;
    CSMCVersion vers;
    CSMCPLimitData pLimitData;
    CSMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} CSMCParam;

_Static_assert(sizeof(CSMCParam) == 80, "AppleSMC expects an 80-byte parameter struct");

/// Opens the AppleSMC user client. Returns kCSMCNotFound if there is no AppleSMC service.
kern_return_t csmc_open(io_connect_t *connection);

/// One SMC command round trip.
kern_return_t csmc_call(io_connect_t connection, const CSMCParam *input, CSMCParam *output);

#endif
