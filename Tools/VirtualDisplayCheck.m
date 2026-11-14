#import <AppKit/AppKit.h>
#import "../Sources/Host/VirtualDisplayBridge.h"

// Exercise the host's AppKit event loop. A nested NSRunLoop alone does not
// deliver AppKit's display-cache invalidation events.
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        dispatch_async(dispatch_get_main_queue(), ^{
            CGDirectDisplayID originalMain = CGMainDisplayID();
            NSError *error = nil;
            __block SkyDeskVirtualDisplay *display = [[SkyDeskVirtualDisplay alloc]
                initWithPixelWidth:2752 height:2064 refreshRate:120 error:&error];
            if (!display) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); exit(1); }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                NSError *activationError = nil;
                if (![display activateWithError:&activationError]) {
                    fprintf(stderr, "%s\n", activationError.localizedDescription.UTF8String); exit(1);
                }
                CGDirectDisplayID identifier = display.displayID;
                __block BOOL valid = NO;
                __block NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
                [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
                    if (!valid) {
                        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(identifier);
                        valid = mode && CGDisplayModeGetPixelWidth(mode) == 2752 && CGDisplayModeGetPixelHeight(mode) == 2064 &&
                            CGDisplayModeGetWidth(mode) == 1376 && CGDisplayModeGetHeight(mode) == 1032 &&
                            CGDisplayModeGetRefreshRate(mode) == 120 && CGMainDisplayID() == originalMain;
                        if (valid) {
                            printf("Retina desktop: %zu x %zu logical, %zu x %zu pixels, %.1f Hz; main display preserved: yes\n",
                                CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode), CGDisplayModeGetPixelWidth(mode),
                                CGDisplayModeGetPixelHeight(mode), CGDisplayModeGetRefreshRate(mode));
                            [display invalidate]; display = nil;
                            deadline = [NSDate dateWithTimeIntervalSinceNow:5];
                        }
                        if (mode) CGDisplayModeRelease(mode);
                    } else {
                        // This macOS returns -1 for a removed ID; testing !IsOnline
                        // incorrectly treats that error value as still online.
                        CGDirectDisplayID online[16]; uint32_t count = 0;
                        CGError result = CGGetOnlineDisplayList(16, online, &count);
                        BOOL present = NO;
                        for (uint32_t i = 0; i < count; i++) if (online[i] == identifier) present = YES;
                        if (result == kCGErrorSuccess && !present) {
                            printf("Virtual display removed: yes\n");
                            [timer invalidate]; exit(0);
                        }
                    }
                    if (deadline.timeIntervalSinceNow <= 0) {
                        fprintf(stderr, "%s\n", valid ? "Virtual display removal timed out." : "Requested Retina mode unavailable.");
                        [display invalidate]; [timer invalidate]; exit(1);
                    }
                }];
            });
        });
        [NSApp run];
    }
    return 1;
}
