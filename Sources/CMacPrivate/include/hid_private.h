#ifndef CMACPRIVATE_HID_PRIVATE_H
#define CMACPRIVATE_HID_PRIVATE_H

#include <stdint.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// Private IOHIDEvent API (exported by IOKit, not in the public headers). Temperature sensors are the
// services with PrimaryUsagePage 0xFF00 and PrimaryUsage 5.

CF_ASSUME_NONNULL_BEGIN

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

static const int64_t kCHIDEventTypeTemperature = 15;
static const int32_t kCHIDTemperatureLevelField = 15 << 16;
static const int kCHIDSensorUsagePage = 0xFF00;
static const int kCHIDTemperatureSensorUsage = 5;

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;

IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options,
                                                    int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

CF_ASSUME_NONNULL_END

#endif
