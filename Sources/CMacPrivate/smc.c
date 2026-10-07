#include "smc.h"

kern_return_t csmc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return kCSMCNotFound;
    }
    // mach_task_self() is a macro over a global Swift 6 rejects, so the open lives in C.
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

kern_return_t csmc_call(io_connect_t connection, const CSMCParam *input, CSMCParam *output) {
    size_t outputSize = sizeof(CSMCParam);
    return IOConnectCallStructMethod(connection, kCSMCHandleYPCEvent,
                                     input, sizeof(CSMCParam), output, &outputSize);
}
