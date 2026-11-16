#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
// Owns only the virtual display it creates. Releasing it disconnects that display.
@interface SkyDeskVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithPixelWidth:(uint32_t)width
                                    height:(uint32_t)height
                               refreshRate:(double)refreshRate
                                     error:(NSError **)error;
- (BOOL)activateWithError:(NSError **)error;
- (void)invalidate;
@end
/// Whether the Mac's pointer is showing. Swift marks the underlying call unavailable; it still answers from the
/// WindowServer's shared state for every app (checked on macOS 27: it follows other apps hiding the pointer).
BOOL SkyDeskPointerIsVisible(void);
/// The built-in keyboard's backlight setting, 0 to 1; negative when there is no such keyboard or no way to ask.
float SkyDeskKeyboardBacklight(void);
/// Sets it for now, without saving it as the user's own choice. NO when it could not be set.
BOOL SkyDeskSetKeyboardBacklight(float value);
NS_ASSUME_NONNULL_END
