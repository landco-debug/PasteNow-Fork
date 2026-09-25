#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <objc/runtime.h>

typedef BOOL (*PNWriteObjectsIMP)(NSPasteboard *, SEL, NSArray *);
static PNWriteObjectsIMP PNOriginalWriteObjects = NULL;

static BOOL PNArmed = NO;
static BOOL PNBatchingImages = NO;
static NSUInteger PNExpectedItems = 0;
static NSUInteger PNSeenItems = 0;
static NSUInteger PNGeneration = 0;
static NSMutableArray *PNBatchObjects = nil;
static NSArray *PNCompletedBatchHold = nil;
static id PNEventMonitor = nil;

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

static BOOL PNIsPlainEnter(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown || event.isARepeat) return NO;
    if (event.keyCode != 36 && event.keyCode != 76) return NO; // Return / keypad Enter

    NSEventModifierFlags semantic =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    semantic &= ~(NSEventModifierFlagCapsLock |
                  NSEventModifierFlagNumericPad |
                  NSEventModifierFlagFunction);
    return semantic == 0;
}

static BOOL PNIsGeneralPasteboard(NSPasteboard *pasteboard) {
    return [pasteboard.name isEqualToString:NSPasteboardNameGeneral];
}

static BOOL PNWriterContainsImage(id object, NSPasteboard *pasteboard) {
    if ([object isKindOfClass:[NSImage class]]) return YES;

    NSArray<NSPasteboardType> *types = nil;
    if ([object isKindOfClass:[NSPasteboardItem class]]) {
        types = ((NSPasteboardItem *)object).types;
    } else if ([object respondsToSelector:@selector(writableTypesForPasteboard:)]) {
        types = [(id<NSPasteboardWriting>)object writableTypesForPasteboard:pasteboard];
    }

    for (NSPasteboardType type in types) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeImage)) {
#pragma clang diagnostic pop
            return YES;
        }
    }
    return NO;
}

static void PNResetBatch(BOOL releaseCompletedHold) {
    PNArmed = NO;
    PNBatchingImages = NO;
    PNExpectedItems = 0;
    PNSeenItems = 0;
    PNBatchObjects = nil;
    if (releaseCompletedHold) {
        PNCompletedBatchHold = nil;
    }
}

static void PNArmBatch(NSUInteger selectedCount) {
    PNGeneration += 1;
    PNArmed = YES;
    PNBatchingImages = NO;
    PNExpectedItems = selectedCount;
    PNSeenItems = 0;
    PNBatchObjects = [NSMutableArray arrayWithCapacity:selectedCount];
    PNCompletedBatchHold = nil;

    NSUInteger generation = PNGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (PNGeneration == generation && PNArmed) {
            NSLog(@"[PasteNowMultiPasteFix] timeout after %lu/%lu pasteboard items",
                  (unsigned long)PNSeenItems, (unsigned long)PNExpectedItems);
            PNResetBatch(NO);
        }
    });
}

static void PNFinishBatch(void) {
    PNCompletedBatchHold = [PNBatchObjects copy];
    PNArmed = NO;
    PNBatchingImages = NO;
    PNExpectedItems = 0;
    PNSeenItems = 0;
    PNBatchObjects = nil;

    NSUInteger generation = PNGeneration;
    NSArray *hold = PNCompletedBatchHold;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (PNGeneration == generation && PNCompletedBatchHold == hold) {
            PNCompletedBatchHold = nil;
        }
    });
}

static BOOL PNWriteObjects(NSPasteboard *pasteboard, SEL _cmd, NSArray *objects) {
    if (!PNOriginalWriteObjects) return NO;

    if (!PNArmed ||
        !PNIsGeneralPasteboard(pasteboard) ||
        objects.count == 0) {
        return PNOriginalWriteObjects(pasteboard, _cmd, objects);
    }

    // The stock 2.32 Enter path already passes the whole collection selection
    // downstream. The bug happens later: for ordinary apps it calls
    // -writeObjects: once per selected item. AppKit requires a fresh
    // clearContents before a new write, so only the first image survives.
    //
    // Do not touch non-image multi-selections: wait for the first writer and
    // arm batching only if it is an image writer.
    if (!PNBatchingImages) {
        id first = objects.firstObject;
        if (!PNWriterContainsImage(first, pasteboard)) {
            PNResetBatch(NO);
            return PNOriginalWriteObjects(pasteboard, _cmd, objects);
        }

        PNBatchingImages = YES;
        [PNBatchObjects addObjectsFromArray:objects];
        PNSeenItems += objects.count;

        BOOL ok = PNOriginalWriteObjects(pasteboard, _cmd, objects);
        if (!ok) {
            [pasteboard clearContents];
            ok = PNOriginalWriteObjects(pasteboard, _cmd, objects);
        }

        if (PNSeenItems >= PNExpectedItems) {
            PNFinishBatch();
        }
        return ok;
    }

    [PNBatchObjects addObjectsFromArray:objects];
    PNSeenItems += objects.count;

    // Rebuild the pasteboard from the retained writer objects. This is
    // synchronous, so by the time PasteNow sends Cmd+V the general pasteboard
    // contains one NSPasteboard item per selected image, in selection order.
    [pasteboard clearContents];
    BOOL ok = PNOriginalWriteObjects(pasteboard, _cmd, PNBatchObjects);

    NSLog(@"[PasteNowMultiPasteFix] batched %lu/%lu image items (write=%@)",
          (unsigned long)PNSeenItems,
          (unsigned long)PNExpectedItems,
          ok ? @"OK" : @"FAILED");

    if (PNSeenItems >= PNExpectedItems) {
        PNFinishBatch();
    }
    return ok;
}

static void PNInstallPasteboardHook(void) {
    Method method = class_getInstanceMethod([NSPasteboard class], @selector(writeObjects:));
    if (!method) {
        NSLog(@"[PasteNowMultiPasteFix] writeObjects: method not found");
        return;
    }

    PNOriginalWriteObjects = (PNWriteObjectsIMP)method_getImplementation(method);
    method_setImplementation(method, (IMP)PNWriteObjects);
}

static void PNInstallEnterMonitor(void) {
    PNEventMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                              handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (!PNIsPlainEnter(event)) return event;

        NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
        NSView *root = window.contentView;
        if (!root) return event;

        NSCollectionView *collectionView = PNFindMultiSelectedCollectionView(root);
        NSUInteger count = collectionView.selectionIndexPaths.count;
        if (count > 1) {
            // Crucially, return the event unchanged. Stock PasteNow 2.32
            // already gathers the entire selection on Enter; we only repair
            // its later pasteboard serialization.
            PNArmBatch(count);
            NSLog(@"[PasteNowMultiPasteFix] armed for %lu selected items",
                  (unsigned long)count);
        }
        return event;
    }];
}

__attribute__((constructor))
static void PNInstallMultiPasteFix(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PNInstallPasteboardHook();
        PNInstallEnterMonitor();
        NSLog(@"[PasteNowMultiPasteFix] installed (pasteboard batching mode)");
    });
}
