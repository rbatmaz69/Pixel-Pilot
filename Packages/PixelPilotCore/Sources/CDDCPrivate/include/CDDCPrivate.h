//
//  CDDCPrivate.h
//  Thin C shim over the undocumented IOAVService I2C entry points.
//
//  Background: on Apple Silicon the legacy IOFramebuffer I2C APIs silently fail,
//  because displays hang off the DCP (display coprocessor) stack instead. The
//  replacement is a set of IOAVService* functions. They have no public header,
//  but the symbols *are* exported from IOKit (verified present in the macOS 26
//  SDK's IOKit.tbd).
//
//  Two deliberate choices here:
//
//  1. Symbols are resolved lazily with dlsym(RTLD_DEFAULT, ...) rather than
//     linked. If a future macOS drops them, we get a NULL function pointer and
//     can degrade to gamma dimming — instead of failing to launch.
//
//  2. The service handle crosses into Swift as `void *`, not `CFTypeRef`. That
//     keeps ARC completely out of the ownership story: we retain in
//     PPAVServiceCreate and release in PPAVServiceRelease, nowhere else.
//

#ifndef CDDCPRIVATE_H
#define CDDCPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

/// True if the IOAVService I2C entry points could be resolved on this system.
/// Everything else in this header is a no-op returning an error when false.
bool PPAVServiceAvailable(void);

/// Wraps an `io_service_t` (expected to be a `DCPAVServiceProxy`) in an
/// IOAVService. Returns an owning handle, or NULL. Balance with
/// `PPAVServiceRelease`.
void *_Nullable PPAVServiceCreate(io_service_t service);

/// Releases a handle from `PPAVServiceCreate`. NULL-safe.
void PPAVServiceRelease(void *_Nullable service);

/// Raw I2C write. `chipAddress` is the 8-bit (already shifted) address.
/// Returns an IOReturn; `kIOReturnSuccess` (0) on success.
int32_t PPAVServiceWriteI2C(void *service,
                            uint32_t chipAddress,
                            uint32_t dataAddress,
                            const void *buffer,
                            uint32_t length);

/// Raw I2C read into `buffer`. Returns an IOReturn.
int32_t PPAVServiceReadI2C(void *service,
                           uint32_t chipAddress,
                           uint32_t offset,
                           void *buffer,
                           uint32_t length);

/// Experimental: `IOAVServiceCopyEDID` is exported but its exact signature is
/// undocumented. We assume `CFDataRef (*)(void *)`. Only reachable from
/// `ppctl probe-edid` so a bad guess can never take the app down. Returns the
/// number of bytes written into `buffer`, or -1.
///
/// Production display identification does NOT use this — see
/// `DisplayRegistry`, which reads `DisplayAttributes` from the IORegistry
/// framebuffer node instead.
int32_t PPAVServiceCopyEDIDExperimental(void *service,
                                        uint8_t *buffer,
                                        uint32_t capacity);

#pragma mark - Native brightness (DisplayServices)

//
//  The built-in panel has no I2C bus. macOS drives it through DisplayServices,
//  a private framework that is not in the SDK at all — so unlike IOAVService,
//  this one has to be dlopen'd by path before its symbols can be resolved.
//
//  Same defensive posture: if any of it is missing, callers get `false` and fall
//  back to gamma dimming.
//

/// True if DisplayServices could be loaded and its brightness functions found.
bool PPNativeBrightnessAvailable(void);

/// Whether this specific display can be driven natively. False for external
/// panels, which is the expected case.
bool PPNativeBrightnessSupported(uint32_t displayID);

/// Reads brightness as 0.0...1.0. Returns false if unavailable.
bool PPNativeBrightnessGet(uint32_t displayID, float *value);

/// Writes brightness as 0.0...1.0. Returns false if unavailable.
bool PPNativeBrightnessSet(uint32_t displayID, float value);

CF_ASSUME_NONNULL_END

#endif /* CDDCPRIVATE_H */
