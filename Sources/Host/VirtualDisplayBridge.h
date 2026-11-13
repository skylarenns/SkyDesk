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
NS_ASSUME_NONNULL_END
