#include "MacAudioPermissions.h"

#include <QDebug>
#include <QEventLoop>
#include <QMetaObject>

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#include <unistd.h>
#include <vector>

// Core Audio process taps are only declared in the macOS 14.2+ SDK.
// When building with an older SDK the "System Audio" device is simply not available.
#if defined(__MAC_14_2) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_2
#  define LUMINOSUS_HAS_PROCESS_TAPS 1
#  import <CoreAudio/CATapDescription.h>
#  import <CoreAudio/AudioHardwareTapping.h>
#else
#  define LUMINOSUS_HAS_PROCESS_TAPS 0
#endif

static const char* const kSystemAudioDeviceName = "System Audio (all apps)";

static AudioObjectID s_tapID = kAudioObjectUnknown;
static AudioObjectID s_aggregateID = kAudioObjectUnknown;


// ------------------------------------------------------------------------------------
// Microphone / audio input permission
// ------------------------------------------------------------------------------------

static MacMicPermission toMacMicPermission(AVAuthorizationStatus status) {
    switch (status) {
    case AVAuthorizationStatusAuthorized: return MacMicPermission::Granted;
    case AVAuthorizationStatusDenied:     return MacMicPermission::Denied;
    case AVAuthorizationStatusRestricted: return MacMicPermission::Restricted;
    default:                              return MacMicPermission::Unknown;
    }
}

MacMicPermission macEnsureMicrophoneAccess() {
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (status != AVAuthorizationStatusNotDetermined) {
            MacMicPermission result = toMacMicPermission(status);
            if (result != MacMicPermission::Granted) {
                qWarning() << "Audio input access is not allowed. Enable Luminosus in"
                              " System Settings > Privacy & Security > Microphone and restart the app.";
            }
            return result;
        }

        // Not decided yet: show the system prompt and wait for the answer while
        // keeping the Qt / Cocoa event loop running.
        QEventLoop loop;
        __block bool granted = false;
        __block bool answered = false;
        QEventLoop* loopPtr = &loop;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) {
            granted = ok;
            answered = true;
            QMetaObject::invokeMethod(loopPtr, "quit", Qt::QueuedConnection);
        }];
        if (!answered) loop.exec();

        if (!granted) {
            qWarning() << "Audio input access was denied. Enable Luminosus in"
                          " System Settings > Privacy & Security > Microphone and restart the app.";
        }
        return granted ? MacMicPermission::Granted : MacMicPermission::Denied;
    }
    // macOS 10.13 and older have no audio input permission system:
    return MacMicPermission::Granted;
}


// ------------------------------------------------------------------------------------
// "System Audio" input (Core Audio process tap wrapped in a private aggregate device)
// ------------------------------------------------------------------------------------

QString macSystemAudioDeviceName() {
    return QString::fromUtf8(kSystemAudioDeviceName);
}

#if LUMINOSUS_HAS_PROCESS_TAPS

static NSString* deviceUID(AudioObjectID device) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyDeviceUID,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(uid);
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &uid) != noErr || !uid) {
        return nil;
    }
    return (__bridge_transfer NSString*)uid;
}

static bool hasOutputStreams(AudioObjectID device) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreams,
                                        kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, nullptr, &size) != noErr) return false;
    return size > 0;
}

// The aggregate device needs a real output device as clock source. The built-in
// output is preferred because it has no inputs of its own (so the aggregate exposes
// only the 2 tap channels) and it doesn't disappear when interfaces are unplugged.
static NSString* clockDeviceUID() {
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDevices,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) == noErr && size > 0) {
        std::vector<AudioObjectID> devices(size / sizeof(AudioObjectID));
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, devices.data()) == noErr) {
            for (AudioObjectID dev: devices) {
                AudioObjectPropertyAddress tAddr = { kAudioDevicePropertyTransportType,
                                                     kAudioObjectPropertyScopeGlobal,
                                                     kAudioObjectPropertyElementMain };
                UInt32 transport = 0;
                UInt32 tSize = sizeof(transport);
                if (AudioObjectGetPropertyData(dev, &tAddr, 0, nullptr, &tSize, &transport) != noErr) continue;
                if (transport == kAudioDeviceTransportTypeBuiltIn && hasOutputStreams(dev)) {
                    NSString* uid = deviceUID(dev);
                    if (uid) return uid;
                }
            }
        }
    }
    // fallback: default system output device
    AudioObjectPropertyAddress defAddr = { kAudioHardwarePropertyDefaultSystemOutputDevice,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain };
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 dSize = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defAddr, 0, nullptr, &dSize, &dev) == noErr
            && dev != kAudioObjectUnknown) {
        return deviceUID(dev);
    }
    return nil;
}

