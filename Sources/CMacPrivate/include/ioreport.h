#ifndef CMACPRIVATE_IOREPORT_H
#define CMACPRIVATE_IOREPORT_H

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

// Private API in /usr/lib/libIOReport.dylib. Not documented by Apple; signatures follow the
// open-source tools that use it (macmon, asitop). Channel formats: 1 = simple, 2 = state.

CF_ASSUME_NONNULL_BEGIN

typedef struct CF_BRIDGED_TYPE(id) __IOReportSubscription *IOReportSubscriptionRef;

CFDictionaryRef _Nullable IOReportCopyAllChannels(uint64_t a, uint64_t b) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup,
                                                      uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
void IOReportMergeChannels(CFMutableDictionaryRef into, CFDictionaryRef from, CFTypeRef _Nullable unused);
IOReportSubscriptionRef _Nullable IOReportCreateSubscription(void * _Nullable unused, CFMutableDictionaryRef channels,
                                                             CFMutableDictionaryRef _Nullable * _Nonnull subscribed,
                                                             uint64_t channelID, CFTypeRef _Nullable unused2)
    CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef subscribed,
                                                CFTypeRef _Nullable unused) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current,
                                                     CFTypeRef _Nullable unused) CF_RETURNS_RETAINED;

CFStringRef _Nullable IOReportChannelGetGroup(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetSubGroup(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetUnitLabel(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
uint8_t IOReportChannelGetFormat(CFDictionaryRef channel);

int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

CF_ASSUME_NONNULL_END

#endif
