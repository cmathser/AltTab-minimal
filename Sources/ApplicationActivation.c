#include <ApplicationServices/ApplicationServices.h>
#include "ApplicationActivation.h"

// This public Process Manager API brings the window group forward in one
// operation. AppKit activation followed by individual AXRaise actions flickers.
// The API is deprecated and unavailable directly from Swift, so keep it here.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int32_t OptionTabActivateApplication(int32_t pid) {
    ProcessSerialNumber process;
    OSStatus status = GetProcessForPID(pid, &process);
    if (status != noErr) return status;
    return SetFrontProcessWithOptions(&process, kSetFrontProcessCausedByUser);
}
#pragma clang diagnostic pop
