#include "include/CDDCPrivate.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <os/lock.h>
#include <string.h>

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
typedef int (*DisplayServicesRegisterBrightnessChangeFn)(uint32_t, uint64_t, void *);
typedef int (*DisplayServicesUnregisterBrightnessChangeFn)(uint32_t, uint64_t);

static DisplayServicesGetBrightnessFn sGetBrightness;
static DisplayServicesSetBrightnessFn sSetBrightness;
static DisplayServicesCanChangeBrightnessFn sCanChangeBrightness;
static DisplayServicesRegisterBrightnessChangeFn sRegisterBrightnessChange;
static DisplayServicesUnregisterBrightnessChangeFn sUnregisterBrightnessChange;
static bool sNativeAvailable;
static bool sCanObserve;

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
    sRegisterBrightnessChange = (DisplayServicesRegisterBrightnessChangeFn)dlsym(
        handle, "DisplayServicesRegisterForBrightnessChangeNotifications");
    sUnregisterBrightnessChange = (DisplayServicesUnregisterBrightnessChangeFn)dlsym(
        handle, "DisplayServicesUnregisterForBrightnessChangeNotifications");
    sNativeAvailable = sGetBrightness && sSetBrightness;
    // Watching needs the read as well as the registration: the notification is
    // only ever used as "something changed", and the value comes from a read.
    sCanObserve = sNativeAvailable && sRegisterBrightnessChange && sUnregisterBrightnessChange;
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

#pragma mark - Watching native brightness

// Small and fixed: the only caller watches one panel, and a growable table for
// that would be machinery in the one file where machinery is least welcome.
#define PP_MAX_WATCHED 8

static uint32_t sWatched[PP_MAX_WATCHED];
static float sWatchedLast[PP_MAX_WATCHED];
static int sWatchedCount;
static PPNativeBrightnessObserver sObserver;
static os_unfair_lock sWatchLock = OS_UNFAIR_LOCK_INIT;

/// What DisplayServices calls. See the header for why it reads none of its
/// arguments — every one of them is a guess, and none of them is needed.
static void ppBrightnessDidChange(void *a, void *b, void *c, void *d, void *e) {
  (void)a;
  (void)b;
  (void)c;
  (void)d;
  (void)e;

  uint32_t displays[PP_MAX_WATCHED];
  int count;
  PPNativeBrightnessObserver observer;

  // Snapshot under the lock; read and report outside it. Both of those call out
  // of this file — one into a private framework, one into the caller — and
  // neither should happen while holding a lock that stopping needs.
  os_unfair_lock_lock(&sWatchLock);
  count = sWatchedCount;
  memcpy(displays, sWatched, sizeof(uint32_t) * (size_t)count);
  observer = sObserver;
  os_unfair_lock_unlock(&sWatchLock);

  if (!observer) {
    return;
  }

  for (int i = 0; i < count; i++) {
    float value = 0;
    if (!PPNativeBrightnessGet(displays[i], &value)) {
      continue;
    }

    // The notification says a display moved, not which one. Without comparing
    // against the last known value, one panel moving would be reported as a
    // change on every watched panel — and each of those is a DDC round trip
    // somewhere upstream.
    bool changed = false;
    os_unfair_lock_lock(&sWatchLock);
    for (int j = 0; j < sWatchedCount; j++) {
      if (sWatched[j] != displays[i]) {
        continue;
      }
      if (fabsf(sWatchedLast[j] - value) > 0.0001f) {
        sWatchedLast[j] = value;
        changed = true;
      }
      break;
    }
    os_unfair_lock_unlock(&sWatchLock);

    if (changed) {
      observer(displays[i], value);
    }
  }
}

bool PPNativeBrightnessCanObserve(void) {
  ppResolveDisplayServices();
  return sCanObserve;
}

bool PPNativeBrightnessObserve(uint32_t displayID, PPNativeBrightnessObserver observer) {
  ppResolveDisplayServices();
  if (!sCanObserve) {
    return false;
  }

  os_unfair_lock_lock(&sWatchLock);
  for (int i = 0; i < sWatchedCount; i++) {
    if (sWatched[i] == displayID) {
      // Already watched. One registration per display, so this only refreshes
      // who hears about it.
      sObserver = observer;
      os_unfair_lock_unlock(&sWatchLock);
      return true;
    }
  }
  bool hasRoom = sWatchedCount < PP_MAX_WATCHED;
  os_unfair_lock_unlock(&sWatchLock);

  if (!hasRoom) {
    return false;
  }

  if (sRegisterBrightnessChange(displayID, (uint64_t)displayID, (void *)ppBrightnessDidChange) !=
      0) {
    return false;
  }

  // The baseline the filter above compares against. Without it the first
  // notification reports a change from zero, whatever the panel is actually at.
  float value = 0;
  PPNativeBrightnessGet(displayID, &value);

  os_unfair_lock_lock(&sWatchLock);
  bool alreadyPresent = false;
  for (int i = 0; i < sWatchedCount; i++) {
    if (sWatched[i] == displayID) {
      alreadyPresent = true;
      break;
    }
  }
  if (!alreadyPresent && sWatchedCount < PP_MAX_WATCHED) {
    sWatched[sWatchedCount] = displayID;
    sWatchedLast[sWatchedCount] = value;
    sWatchedCount++;
  }
  sObserver = observer;
  os_unfair_lock_unlock(&sWatchLock);

  return true;
}

void PPNativeBrightnessStopObserving(uint32_t displayID) {
  ppResolveDisplayServices();
  if (!sCanObserve) {
    return;
  }

  bool wasWatched = false;
  os_unfair_lock_lock(&sWatchLock);
  for (int i = 0; i < sWatchedCount; i++) {
    if (sWatched[i] != displayID) {
      continue;
    }
    sWatched[i] = sWatched[sWatchedCount - 1];
    sWatchedLast[i] = sWatchedLast[sWatchedCount - 1];
    sWatchedCount--;
    wasWatched = true;
    break;
  }
  if (sWatchedCount == 0) {
    sObserver = NULL;
  }
  os_unfair_lock_unlock(&sWatchLock);

  if (wasWatched) {
    sUnregisterBrightnessChange(displayID, (uint64_t)displayID);
  }
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
