#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDraggingSession * _Nullable SukuriniBeginGestureDraggingSession(
    NSView *view,
    NSArray<NSDraggingItem *> *items,
    NSGestureRecognizer *gesture,
    id<NSDraggingSource> source
);

NS_ASSUME_NONNULL_END
