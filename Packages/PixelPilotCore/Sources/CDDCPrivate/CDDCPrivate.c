#include "include/CDDCPrivate.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>

typedef CFTypeRef (*IOAVServiceCreateWithServiceFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVServiceWriteI2CFn)(CFTypeRef, uint32_t, uint32_t, const void *, uint32_t);
typedef IOReturn (*IOAVServiceReadI2CFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef CFDataRef (*IOAVServiceCopyEDIDFn)(CFTypeRef);

static IOAVServiceCreateWithServiceFn sCreateWithService;
static IOAVServiceWriteI2CFn sWriteI2C;
static IOAVServiceReadI2CFn sReadI2C;
static IOAVServiceCopyEDIDFn sCopyEDID;
static bool sAvailable;

static void ppResolveSymbols(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sCreateWithService = (IOAVServiceCreateWithServiceFn)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    sWriteI2C = (IOAVServiceWriteI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    sReadI2C = (IOAVServiceReadI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    sCopyEDID = (IOAVServiceCopyEDIDFn)dlsym(RTLD_DEFAULT, "IOAVServiceCopyEDID");
    sAvailable = sCreateWithService && sWriteI2C && sReadI2C;
  });
}

bool PPAVServiceAvailable(void) {
  ppResolveSymbols();
  return sAvailable;
}

void *PPAVServiceCreate(io_service_t service) {
  ppResolveSymbols();
  if (!sAvailable) {
    return NULL;
  }
  // IOAVServiceCreateWithService follows the CF "Create" rule: the result is
  // already +1, so we hand it straight to Swift as an owning raw pointer.
  CFTypeRef ref = sCreateWithService(kCFAllocatorDefault, service);
  return (void *)ref;
}

void PPAVServiceRelease(void *service) {
  if (service) {
    CFRelease((CFTypeRef)service);
  }
}

int32_t PPAVServiceWriteI2C(void *service, uint32_t chipAddress, uint32_t dataAddress,
                            const void *buffer, uint32_t length) {
  ppResolveSymbols();
  if (!sAvailable || !service) {
    return kIOReturnNotReady;
  }
  return (int32_t)sWriteI2C((CFTypeRef)service, chipAddress, dataAddress, buffer, length);
}

int32_t PPAVServiceReadI2C(void *service, uint32_t chipAddress, uint32_t offset,
                           void *buffer, uint32_t length) {
  ppResolveSymbols();
  if (!sAvailable || !service) {
    return kIOReturnNotReady;
  }
  return (int32_t)sReadI2C((CFTypeRef)service, chipAddress, offset, buffer, length);
}

#pragma mark - Native brightness (DisplayServices)

typedef int (*DisplayServicesGetBrightnessFn)(uint32_t, float *);
typedef int (*DisplayServicesSetBrightnessFn)(uint32_t, float);
typedef bool (*DisplayServicesCanChangeBrightnessFn)(uint32_t);

static DisplayServicesGetBrightnessFn sGetBrightness;
static DisplayServicesSetBrightnessFn sSetBrightness;
static DisplayServicesCanChangeBrightnessFn sCanChangeBrightness;
static bool sNativeAvailable;

static void ppResolveDisplayServices(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Not in the SDK, so it must be opened by path rather than linked.
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
      return;
    }
    sGetBrightness = (DisplayServicesGetBrightnessFn)dlsym(handle, "DisplayServicesGetBrightness");
    sSetBrightness = (DisplayServicesSetBrightnessFn)dlsym(handle, "DisplayServicesSetBrightness");
    sCanChangeBrightness =
        (DisplayServicesCanChangeBrightnessFn)dlsym(handle, "DisplayServicesCanChangeBrightness");
    sNativeAvailable = sGetBrightness && sSetBrightness;
  });
}

bool PPNativeBrightnessAvailable(void) {
  ppResolveDisplayServices();
  return sNativeAvailable;
}

bool PPNativeBrightnessSupported(uint32_t displayID) {
  ppResolveDisplayServices();
  if (!sNativeAvailable) {
    return false;
  }
  if (sCanChangeBrightness) {
    return sCanChangeBrightness(displayID);
  }
  // Without the capability query, a successful read is the next best evidence.
  float value = 0;
  return sGetBrightness(displayID, &value) == 0;
}

bool PPNativeBrightnessGet(uint32_t displayID, float *value) {
  ppResolveDisplayServices();
  if (!sNativeAvailable || !value) {
    return false;
  }
  return sGetBrightness(displayID, value) == 0;
}

bool PPNativeBrightnessSet(uint32_t displayID, float value) {
  ppResolveDisplayServices();
  if (!sNativeAvailable) {
    return false;
  }
  if (value < 0.0f) {
    value = 0.0f;
  }
  if (value > 1.0f) {
    value = 1.0f;
  }
  return sSetBrightness(displayID, value) == 0;
}

#pragma mark - Experimental

int32_t PPAVServiceCopyEDIDExperimental(void *service, uint8_t *buffer, uint32_t capacity) {
  ppResolveSymbols();
  if (!sCopyEDID || !service) {
    return -1;
  }
  CFDataRef data = sCopyEDID((CFTypeRef)service);
  if (!data) {
    return -1;
  }
  CFIndex length = CFDataGetLength(data);
  if (length < 0 || (uint32_t)length > capacity) {
    length = (CFIndex)capacity;
  }
  CFDataGetBytes(data, CFRangeMake(0, length), buffer);
  CFRelease(data);
  return (int32_t)length;
}
