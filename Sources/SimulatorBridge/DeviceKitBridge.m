#import "DeviceKitBridge.h"
#import <dlfcn.h>

typedef struct { const void *value; uintptr_t state; } DHMetadataResponse;
typedef DHMetadataResponse __attribute__((swiftcall)) (*DHMetadataAccessor)(uintptr_t request);
// Resilient Swift values are returned indirectly; Foundation.UUID is borrowed
// indirectly too. Let Clang lower the Swift calling convention on each platform.
typedef void __attribute__((swiftcall)) (*DHViewInitializer)(void * __attribute__((swift_indirect_result)) result, const void *uuid);
static DHViewInitializer DHInitializer;

const void *DHDeviceViewMetadata(NSString *directory, NSError **error) {
    NSString *path=[[directory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SharedFrameworks/DeviceKit.framework/DeviceKit"];
    void *kit=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
    DHMetadataAccessor metadata=kit?(DHMetadataAccessor)dlsym(kit,"$s9DeviceKit0A4ViewVMa"):NULL;
    DHViewInitializer initializer=kit?(DHViewInitializer)dlsym(kit,"$s9DeviceKit0A4ViewV16deviceIdentifierAC10Foundation4UUIDV_tcfC"):NULL;
    if(!metadata||!initializer) {
        if(error)*error=[NSError errorWithDomain:@"DroidHub.DeviceKit" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This Xcode doesn't provide the native Apple device view. Select a newer Xcode installation with xcode-select."}];
        return NULL;
    }
    DHInitializer=initializer;
    return metadata(0).value;
}

void DHInitializeDeviceView(void *result,const void *uuid) { DHInitializer(result,uuid); }
