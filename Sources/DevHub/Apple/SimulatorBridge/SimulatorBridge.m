#import "SimulatorBridge.h"
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFSerialize.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#import <os/log.h>

// CoreSimulator / SimulatorKit runtime declarations. Protocol signatures and HID
// wire keys verified against Xcode and Meta's MIT-licensed idb (see NOTICE).
@interface NSObject (DHSimulatorAPI)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)directory error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSUUID *)UDID;
- (id)deviceType;
- (NSDictionary *)capabilities;
- (id)io;
- (NSArray *)ioPorts;
- (id)descriptor;
- (id)screenProperties;
- (unsigned int)screenID;
- (unsigned int)uiOrientation;
- (id)framebufferSurface;
- (id)maskedFramebufferSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid callbackQueue:(dispatch_queue_t)queue frameCallback:(void (^)(void))frame surfacesChangedCallback:(void (^)(id,id))surfaces propertiesChangedCallback:(void (^)(id))properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(id))callback;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)registerCallbackWithUUID:(NSUUID *)uuid damageRectanglesCallback:(void (^)(id))callback;
- (void)unregisterDamageRectanglesCallbackWithUUID:(NSUUID *)uuid;
- (mach_port_t)lookup:(NSString *)service error:(NSError **)error;
- (id)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message freeWhenDone:(BOOL)free completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end

static NSError *DHError(NSString *message) { return [NSError errorWithDomain:@"DevHub.Simulator" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static os_log_t DHInputLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once,^{log=os_log_create("com.kaneoriley.devhub.simulator","Input");});
    return log;
}
static BOOL DHSurfaceHasContent(id object) {
    if(!object || CFGetTypeID((__bridge CFTypeRef)object)!=IOSurfaceGetTypeID())return NO;
    IOSurfaceRef surface=(__bridge IOSurfaceRef)object;
    if(IOSurfaceGetBytesPerElement(surface)!=4 || IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL)!=kIOReturnSuccess)return NO;
    const uint8_t *base=IOSurfaceGetBaseAddress(surface);size_t width=IOSurfaceGetWidth(surface),height=IOSurfaceGetHeight(surface),stride=IOSurfaceGetBytesPerRow(surface);
    BOOL visible=NO;
    if(base&&width&&height)for(size_t y=1;y<8&&!visible;y++)for(size_t x=1;x<8;x++){
        const uint8_t *pixel=base+(height*y/8)*stride+(width*x/8)*4;
        if(pixel[0]||pixel[1]||pixel[2]){visible=YES;break;}
    }
    IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);return visible;
}
static xpc_object_t DHDictionary(NSDictionary *values) {
    xpc_object_t result=xpc_dictionary_create(NULL,NULL,0);
    for(NSString *key in values) {
        id value=values[key]; const char *k=key.UTF8String;
        if([value isKindOfClass:NSString.class]) xpc_dictionary_set_string(result,k,[value UTF8String]);
        else if([value isKindOfClass:NSDictionary.class]) xpc_dictionary_set_value(result,k,DHDictionary(value));
        else if([value isKindOfClass:NSData.class]) xpc_dictionary_set_data(result,k,[value bytes],[value length]);
        else if(CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) xpc_dictionary_set_bool(result,k,[value boolValue]);
        else if(CFNumberIsFloatType((__bridge CFNumberRef)value)) xpc_dictionary_set_double(result,k,[value doubleValue]);
        else xpc_dictionary_set_uint64(result,k,[value unsignedLongLongValue]);
    }
    return result;
}

@interface DHSimChannel : NSObject
@property xpc_connection_t connection;
@property NSString *service;
@property BOOL valid;
@end
@implementation DHSimChannel
- (void)dealloc { if(_connection)xpc_connection_cancel(_connection); }
@end

@interface DHSimScreen : NSObject
@property id descriptor;
@property id surface;
@property id masked;
@property NSInteger identifier;
@property NSInteger orientation;
@property NSUUID *token;
@property BOOL modern;
@end
@implementation DHSimScreen @end

@interface DHSimulatorBridge ()
@property id device;
@property id legacyInput;
@property NSMutableArray<DHSimScreen *> *screens;
@property NSMutableDictionary<NSString *,DHSimChannel *> *channels;
@property dispatch_queue_t queue;
@property dispatch_queue_t inputQueue;
@property BOOL stopped;
@property BOOL touching;
@property NSDictionary<NSNumber *,NSNumber *> *nativeRotations;
@property (readwrite) NSInteger selectedScreen;
@property (readwrite) BOOL modernInput;
@end

