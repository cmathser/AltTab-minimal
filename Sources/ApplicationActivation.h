#ifndef OPTIONTAB_APPLICATION_ACTIVATION_H
#define OPTIONTAB_APPLICATION_ACTIVATION_H

#include <stdint.h>

/// Brings all windows of the target process forward in a single WindowServer operation.
/// Returns `noErr` (0) on success, or a non-zero `OSStatus` error code on failure.
int32_t OptionTabActivateApplication(int32_t pid);

#endif
