#import "VirtualDisplayBridge.h"

// Runtime-only declarations for the private CoreGraphics virtual-display API.
// Kept behind this bridge; an unavailable API fails without changing a physical display.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, serialNum, productID, vendorID;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, strong) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation SkyDeskVirtualDisplay {
    CGVirtualDisplay *_display;
    CGVirtualDisplaySettings *_settings;
}
- (instancetype)initWithPixelWidth:(uint32_t)width height:(uint32_t)height
                       refreshRate:(double)rate error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    NSString *failure = nil;
    @try {
        if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
            failure = @"This macOS version does not provide the virtual display API. Choose Mirror Mac display.";
        } else if (width < 640 || height < 640 || width > 4096 || height > 4096 || width % 2 || height % 2) {
            failure = @"Invalid Retina desktop dimensions.";
        } else {
            CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
            descriptor.queue = dispatch_get_main_queue();
            descriptor.name = @"SkyDesk iPad Retina";
            descriptor.maxPixelsWide = width; descriptor.maxPixelsHigh = height;
            descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 264.0, height * 25.4 / 264.0);
            descriptor.vendorID = 0x534b; descriptor.productID = 0x4950; descriptor.serialNum = 1;
            descriptor.redPrimary = CGPointMake(0.64, 0.33);
            descriptor.greenPrimary = CGPointMake(0.30, 0.60);
            descriptor.bluePrimary = CGPointMake(0.15, 0.06);
            descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
            _display = [[displayClass alloc] initWithDescriptor:descriptor];
            CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
            settings.hiDPI = 1;
            CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width / 2 height:height / 2 refreshRate:rate];
            settings.modes = @[mode];
            _settings = settings;
            if (!_display) {
                failure = @"macOS could not create the iPad Retina desktop. Choose Mirror Mac display to continue.";
            }
        }
    } @catch (NSException *exception) {
        failure = @"The macOS virtual display API rejected this configuration. Choose Mirror Mac display.";
    }
    if (failure) {
        _display = nil;
        if (error) *error = [NSError errorWithDomain:@"SkyDesk.VirtualDisplay" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: failure}];
        return nil;
    }
    return self;
}
- (CGDirectDisplayID)displayID { return _display ? _display.displayID : kCGNullDirectDisplay; }
- (BOOL)activateWithError:(NSError **)error {
    // WindowServer's creation handshake is asynchronous. Call on a later run-loop turn.
    BOOL success = NO;
    @try { success = _display && [_display applySettings:_settings]; } @catch (NSException *exception) { }
    if (!success && error) *error = [NSError errorWithDomain:@"SkyDesk.VirtualDisplay" code:2
        userInfo:@{NSLocalizedDescriptionKey: @"macOS could not activate the iPad Retina display mode."}];
    return success;
}
- (void)invalidate { _display = nil; _settings = nil; }
@end