@implementation DHSimulatorBridge
- (instancetype)initWithDeviceID:(NSString *)identifier developerDirectory:(NSString *)directory error:(NSError **)error {
    if(!(self=[super init]))return nil;
    _queue=dispatch_queue_create("com.kaneoriley.devhub.simulator",DISPATCH_QUEUE_SERIAL);
    _inputQueue=dispatch_queue_create("com.kaneoriley.devhub.simulator.input",DISPATCH_QUEUE_SERIAL);
    _screens=[NSMutableArray array]; _channels=[NSMutableDictionary dictionary]; _selectedScreen=-1;
    @try {
        void *core=dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",RTLD_NOW|RTLD_GLOBAL);
        NSString *kit=[[directory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
        if(!core || !dlopen(kit.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) {
            if(error)*error=DHError(@"Couldn't load Xcode's simulator frameworks. Select a full Xcode installation with xcode-select."); return nil;
        }
        Class cls=NSClassFromString(@"SimServiceContext");
        if(![cls respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)]) { if(error)*error=DHError(@"This Xcode's simulator interface is unsupported.");return nil; }
        id context=[cls sharedServiceContextForDeveloperDir:directory error:error];
        id set=[context defaultDeviceSetWithError:error];
        for(id candidate in [set availableDevices])if([[[candidate UDID] UUIDString] caseInsensitiveCompare:identifier]==NSOrderedSame){_device=candidate;break;}
        if(!_device){if(error)*error=DHError(@"The simulator is no longer available.");return nil;}
        NSMutableDictionary *rotations=[NSMutableDictionary dictionary];
        id type=[_device deviceType];
        if([type respondsToSelector:@selector(capabilities)]) {
            NSDictionary *capabilities=[type capabilities][@"capabilities"];
            for(NSDictionary *display in capabilities[@"displays"]) {
                NSNumber *identifier=display[@"screenID"], *rotation=display[@"nativeRotation"]?:display[@"nativeOrientation"];
                if([identifier isKindOfClass:NSNumber.class]&&[rotation isKindOfClass:NSNumber.class])rotations[identifier]=rotation;
            }
        }
        _nativeRotations=[rotations copy];
    } @catch(NSException *e) {if(error)*error=DHError(e.reason);return nil;}
    return self;
}
- (BOOL)startWithError:(NSError **)error {
    @try {
        for(id port in [[_device io] ioPorts]) {
            id descriptor=[port descriptor];
            if(![descriptor respondsToSelector:@selector(framebufferSurface)])continue;
            id surface=[descriptor framebufferSurface];
            if(!surface)continue;
            DHSimScreen *screen=[DHSimScreen new]; screen.descriptor=descriptor;screen.surface=surface;
            screen.masked=[descriptor respondsToSelector:@selector(maskedFramebufferSurface)]?[descriptor maskedFramebufferSurface]:nil;
            id props=[descriptor screenProperties]; screen.identifier=[props screenID];screen.orientation=[props uiOrientation];screen.token=[NSUUID UUID];
            [_screens addObject:screen];
        }
        [_screens sortUsingComparator:^NSComparisonResult(DHSimScreen *a,DHSimScreen *b){return [@(a.identifier) compare:@(b.identifier)];}];
        if(!_screens.count){if(error)*error=DHError(@"The simulator has no display yet. Wait for it to finish booting, then retry.");return NO;}
        _selectedScreen=_screens.firstObject.identifier;
        if(_followsActiveDisplays)for(DHSimScreen *s in _screens)if(DHSurfaceHasContent(s.surface)){_selectedScreen=s.identifier;break;}
        __weak DHSimulatorBridge *weakSelf=self;
        dispatch_queue_t callbackQueue=_queue;
        for(DHSimScreen *screen in _screens) {
            if([screen.descriptor respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)]) {
                screen.modern=YES;
                [screen.descriptor registerScreenCallbacksWithUUID:screen.token callbackQueue:_queue frameCallback:^{[weakSelf deliver:screen];} surfacesChangedCallback:^(id raw,id masked){screen.surface=raw;screen.masked=masked;[weakSelf deliver:screen];} propertiesChangedCallback:^(id props){screen.orientation=[props uiOrientation];[weakSelf deliver:screen];}];
            } else {
                [screen.descriptor registerCallbackWithUUID:screen.token ioSurfacesChangeCallback:^(id surface){dispatch_async(callbackQueue,^{screen.surface=surface;[weakSelf deliver:screen];});}];
                [screen.descriptor registerCallbackWithUUID:screen.token damageRectanglesCallback:^(id ignored){dispatch_async(callbackQueue,^{[weakSelf deliver:screen];});}];
            }
        }
        for(DHSimScreen *screen in _screens)[self deliver:screen];
        // Rendering must not wait for guest HID daemons. Input events queued by
        // the user stay ordered behind this preparation on a separate queue.
        dispatch_async(_inputQueue,^{[self prepareInput];});
        return YES;
    } @catch(NSException *e) {if(error)*error=DHError(e.reason);[self stop];return NO;}
}
- (void)prepareInput {
    CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
    if(_stopped)return;
    @try {
        // Indigo multiplexes touch, keys, buttons and VM controls on one peer.
        // Each extra peer creates another full virtual HID device set in iOS.
        // Besides wasting time, parallel peers can time out during cold startup.
        _modernInput=!_prefersLegacyInput && [self channel:@"digitizer"]!=nil;
        if(_stopped)return;
        if(!_modernInput) {
            NSError *error=nil;
            Class legacy=NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient")?:NSClassFromString(@"SimDeviceLegacyHIDClient");
            if(legacy)_legacyInput=[[legacy alloc] initWithDevice:_device error:&error];
            if(!_legacyInput && _errorHandler)_errorHandler(error.localizedDescription?:@"Couldn't connect to simulator input. Retry once the simulator is fully booted.");
        }
        os_log_debug(DHInputLog(),"Input preparation %.3fs, modern=%d",CFAbsoluteTimeGetCurrent()-began,_modernInput);
    } @catch(NSException *e) {if(_errorHandler)_errorHandler(e.reason);}
}
- (void)setPaused:(BOOL)paused {
    if(_paused==paused)return;
    _paused=paused;
    if(!paused)dispatch_async(_queue,^{for(DHSimScreen *screen in self.screens)[self deliver:screen];});
}
- (void)deliver:(DHSimScreen *)screen {
    if(_stopped||_paused)return;
    if(_followsActiveDisplays && screen.identifier!=_selectedScreen && DHSurfaceHasContent(screen.surface)) {
        DHSimScreen *current=nil;for(DHSimScreen *s in _screens)if(s.identifier==_selectedScreen){current=s;break;}
        if(!DHSurfaceHasContent(current.surface)) {
            _selectedScreen=screen.identifier;
            os_log_debug(DHInputLog(),"Active display changed to %ld",(long)_selectedScreen);
        }
    }
    void (^handler)(CVPixelBufferRef,NSInteger,NSInteger)=self.frameHandler;
    if(_stopped||screen.identifier!=_selectedScreen||!screen.surface||!handler)return;
    IOSurfaceRef surface=(__bridge IOSurfaceRef)(screen.masked?:screen.surface);
    if(CFGetTypeID(surface)!=IOSurfaceGetTypeID())return;
    CVPixelBufferRef pixel=NULL;
    if(CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault,surface,NULL,&pixel)!=kCVReturnSuccess)return;
    handler(pixel,screen.orientation,screen.identifier);
    CVPixelBufferRelease(pixel);
}
- (void)stop {
    if(_stopped)return;
    _stopped=YES;
    _frameHandler=nil;_errorHandler=nil;
    dispatch_async(_queue,^{[self cleanupScreens];});
    dispatch_async(_inputQueue,^{[self cleanupInput];});
}
- (void)cleanupScreens {
    for(DHSimScreen *s in _screens) { @try {
        if(s.modern)[s.descriptor unregisterScreenCallbacksWithUUID:s.token];
        else {[s.descriptor unregisterIOSurfacesChangeCallbackWithUUID:s.token];[s.descriptor unregisterDamageRectanglesCallbackWithUUID:s.token];}
    } @catch(NSException *e) {} }
    [_screens removeAllObjects];_frameHandler=nil;
}
- (void)cleanupInput {
    NSArray<DHSimChannel *> *channels;
    @synchronized(_channels) {channels=_channels.allValues;[_channels removeAllObjects];}
    for(DHSimChannel *channel in channels)if(channel.connection)xpc_connection_cancel(channel.connection);
    _legacyInput=nil;
}
- (void)dealloc { if(!_stopped){[self cleanupScreens];[self cleanupInput];} }
- (DHSimChannel *)channel:(NSString *)suffix {
    if(_stopped)return nil;
    @synchronized(_channels) {
        DHSimChannel *existing=_channels[suffix];if(existing.valid)return existing;
        if(existing)[_channels removeObjectForKey:suffix];
    }
    CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
    os_log_debug(DHInputLog(),"Connecting %{public}@",suffix);
    // _4sim's two extra endpoint arguments must be initialized. Declaring this
    // as a one-argument function leaves caller-register garbage in both slots.
    // Signature verified against idb's SimulatorXPCConnector (see integration docs).
    typedef xpc_endpoint_t (*Endpoint)(mach_port_t,uint64_t,uint64_t) __attribute__((ns_returns_retained));
    typedef void (*Enable)(xpc_connection_t);
    Endpoint endpoint=(Endpoint)dlsym(RTLD_DEFAULT,"xpc_endpoint_create_mach_port_4sim");
    Enable enable=(Enable)dlsym(RTLD_DEFAULT,"xpc_connection_enable_sim2host_4sim");
    if(!endpoint||!enable)return nil;
    NSString *service=[@"com.apple.coredevice.feature.remote.hid." stringByAppendingString:suffix];
    NSError *error=nil; mach_port_t port=[_device lookup:service error:&error];if(!port)return nil;
    // Create returns +1 and consumes the lookup's send right. ARC owns the
    // endpoint; manually deallocating that right later can invalidate a reused port.
    xpc_endpoint_t ep=endpoint(port,0,0);if(!ep)return nil;
    xpc_connection_t connection=xpc_connection_create_from_endpoint(ep);if(!connection)return nil;
    DHSimChannel *channel=[DHSimChannel new];channel.service=service;channel.connection=connection;channel.valid=YES;
    dispatch_queue_t events=dispatch_queue_create("com.kaneoriley.devhub.simulator.xpc",DISPATCH_QUEUE_SERIAL);
    xpc_connection_set_target_queue(connection,events);
    __weak DHSimChannel *weakChannel=channel;
    xpc_connection_set_event_handler(connection,^(xpc_object_t event){if(event==XPC_ERROR_CONNECTION_INVALID)weakChannel.valid=NO;});
    enable(connection);xpc_connection_resume(connection);
    // A round-trip establishes a live daemon before accepting input.
    dispatch_semaphore_t reply=dispatch_semaphore_create(0); __block BOOL alive=NO;
    xpc_object_t probe=DHDictionary(@{@"messageType":@"IndigoKeyboardButtonEvent",@"isBarrier":@YES,@"featureIdentifier":service,@"payload":@{@"usageCode":@0,@"state":@2}});
    xpc_connection_send_message_with_reply(connection,probe,events,^(xpc_object_t result){alive=xpc_get_type(result)!=XPC_TYPE_ERROR;dispatch_semaphore_signal(reply);});
    if(dispatch_semaphore_wait(reply,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))||!alive){
        os_log_debug(DHInputLog(),"Connection failed %{public}@ after %.3fs",suffix,CFAbsoluteTimeGetCurrent()-began);
        xpc_connection_cancel(connection);return nil;
    }
    [NSThread sleepForTimeInterval:0.2]; // The guest opens its HID device after replying.
    if(_stopped){xpc_connection_cancel(connection);return nil;}
    @synchronized(_channels) {
        if(_stopped){xpc_connection_cancel(connection);return nil;}
        _channels[suffix]=channel;
    }
    os_log_debug(DHInputLog(),"Connected %{public}@ after %.3fs",suffix,CFAbsoluteTimeGetCurrent()-began);
    return channel;
}
- (BOOL)send:(NSString *)type payload:(NSDictionary *)payload service:(NSString *)service {
    DHSimChannel *channel=[self channel:service];
    if(!channel){if(_errorHandler)_errorHandler(@"Simulator input disconnected. Try the action again.");return NO;}
    xpc_connection_send_message(channel.connection,DHDictionary(@{@"messageType":type,@"isBarrier":@NO,@"featureIdentifier":channel.service,@"payload":payload}));
    return YES;
}
- (void)legacy:(void *)message {
    if(!message)return;
    @try {[_legacyInput sendWithMessage:message freeWhenDone:YES completionQueue:_inputQueue completion:^(NSError *error){if(error&&self.errorHandler)self.errorHandler(error.localizedDescription);}];}
    @catch(NSException *e){free(message);if(_errorHandler)_errorHandler(e.reason);}
}
- (void)touchAt:(CGPoint)point phase:(NSInteger)phase edge:(NSInteger)edge secondPoint:(NSValue *)second {
    dispatch_async(_inputQueue,^{if(self.stopped)return;
        if(self.modernInput){
            NSMutableDictionary *p=[@{@"pointOne":@{@"x":@(point.x),@"y":@(point.y)},@"eventType":@(phase),@"edge":@(edge),@"target":@(self.selectedScreen==1?0:self.selectedScreen)} mutableCopy];
            if(second){CGPoint v=second.pointValue;p[@"pointTwo"]=@{@"x":@(v.x),@"y":@(v.y)};}
            [self send:@"IndigoDigitizerEvent" payload:p service:@"digitizer"];
        }else{
            typedef void *(*Builder)(CGPoint *,CGPoint *,uint32_t,NSUInteger,CGSize,uint32_t);
            Builder builder=(Builder)dlsym(RTLD_DEFAULT,"IndigoHIDMessageForMouseNSEvent");
            if(builder){CGPoint p=point,p2=second.pointValue;[self legacy:builder(&p,second?&p2:NULL,0x32,phase==2?NSEventTypeLeftMouseUp:phase==0?NSEventTypeLeftMouseDown:NSEventTypeLeftMouseDragged,CGSizeMake(1,1),(uint32_t)edge)];}
        }
    });
}
- (void)key:(uint32_t)usage pressed:(BOOL)pressed {
    dispatch_async(_inputQueue,^{if(self.stopped)return;
        if(self.modernInput)[self send:@"IndigoKeyboardButtonEvent" payload:@{@"usageCode":@(usage),@"state":@(pressed?1:2)} service:@"digitizer"];
        else{typedef void *(*Builder)(int,int);Builder fn=(Builder)dlsym(RTLD_DEFAULT,"IndigoHIDMessageForKeyboardArbitrary");if(fn)[self legacy:fn(usage,pressed?1:2)];}
    });
}
- (void)button:(uint32_t)usage {
    dispatch_async(_inputQueue,^{if(self.stopped)return;
        for(int state=1;state<=2;state++){
            if(self.modernInput)[self send:@"IndigoButtonEvent" payload:@{@"usagePage":@12,@"usageCode":@(usage),@"state":@(state)} service:@"digitizer"];
            else{typedef void *(*Builder)(int,uint32_t,uint32_t,int);Builder fn=(Builder)dlsym(RTLD_DEFAULT,"IndigoHIDMessageForHIDArbitrary");if(fn)[self legacy:fn(0x32,12,usage,state)];}
        }
    });
}
- (void)vendorSource:(NSString *)source type:(NSString *)type value:(id)value {
    CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
    CFDataRef data=IOCFSerialize((__bridge CFDictionaryRef)@{@"provider":@"com.apple.Virtualization.VirtualMachines",@"source":source,@"type":type,@"value":value},1);
    if(!data)return;
    BOOL sent=[self send:@"IndigoVendorDefinedEvent" payload:@{@"usagePage":@0xff61,@"usage":@0x5b,@"version":@0,@"data":CFBridgingRelease(data)} service:@"digitizer"];
    os_log_debug(DHInputLog(),"Vendor event %{public}@ dispatched=%d in %.3fs",source,sent,CFAbsoluteTimeGetCurrent()-began);
}
- (void)orient:(NSInteger)orientation {
    dispatch_async(_inputQueue,^{
    if(self.stopped)return;
    // Legacy runtimes consume GraphicsServices; motion-enabled runtimes consume
    // the vendor report. The former is ignored by motion-enabled runtimes.
        mach_port_t port=[self.device lookup:@"PurpleWorkspacePort" error:nil];
        if(port) {
        uint8_t bytes[112]={0};mach_msg_header_t *header=(mach_msg_header_t *)bytes;
        header->msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);header->msgh_size=108;header->msgh_remote_port=port;header->msgh_id=0x7b;
        uint32_t event=50|0x20000, length=4, value=(uint32_t)(orientation==3?4:orientation==4?3:orientation);
        memcpy(bytes+0x18,&event,4);memcpy(bytes+0x48,&length,4);memcpy(bytes+0x4c,&value,4);
        kern_return_t status=mach_msg(header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,header->msgh_size,0,MACH_PORT_NULL,250,MACH_PORT_NULL);
        mach_port_deallocate(mach_task_self(),port);
        if(status!=KERN_SUCCESS&&self.errorHandler)self.errorHandler(@"The simulator couldn't rotate. Retry its screen.");
        }
    if(self.modernInput) {
        NSString *value=@{@1:@"portrait",@2:@"pud",@3:@"landscape-right",@4:@"landscape-left"}[@(orientation)];
        if(value)[self vendorSource:@"orientation-picker-control" type:@"enum" value:value];
    }
    });
}
- (NSInteger)nativeRotationForScreen:(NSInteger)screenID { return [_nativeRotations[@(screenID)] integerValue]; }
- (void)setFolded:(BOOL)folded {
    CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
    dispatch_async(_inputQueue,^{
        if(self.stopped)return;
        os_log_debug(DHInputLog(),"Fold command queue wait %.3fs",CFAbsoluteTimeGetCurrent()-began);
        [self vendorSource:@"hinge-slider-control" type:@"range" value:@(folded?0.0:180.0)];
    });
}
@end
