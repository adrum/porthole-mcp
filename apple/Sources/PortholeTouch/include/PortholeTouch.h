#import <TargetConditionals.h>
#import <Foundation/Foundation.h>

#if defined(TARGET_OS_VISION) && TARGET_OS_VISION
#define PORTHOLE_VISION 1
#else
#define PORTHOLE_VISION 0
#endif

#if DEBUG && !TARGET_OS_OSX

NS_ASSUME_NONNULL_BEGIN

/// Turn on UIKit's in-process accessibility so SwiftUI builds its element
/// tree, as automation tools do. Returns a description of what was enabled.
NSString *PortholeEnableAccessibilityAutomation(void);

NS_ASSUME_NONNULL_END

#if TARGET_OS_IOS || TARGET_OS_TV || PORTHOLE_VISION
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Type through UIKit's keyboard implementation (what the software
/// keyboard does), so return-key handling and delegates run. Returns NO when
/// the private keyboard API isn't available.
BOOL PortholeKeyboardType(NSString *text);

NS_ASSUME_NONNULL_END
#endif

#if TARGET_OS_IOS || PORTHOLE_VISION

NS_ASSUME_NONNULL_BEGIN

/// One synthesized finger, delivered through UIApplication's real touch
/// pipeline (UITouch + IOHIDEvent), so gesture recognizers see it. Uses
/// private UIKit API; compiled into DEBUG builds only.
@interface PortholeTouchSequence : NSObject

/// Nil when this UIKit doesn't have the private API we need.
+ (nullable NSString *)unavailableReason;

/// Touch down at a point in window coordinates.
- (nullable instancetype)initWithWindow:(UIWindow *)window point:(CGPoint)point;
- (instancetype)init NS_UNAVAILABLE;

- (void)moveTo:(CGPoint)point;
- (void)end;

@end

NS_ASSUME_NONNULL_END
#endif

#endif
