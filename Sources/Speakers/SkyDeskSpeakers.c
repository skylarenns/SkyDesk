// SkyDesk's Core Audio driver (AudioServerPlugIn), installed from the SkyDesk Host window.
//
// "SkyDesk Speakers" (build 65, user request 2026-11-17: "can u have "skydesk speakers" in the output option on my
// mac that outputs to my ipad"): an output that makes no sound. Whatever apps play into it is picked up by SkyDesk
// Host's system sound tap and sent to the iPad, so choosing it in the Mac's Sound menu sends the Mac's sound to the
// iPad, and choosing anything else keeps it on the Mac.
//
// "SkyDesk Microphone" (build 68, user report 2026-11-18: "why is sky desk microphone in the output thing"): a
// loopback for the iPad's microphone. SkyDesk Host plays the microphone into its output side and Mac apps record
// it from its input side. Its output side cannot be the Mac's default output, so the Sound menu and settings list
// it under input only. It replaces the renamed BlackHole device, which as a two-way device showed under output too.
//
// Objects: the plug-in (1); SkyDesk Speakers (2) with its output stream (3); SkyDesk Microphone (4) with its output
// stream (5) and input stream (6). 48 kHz stereo 32-bit float, fixed. Each device's clock is the host clock,
// advanced one ring-buffer period at a time, as in Apple's NullAudio sample.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define kPlugInID          kAudioObjectPlugInObject
#define kSpeakersID        2
#define kSpeakersOutID     3
#define kMicID             4
#define kMicOutID          5
#define kMicInID           6
#define kSampleRate        48000.0
#define kChannels          2
#define kPeriodFrames      16384
#define kSpeakersUID       "SkyDeskSpeakers_UID"
#define kMicUID            "SkyDeskMicrophone_UID"

static atomic_uint gRefCount = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static Float64 gHostTicksPerFrame = 0;

typedef struct { UInt32 ioCount; UInt64 anchor; UInt64 stamps; } Clock;
static Clock gClock[2]; // 0 = speakers, 1 = microphone
static Boolean gActive[7] = { false, false, false, true, false, true, true };

// The microphone's loopback: written at the output's sample time, read at the input's, and cleared once read so
// a silence on the writing side reads as silence, not a repeat of the last buffer.
static Float32 gRing[kPeriodFrames * kChannels];

static int ClockIndex(AudioObjectID device) { return device == kSpeakersID ? 0 : device == kMicID ? 1 : -1; }
static Boolean IsDevice(AudioObjectID obj) { return obj == kSpeakersID || obj == kMicID; }
static Boolean IsStream(AudioObjectID obj) { return obj == kSpeakersOutID || obj == kMicOutID || obj == kMicInID; }
static AudioObjectID StreamOwner(AudioObjectID stream) { return stream == kSpeakersOutID ? kSpeakersID : kMicID; }

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
static OSStatus SD_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary);
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

/// The device's streams in a scope: speakers have output only; the microphone has both.
static UInt32 Streams(AudioObjectID device, AudioObjectPropertyScope scope, AudioObjectID *list) {
    UInt32 n = 0;
    if (device == kSpeakersID) {
        if (scope != kAudioObjectPropertyScopeInput) list[n++] = kSpeakersOutID;
    } else {
        if (scope != kAudioObjectPropertyScopeInput) list[n++] = kMicOutID;
        if (scope != kAudioObjectPropertyScopeOutput) list[n++] = kMicInID;
    }
    return n;
}
/// Whether the device may be the Mac's default in a scope: this is what keeps the microphone out of output lists.
static UInt32 CanBeDefault(AudioObjectID device, AudioObjectPropertyScope scope) {
    if (device == kSpeakersID) return scope != kAudioObjectPropertyScopeInput;
    return scope == kAudioObjectPropertyScopeInput;
}

static Boolean SD_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr) {
    UInt32 size = 0;
    return SD_GetPropertyDataSize(d, obj, pid, addr, 0, NULL, &size) == noErr;
}

