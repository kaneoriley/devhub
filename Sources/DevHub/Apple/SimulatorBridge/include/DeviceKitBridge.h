#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Load the selected Xcode's native device view. Swift allocates its resilient
/// value using this metadata, so no DeviceKit value layout is copied or assumed.
const void * _Nullable DHDeviceViewMetadata(NSString *developerDirectory, NSError **error);
void DHInitializeDeviceView(void *result, const void *uuid);

NS_ASSUME_NONNULL_END
