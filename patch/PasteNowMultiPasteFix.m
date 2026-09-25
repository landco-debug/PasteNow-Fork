#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSCollectionView *PNFindMultiSelectedCollectionView(NSView *view) {
    if ([view isKindOfClass:[NSCollectionView class]]) {
        NSCollectionView *collectionView = (NSCollectionView *)view;
        if (collectionView.selectionIndexPaths.count > 1) {
            return collectionView;
        }
    }
    for (NSView *subview in view.subviews) {
        NSCollectionView *found = PNFindMultiSelectedCollectionView(subview);
        if (found) return found;
    }
    return nil;
}

static id PNFindPasteItemControllerFromResponder(NSResponder *responder) {
    SEL action = NSSelectorFromString(@"onPasteItemsToFrontmostApp:");
    for (NSResponder *current = responder; current; current = current.nextResponder) {
        NSString *name = NSStringFromClass(current.class);
        if ([name hasSuffix:@"PasteItemViewController"] && [current respondsToSelector:action]) {
            return current;
        }
    }
    return nil;
}

static id PNFindPasteItemControllerInTree(NSViewController *controller) {
    if (!controller) return nil;
    SEL action = NSSelectorFromString(@"onPasteItemsToFrontmostApp:");
    NSString *name = NSStringFromClass(controller.class);
    if ([name hasSuffix:@"PasteItemViewController"] && [controller respondsToSelector:action]) {
        return controller;
    }
    for (NSViewController *child in controller.childViewControllers) {
        id found = PNFindPasteItemControllerInTree(child);
        if (found) return found;
    }
    return nil;
}

static BOOL PNHandleMultiPasteEnter(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown) return NO;

    // 36 = Return, 76 = keypad Enter.
    if (event.keyCode != 36 && event.keyCode != 76) return NO;

    NSEventModifierFlags blocked =
        NSEventModifierFlagCommand |
        NSEventModifierFlagControl |
        NSEventModifierFlagOption;
    if ((event.modifierFlags & blocked) != 0) return NO;

    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    NSView *root = window.contentView;
    if (!root) return NO;

    NSCollectionView *collectionView = PNFindMultiSelectedCollectionView(root);
    if (!collectionView) return NO;

    id controller = PNFindPasteItemControllerFromResponder(collectionView);
    if (!controller) {
        controller = PNFindPasteItemControllerInTree(window.contentViewController);
    }
    if (!controller) return NO;

    SEL action = NSSelectorFromString(@"onPasteItemsToFrontmostApp:");
    NSMethodSignature *signature = [controller methodSignatureForSelector:action];
    if (!signature) return NO;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = controller;
    invocation.selector = action;
    id sender = nil;
    [invocation setArgument:&sender atIndex:2];
    [invocation invoke];
    return YES;
}

__attribute__((constructor))
static void PNInstallMultiPasteFix(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                              handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
            return PNHandleMultiPasteEnter(event) ? nil : event;
        }];
        NSLog(@"[PasteNowMultiPasteFix] installed");
    });
}
