#import "PortholeTouch.h"

#if DEBUG && !TARGET_OS_OSX
#import <dlfcn.h>

NSString *PortholeEnableAccessibilityAutomation(void) {
    NSMutableArray<NSString *> *done = [NSMutableArray array];
    if (dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW)) {
        [done addObject:@"AccessibilityUtilities"];
    }
    void *lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
    void (*setAutomation)(int) = lib ? (void (*)(int))dlsym(lib, "_AXSSetAutomationEnabled") : NULL;
    if (setAutomation) {
        setAutomation(1);
        [done addObject:@"automation"];
    }
    return done.count ? [done componentsJoinedByString:@", "] : @"nothing (accessibility libraries not found)";
}
#endif

#if DEBUG && (TARGET_OS_IOS || PORTHOLE_VISION)
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

typedef IOHIDEventRef (*AUCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t type, uint32_t index, uint32_t identity,
                                                uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                                IOHIDFloat tipPressure, IOHIDFloat barrelPressure, Boolean range, Boolean touch,
                                                uint32_t options);
typedef IOHIDEventRef (*AUCreateFingerEvent)(CFAllocatorRef, uint64_t, uint32_t index, uint32_t identity, uint32_t eventMask,
                                             IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
                                             IOHIDFloat minorRadius, IOHIDFloat majorRadius, IOHIDFloat quality, IOHIDFloat density,
                                             IOHIDFloat irregularity, Boolean range, Boolean touch, uint32_t options);
typedef void (*AUSetIntegerValue)(IOHIDEventRef, uint32_t field, long value);
typedef void (*AUAppendEvent)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);

enum {
    AUTransducerTypeHand = 3,
    AUDigitizerEventRange = 1 << 0,
    AUDigitizerEventTouch = 1 << 1,
    AUDigitizerEventPosition = 1 << 2,
    AUEventTypeDigitizer = 11,
    // IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) + kIOHIDEventFieldDigitizerIsDisplayIntegrated
    AUFieldDigitizerIsDisplayIntegrated = (AUEventTypeDigitizer << 16) | 25,
};

static AUCreateDigitizerEvent createDigitizer;
static AUCreateFingerEvent createFinger;
static AUSetIntegerValue setIntegerValue;
static AUAppendEvent appendEvent;

static BOOL loadIOKit(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        createDigitizer = (AUCreateDigitizerEvent)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        createFinger = (AUCreateFingerEvent)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        setIntegerValue = (AUSetIntegerValue)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        appendEvent = (AUAppendEvent)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        loaded = createDigitizer && createFinger && setIntegerValue && appendEvent;
    });
    return loaded;
}

@interface UITouch (PortholePrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setPhase:(UITouchPhase)phase;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)setIsTap:(BOOL)isTap;
- (void)setTapCount:(NSUInteger)count;
- (void)_setHidEvent:(IOHIDEventRef)event;
- (void)setGestureView:(UIView *)view;
- (void)_setIsTapToClick:(BOOL)value;
@end

@interface UIApplication (PortholePrivate)
- (UIEvent *)_touchesEvent;
@end

@interface UIEvent (PortholePrivate)
- (void)_clearTouches;
- (void)_setHIDEvent:(IOHIDEventRef)event;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
@end