static OSStatus SD_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *out) {
    if (d != gDriver || addr == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!SD_HasProperty(d, obj, pid, addr)) return kAudioHardwareUnknownPropertyError;
    *out = IsStream(obj) && addr->mSelector == kAudioStreamPropertyIsActive;
    return noErr;
}

static OSStatus SD_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 *out) {
    if (d != gDriver || addr == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (obj == kPlugInID) {
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyManufacturer: case kAudioPlugInPropertyResourceBundle: *out = sizeof(CFStringRef); return noErr;
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: *out = 2 * sizeof(AudioObjectID); return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice: *out = sizeof(AudioObjectID); return noErr;
        }
    } else if (IsDevice(obj)) {
        AudioObjectID list[2];
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
            *out = Streams(obj, addr->mScope, list) * sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyControlList: *out = 0; return noErr;
        case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: *out = sizeof(AudioValueRange); return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); return noErr;
        }
    } else if (IsStream(obj)) {
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyOwnedObjects: *out = 0; return noErr;
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: *out = sizeof(UInt32); return noErr;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *out = sizeof(AudioStreamBasicDescription); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: *out = sizeof(AudioStreamRangedDescription); return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

#define PUT(type, value) do { if (size < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)out = (value); *outSize = sizeof(type); return noErr; } while (0)

static OSStatus SD_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 size, UInt32 *outSize, void *out) {
    if (d != gDriver || addr == NULL || outSize == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (obj == kPlugInID) {
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("SkyDesk"));
        case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: {
            AudioObjectID devices[2] = { kSpeakersID, kMicID };
            UInt32 n = size / sizeof(AudioObjectID); if (n > 2) n = 2;
            memcpy(out, devices, n * sizeof(AudioObjectID)); *outSize = n * sizeof(AudioObjectID); return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (qs == sizeof(CFStringRef) && q != NULL) {
                CFStringRef uid = *(CFStringRef *)q;
                if (CFStringCompare(uid, CFSTR(kSpeakersUID), 0) == kCFCompareEqualTo) found = kSpeakersID;
                else if (CFStringCompare(uid, CFSTR(kMicUID), 0) == kCFCompareEqualTo) found = kMicID;
            }
            PUT(AudioObjectID, found);
        }
        }
    } else if (IsDevice(obj)) {
        Boolean mic = obj == kMicID;
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kPlugInID);
        case kAudioObjectPropertyName: PUT(CFStringRef, mic ? CFSTR("SkyDesk Microphone") : CFSTR("SkyDesk Speakers"));
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR("SkyDesk"));
        case kAudioDevicePropertyDeviceUID: PUT(CFStringRef, mic ? CFSTR(kMicUID) : CFSTR(kSpeakersUID));
        case kAudioDevicePropertyModelUID: PUT(CFStringRef, mic ? CFSTR("SkyDeskMicrophone_Model") : CFSTR("SkyDeskSpeakers_Model"));
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: PUT(AudioObjectID, obj);
        case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gLock); UInt32 running = gClock[ClockIndex(obj)].ioCount > 0; pthread_mutex_unlock(&gLock);
            PUT(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, CanBeDefault(obj, addr->mScope));
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, CanBeDefault(obj, addr->mScope));
        case kAudioDevicePropertyLatency: PUT(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kPeriodFrames);
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            AudioObjectID list[2];
            UInt32 n = Streams(obj, addr->mScope, list), fit = size / sizeof(AudioObjectID);
            if (n > fit) n = fit;
            memcpy(out, list, n * sizeof(AudioObjectID)); *outSize = n * sizeof(AudioObjectID); return noErr;
        }
        case kAudioObjectPropertyControlList: *outSize = 0; return noErr;
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: { AudioValueRange r = { kSampleRate, kSampleRate }; PUT(AudioValueRange, r); }
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (size < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)out)[0] = 1; ((UInt32 *)out)[1] = 2; *outSize = 2 * sizeof(UInt32); return noErr;
        }
    } else if (IsStream(obj)) {
        Boolean input = obj == kMicInID;
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, StreamOwner(obj));
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
        case kAudioStreamPropertyIsActive: { pthread_mutex_lock(&gLock); UInt32 active = gActive[obj]; pthread_mutex_unlock(&gLock); PUT(UInt32, active); }
        case kAudioStreamPropertyDirection: PUT(UInt32, input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: PUT(UInt32, input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency: PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, Format());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r; r.mFormat = Format(); r.mSampleRateRange.mMinimum = kSampleRate; r.mSampleRateRange.mMaximum = kSampleRate;
            PUT(AudioStreamRangedDescription, r);
        }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SD_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qs, const void *q, UInt32 size, const void *data) {
    if (d != gDriver || addr == NULL) return kAudioHardwareIllegalOperationError;
    if (IsStream(obj) && addr->mSelector == kAudioStreamPropertyIsActive) {
        if (size != sizeof(UInt32) || data == NULL) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gLock); gActive[obj] = *(const UInt32 *)data != 0; pthread_mutex_unlock(&gLock);
        return noErr;
    }
    // The one format is all there is: setting it to itself is fine, anything else is refused.
    if (IsStream(obj) && (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription) || data == NULL) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = data;
        return f->mSampleRate == kSampleRate && f->mChannelsPerFrame == kChannels ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (IsDevice(obj) && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64) || data == NULL) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)data == kSampleRate ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    return SD_HasProperty(d, obj, pid, addr) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareUnknownPropertyError;
}

