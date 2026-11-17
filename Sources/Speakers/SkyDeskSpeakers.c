// SkyDesk Speakers (build 65, user request 2026-11-17: "can u have "skydesk speakers" in the output option on my mac
// that outputs to my ipad").
//
// A Core Audio driver (AudioServerPlugIn) with one output device and nothing else. It makes no sound: whatever apps
// play into it is picked up by SkyDesk Host's system sound tap and sent to the iPad, so choosing "SkyDesk Speakers"
// in the Mac's Sound output menu sends the Mac's sound to the iPad, and choosing anything else keeps it on the Mac.
//
// Objects: the plug-in (1), the device (2) and its output stream (3). 48 kHz stereo 32-bit float, fixed.
// The clock is the host clock, advanced one ring-buffer period at a time, as in Apple's NullAudio sample.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define kPlugInID      kAudioObjectPlugInObject
#define kDeviceID      2
#define kStreamID      3
#define kSampleRate    48000.0
#define kChannels      2
#define kPeriodFrames  16384
#define kDeviceUID     "SkyDeskSpeakers_UID"
#define kModelUID      "SkyDeskSpeakers_Model"

static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gRefCount = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStamps = 0;
static Boolean gStreamActive = true;

// MARK: Interface

static HRESULT SD_QueryInterface(void *driver, REFIID iid, LPVOID *out);
static ULONG SD_AddRef(void *driver);
static ULONG SD_Release(void *driver);
static OSStatus SD_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus SD_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus SD_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus SD_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) { return noErr; }
static OSStatus SD_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) { return noErr; }
static OSStatus SD_PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) { return noErr; }
static OSStatus SD_AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) { return noErr; }
static Boolean SD_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr);
static OSStatus SD_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *out);
static OSStatus SD_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 *out);
static OSStatus SD_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 size, UInt32 *outSize, void *out);
static OSStatus SD_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 size, const void *data);
static OSStatus SD_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client);
static OSStatus SD_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client);
static OSStatus SD_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed);
static OSStatus SD_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *willDo, Boolean *inPlace);
static OSStatus SD_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) { return noErr; }
static OSStatus SD_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) { return noErr; }
static OSStatus SD_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) { return noErr; }

static AudioServerPlugInDriverInterface gInterface = {
    NULL, SD_QueryInterface, SD_AddRef, SD_Release, SD_Initialize, SD_CreateDevice, SD_DestroyDevice,
    SD_AddDeviceClient, SD_RemoveDeviceClient, SD_PerformConfigChange, SD_AbortConfigChange,
    SD_HasProperty, SD_IsPropertySettable, SD_GetPropertyDataSize, SD_GetPropertyData, SD_SetPropertyData,
    SD_StartIO, SD_StopIO, SD_GetZeroTimeStamp, SD_WillDoIOOperation, SD_BeginIOOperation, SD_DoIOOperation, SD_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePtr;

// Named in Info.plist (CFPlugInFactories).
void *SkyDeskSpeakers_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriver;
}

static HRESULT SD_QueryInterface(void *driver, REFIID iid, LPVOID *out) {
    if (driver != gDriver || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *out = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}
static ULONG SD_AddRef(void *driver) { return driver == gDriver ? atomic_fetch_add(&gRefCount, 1) + 1 : 0; }
static ULONG SD_Release(void *driver) {
    if (driver != gDriver) return 0;
    unsigned int count = atomic_load(&gRefCount);
    if (count > 0) count = atomic_fetch_sub(&gRefCount, 1) - 1;
    return count;
}
static OSStatus SD_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    return noErr;
}

// MARK: Properties

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean SD_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr) {
    UInt32 size = 0;
    return SD_GetPropertyDataSize(d, obj, pid, addr, 0, NULL, &size) == noErr;
}

static OSStatus SD_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *out) {
    if (d != gDriver || addr == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!SD_HasProperty(d, obj, pid, addr)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (obj == kStreamID && (addr->mSelector == kAudioStreamPropertyIsActive)) *out = true;
    return noErr;
}

static OSStatus SD_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 *out) {
    if (d != gDriver || addr == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    switch (obj) {
    case kPlugInID:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyManufacturer: case kAudioPlugInPropertyResourceBundle: *out = sizeof(CFStringRef); return noErr;
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: *out = sizeof(AudioObjectID); return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice: *out = sizeof(AudioObjectID); return noErr;
        }
        break;
    case kDeviceID:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: *out = sizeof(CFStringRef); return noErr;
        case kAudioDevicePropertyTransportType: case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: *out = sizeof(UInt32); return noErr;
        case kAudioDevicePropertyRelatedDevices: *out = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
            *out = (addr->mScope == kAudioObjectPropertyScopeInput ? 0 : 1) * sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyControlList: *out = 0; return noErr;
        case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: *out = sizeof(AudioValueRange); return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); return noErr;
        }
        break;
    case kStreamID:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyOwnedObjects: *out = 0; return noErr;
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: *out = sizeof(UInt32); return noErr;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *out = sizeof(AudioStreamBasicDescription); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: *out = sizeof(AudioStreamRangedDescription); return noErr;
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

