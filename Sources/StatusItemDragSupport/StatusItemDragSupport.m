#import "StatusItemDragSupport.h"

@interface NSView (SukuriniGestureDraggingCompatibility)
- (nullable NSDraggingSession *)beginDraggingSessionWithItems:(NSArray<NSDraggingItem *> *)items
                                                     gesture:(NSGestureRecognizer *)gesture
                                                      source:(id<NSDraggingSource>)source API_AVAILABLE(macos(27.0));
@end

NSDraggingSession * _Nullable SukuriniBeginGestureDraggingSession(
    NSView *view,
    NSArray<NSDraggingItem *> *items,
    NSGestureRecognizer *gesture,
    id<NSDraggingSource> source
) {
    if (@available(macOS 27.0, *)) {
        if ([view respondsToSelector:@selector(beginDraggingSessionWithItems:gesture:source:)]) {
            return [view beginDraggingSessionWithItems:items gesture:gesture source:source];
        }
    }
    return nil;
}