// MARK: IO

static OSStatus SD_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    int c = ClockIndex(id);
    if (d != gDriver || c < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    if (gClock[c].ioCount == 0) {
        gClock[c].anchor = mach_absolute_time(); gClock[c].stamps = 0;
        if (id == kMicID) memset(gRing, 0, sizeof(gRing));
    }
    gClock[c].ioCount++;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus SD_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    int c = ClockIndex(id);
    if (d != gDriver || c < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    if (gClock[c].ioCount > 0) gClock[c].ioCount--;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus SD_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    int c = ClockIndex(id);
    if (d != gDriver || c < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    Clock *clock = &gClock[c];
    Float64 ticksPerPeriod = gHostTicksPerFrame * kPeriodFrames;
    UInt64 now = mach_absolute_time();
    while ((Float64)(now - clock->anchor) >= (Float64)(clock->stamps + 1) * ticksPerPeriod) clock->stamps++;
    *sampleTime = (Float64)(clock->stamps * kPeriodFrames);
    *hostTime = clock->anchor + (UInt64)((Float64)clock->stamps * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus SD_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *willDo, Boolean *inPlace) {
    if (d != gDriver || !IsDevice(id)) return kAudioHardwareBadObjectError;
    // Speakers: mixed output is accepted and dropped (the sound reaches the iPad through SkyDesk Host's tap).
    // Microphone: mixed output goes into the loopback and input is read back out of it.
    *willDo = op == kAudioServerPlugInIOOperationWriteMix || (id == kMicID && op == kAudioServerPlugInIOOperationReadInput);
    *inPlace = true;
    return noErr;
}
static OSStatus SD_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
    if (d != gDriver || !IsDevice(id)) return kAudioHardwareBadObjectError;
    if (id != kMicID || main == NULL || info == NULL) return noErr;
    Float32 *buffer = main;
    UInt64 start = op == kAudioServerPlugInIOOperationWriteMix ? (UInt64)info->mOutputTime.mSampleTime : (UInt64)info->mInputTime.mSampleTime;
    UInt32 offset = (UInt32)(start % kPeriodFrames);
    UInt32 first = frames < kPeriodFrames - offset ? frames : kPeriodFrames - offset;
    UInt32 second = frames - first;
    if (frames > kPeriodFrames) return noErr;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        memcpy(gRing + offset * kChannels, buffer, first * kChannels * sizeof(Float32));
        memcpy(gRing, buffer + first * kChannels, second * kChannels * sizeof(Float32));
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        memcpy(buffer, gRing + offset * kChannels, first * kChannels * sizeof(Float32));
        memcpy(buffer + first * kChannels, gRing, second * kChannels * sizeof(Float32));
        memset(gRing + offset * kChannels, 0, first * kChannels * sizeof(Float32));
        memset(gRing, 0, second * kChannels * sizeof(Float32));
    }
    return noErr;
}