static AudioObjectID ownProcessObject() {
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyTranslatePIDToProcessObject,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    pid_t pid = getpid();
    AudioObjectID obj = kAudioObjectUnknown;
    UInt32 size = sizeof(obj);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof(pid), &pid, &size, &obj) != noErr) {
        return kAudioObjectUnknown;
    }
    return obj;
}

#endif  // LUMINOSUS_HAS_PROCESS_TAPS

bool macCreateSystemAudioDevice(QString* errorMessage) {
#if LUMINOSUS_HAS_PROCESS_TAPS
    if (@available(macOS 14.2, *)) {
        if (s_aggregateID != kAudioObjectUnknown) return true;

        @autoreleasepool {
            // 1. Tap of everything that is played on this Mac, except Luminosus itself
            //    (to avoid analysing our own audio playback blocks).
            NSMutableArray<NSNumber*>* exclude = [NSMutableArray array];
            AudioObjectID ownProc = ownProcessObject();
            if (ownProc != kAudioObjectUnknown) [exclude addObject:@(ownProc)];

            CATapDescription* tap = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:exclude];
            tap.name = @"Luminosus System Audio Tap";

            OSStatus err = AudioHardwareCreateProcessTap(tap, &s_tapID);
            if (err != noErr || s_tapID == kAudioObjectUnknown) {
                if (errorMessage) *errorMessage = QString("AudioHardwareCreateProcessTap failed (%1)").arg(err);
                s_tapID = kAudioObjectUnknown;
                return false;
            }

            // 2. Private aggregate device containing the tap. Private means it is only
            //    visible inside Luminosus, so Qt lists it like any other input device.
            NSString* clockUID = clockDeviceUID();
            if (!clockUID) {
                if (errorMessage) *errorMessage = "No output device found to use as clock source.";
                AudioHardwareDestroyProcessTap(s_tapID);
                s_tapID = kAudioObjectUnknown;
                return false;
            }

            NSDictionary* desc = @{
                @kAudioAggregateDeviceNameKey:        @(kSystemAudioDeviceName),
                @kAudioAggregateDeviceUIDKey:         [NSString stringWithFormat:@"org.luminosus.systemaudio.%@", [[NSUUID UUID] UUIDString]],
                @kAudioAggregateDeviceMainSubDeviceKey: clockUID,
                @kAudioAggregateDeviceIsPrivateKey:   @YES,
                @kAudioAggregateDeviceIsStackedKey:   @NO,
                @kAudioAggregateDeviceTapAutoStartKey: @YES,
                @kAudioAggregateDeviceSubDeviceListKey: @[ @{ @kAudioSubDeviceUIDKey: clockUID } ],
                @kAudioAggregateDeviceTapListKey: @[ @{
                    @kAudioSubTapUIDKey: tap.UUID.UUIDString,
                    @kAudioSubTapDriftCompensationKey: @YES,
                } ],
            };

            err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc, &s_aggregateID);
            if (err != noErr || s_aggregateID == kAudioObjectUnknown) {
                if (errorMessage) *errorMessage = QString("AudioHardwareCreateAggregateDevice failed (%1)").arg(err);
                AudioHardwareDestroyProcessTap(s_tapID);
                s_tapID = kAudioObjectUnknown;
                s_aggregateID = kAudioObjectUnknown;
                return false;
            }
        }
        qInfo() << "Created audio input" << macSystemAudioDeviceName() << "(Core Audio process tap).";
        return true;
    }
    if (errorMessage) *errorMessage = "System Audio input requires macOS 14.2 or later.";
    return false;
#else
    if (errorMessage) *errorMessage = "Built with a macOS SDK older than 14.2, System Audio input not available.";
    return false;
#endif
}

void macDestroySystemAudioDevice() {
#if LUMINOSUS_HAS_PROCESS_TAPS
    if (@available(macOS 14.2, *)) {
        if (s_aggregateID != kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(s_aggregateID);
            s_aggregateID = kAudioObjectUnknown;
        }
        if (s_tapID != kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(s_tapID);
            s_tapID = kAudioObjectUnknown;
        }
    }
#endif
}