static IOHIDEventRef makeHIDEvent(UITouch *touch) {
    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = createDigitizer(kCFAllocatorDefault, now, AUTransducerTypeHand, 0, 0,
                                         AUDigitizerEventTouch, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    setIntegerValue(hand, AUFieldDigitizerIsDisplayIntegrated, 1);
    BOOL moved = touch.phase == UITouchPhaseMoved || touch.phase == UITouchPhaseStationary;
    uint32_t mask = moved ? AUDigitizerEventPosition : (AUDigitizerEventRange | AUDigitizerEventTouch);
    Boolean touching = touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
    CGPoint p = [touch locationInView:touch.window];
    IOHIDEventRef finger = createFinger(kCFAllocatorDefault, now, 1, 2, mask, p.x, p.y, 0, touching ? 1 : 0, 0,
                                        5, 5, 1, 1, 1, touching, touching, 0);
    setIntegerValue(finger, AUFieldDigitizerIsDisplayIntegrated, 1);
    appendEvent(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

@implementation PortholeTouchSequence {
    UITouch *_touch;
}

+ (NSString *)unavailableReason {
    if (!loadIOKit()) {
        return @"IOKit HID event functions are not available";
    }
    NSArray<NSString *> *touchSelectors = @[@"setWindow:", @"setView:", @"setPhase:", @"_setLocationInWindow:resetPrevious:",
                                            @"setTimestamp:", @"setTapCount:", @"_setHidEvent:"];
    for (NSString *s in touchSelectors) {
        if (![UITouch instancesRespondToSelector:NSSelectorFromString(s)]) {
            return [NSString stringWithFormat:@"UITouch lacks %@", s];
        }
    }
    if (![UIApplication instancesRespondToSelector:@selector(_touchesEvent)]) {
        return @"UIApplication lacks _touchesEvent";
    }
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    for (NSString *s in @[@"_clearTouches", @"_setHIDEvent:", @"_addTouch:forDelayedDelivery:"]) {
        if (![event respondsToSelector:NSSelectorFromString(s)]) {
            return [NSString stringWithFormat:@"UITouchesEvent lacks %@", s];
        }
    }
    return nil;
}

- (instancetype)initWithWindow:(UIWindow *)window point:(CGPoint)point {
    if ([PortholeTouchSequence unavailableReason] != nil) {
        return nil;
    }
    self = [super init];
    if (!self) return nil;
    UITouch *t = [[UITouch alloc] init];
    [t setWindow:window];
    [t setTapCount:1];
    [t _setLocationInWindow:point resetPrevious:YES];
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    [t setView:hit];
    [t setPhase:UITouchPhaseBegan];
    if ([t respondsToSelector:@selector(_setIsTapToClick:)]) [t _setIsTapToClick:NO];
    if ([t respondsToSelector:@selector(_setIsFirstTouchForView:)]) [t _setIsFirstTouchForView:YES];
    if ([t respondsToSelector:@selector(setIsTap:)]) [t setIsTap:YES];
    if ([t respondsToSelector:@selector(setGestureView:)]) [t setGestureView:hit];
    [t setTimestamp:[NSProcessInfo processInfo].systemUptime];
    _touch = t;
    [self deliver];
    return self;
}

- (void)deliver {
    IOHIDEventRef hid = makeHIDEvent(_touch);
    [_touch _setHidEvent:hid];
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];
    [event _setHIDEvent:hid];
    [event _addTouch:_touch forDelayedDelivery:NO];
    [[UIApplication sharedApplication] sendEvent:event];
    CFRelease(hid);
}

- (void)moveTo:(CGPoint)point {
    if ([_touch respondsToSelector:@selector(setIsTap:)]) [_touch setIsTap:NO];
    [_touch setPhase:UITouchPhaseMoved];
    [_touch _setLocationInWindow:point resetPrevious:NO];
    [_touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
    [self deliver];
}

- (void)end {
    [_touch setPhase:UITouchPhaseEnded];
    [_touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
    [self deliver];
}

@end

#endif

#if DEBUG && (TARGET_OS_IOS || TARGET_OS_TV || PORTHOLE_VISION)
@interface AUKeyboardImpl : NSObject
+ (instancetype)activeInstance;
+ (instancetype)sharedInstance;
- (void)addInputString:(NSString *)string;
- (id)taskQueue;
@end

@interface AUTaskQueue : NSObject
- (void)waitUntilAllTasksAreFinished;
@end

BOOL PortholeKeyboardType(NSString *text) {
    Class cls = NSClassFromString(@"UIKeyboardImpl");
    if (!cls) return NO;
    AUKeyboardImpl *kb = nil;
    if ([cls respondsToSelector:@selector(activeInstance)]) kb = [(id)cls activeInstance];
    if (!kb && [cls respondsToSelector:@selector(sharedInstance)]) kb = [(id)cls sharedInstance];
    if (!kb || ![kb respondsToSelector:@selector(addInputString:)]) return NO;
    [kb addInputString:text];
    if ([kb respondsToSelector:@selector(taskQueue)]) {
        id queue = [kb taskQueue];
        if ([queue respondsToSelector:@selector(waitUntilAllTasksAreFinished)]) {
            [(AUTaskQueue *)queue waitUntilAllTasksAreFinished];
        }
    }
    return YES;
}

#endif