#define PUT(type, value) do { if (size < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)out = (value); *outSize = sizeof(type); return noErr; } while (0)

static OSStatus SD_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 size, UInt32 *outSize, void *out) {
    if (d != gDriver || addr == NULL || outSize == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    switch (obj) {
    case kPlugInID:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("SkyDesk"));
        case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
            if (size < sizeof(AudioObjectID)) { *outSize = 0; return noErr; }
            PUT(AudioObjectID, kDeviceID);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (qs == sizeof(CFStringRef) && q != NULL && CFStringCompare(*(CFStringRef *)q, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) found = kDeviceID;
            PUT(AudioObjectID, found);
        }
        }
        break;
    case kDeviceID:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kPlugInID);
        case kAudioObjectPropertyName: PUT(CFStringRef, CFSTR("SkyDesk Speakers"));
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("SkyDesk"));
        case kAudioDevicePropertyDeviceUID: PUT(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID: PUT(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: PUT(AudioObjectID, kDeviceID);
        case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: { pthread_mutex_lock(&gLock); UInt32 running = gIOCount > 0; pthread_mutex_unlock(&gLock); PUT(UInt32, running); }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, addr->mScope == kAudioObjectPropertyScopeInput ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, addr->mScope == kAudioObjectPropertyScopeInput ? 0 : 1);
        case kAudioDevicePropertyLatency: PUT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kPeriodFrames);
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
            if (addr->mScope == kAudioObjectPropertyScopeInput || size < sizeof(AudioObjectID)) { *outSize = 0; return noErr; }
            PUT(AudioObjectID, kStreamID);
        case kAudioObjectPropertyControlList: *outSize = 0; return noErr;
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: { AudioValueRange r = { kSampleRate, kSampleRate }; PUT(AudioValueRange, r); }
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (size < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)out)[0] = 1; ((UInt32 *)out)[1] = 2; *outSize = 2 * sizeof(UInt32); return noErr;
        }
        break;
    case kStreamID:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kDeviceID);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
        case kAudioStreamPropertyIsActive: { pthread_mutex_lock(&gLock); UInt32 active = gStreamActive; pthread_mutex_unlock(&gLock); PUT(UInt32, active); }
        case kAudioStreamPropertyDirection: PUT(UInt32, 0); // 0 = output
        case kAudioStreamPropertyTerminalType: PUT(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency: PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, Format());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r; r.mFormat = Format(); r.mSampleRateRange.mMinimum = kSampleRate; r.mSampleRateRange.mMaximum = kSampleRate;
            PUT(AudioStreamRangedDescription, r);
        }
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SD_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 size, const void *data) {
    if (d != gDriver || addr == NULL) return kAudioHardwareIllegalOperationError;
    if (obj == kStreamID && addr->mSelector == kAudioStreamPropertyIsActive) {
        if (size != sizeof(UInt32) || data == NULL) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gLock); gStreamActive = *(const UInt32 *)data != 0; pthread_mutex_unlock(&gLock);
        return noErr;
    }
    // The one format is all there is: setting it to itself is fine, anything else is refused.
    if (obj == kStreamID && (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription) || data == NULL) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = data;
        return f->mSampleRate == kSampleRate && f->mChannelsPerFrame == kChannels ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (obj == kDeviceID && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64) || data == NULL) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)data == kSampleRate ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    return SD_HasProperty(d, obj, pid, addr) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareUnknownPropertyError;
}

// MARK: IO

static OSStatus SD_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    if (d != gDriver || id != kDeviceID) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    if (gIOCount == 0) { gAnchorHostTime = mach_absolute_time(); gTimeStamps = 0; }
    gIOCount++;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus SD_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    if (d != gDriver || id != kDeviceID) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus SD_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    if (d != gDriver || id != kDeviceID) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    Float64 ticksPerPeriod = gHostTicksPerFrame * kPeriodFrames;
    UInt64 now = mach_absolute_time();
    while ((Float64)(now - gAnchorHostTime) >= (Float64)(gTimeStamps + 1) * ticksPerPeriod) gTimeStamps++;
    *sampleTime = (Float64)(gTimeStamps * kPeriodFrames);
    *hostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStamps * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus SD_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *willDo, Boolean *inPlace) {
    if (d != gDriver || id != kDeviceID) return kAudioHardwareBadObjectError;
    // Mixed output is accepted and dropped: the sound reaches the iPad through SkyDesk Host's tap.
    *willDo = op == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return noErr;
}
