#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "DeviceKitBridge.h"
NS_ASSUME_NONNULL_BEGIN

/// Runtime-loaded adapter; no private Xcode framework is linked or bundled.
@interface DHSimulatorBridge : NSObject
@property (nonatomic, copy, nullable) void (^frameHandler)(CVPixelBufferRef buffer, NSInteger orientation, NSInteger screenID);
@property (nonatomic, readonly) NSInteger selectedScreen;
@property (nonatomic, readonly) BOOL modernInput;
@property (nonatomic) BOOL followsActiveDisplays;
@property (nonatomic, getter=isPaused) BOOL paused;
- (nullable instancetype)initWithDeviceID:(NSString *)identifier developerDirectory:(NSString *)directory error:(NSError **)error;
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
- (void)touchAt:(CGPoint)point phase:(NSInteger)phase edge:(NSInteger)edge secondPoint:(nullable NSValue *)secondPoint;
- (void)key:(uint32_t)usage pressed:(BOOL)pressed;
- (void)button:(uint32_t)usage;
- (void)orient:(NSInteger)orientation;
- (void)setFolded:(BOOL)folded;
@property (nonatomic, copy, nullable) void (^errorHandler)(NSString *message);
@end
NS_ASSUME_NONNULL_END
