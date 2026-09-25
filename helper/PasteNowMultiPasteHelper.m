#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdatomic.h>

static NSString * const kPasteNowBundleID = @"app.pastenow.PasteNow";
static CFMachPortRef gTap = NULL;
static CFRunLoopSourceRef gTapSource = NULL;
static pid_t gTapPID = 0;
static _Atomic(pid_t) gLastTargetPID = 0;
static _Atomic(bool) gBusy = false;

static pid_t PasteNowPID(void) {
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:kPasteNowBundleID]) {
        if (!app.terminated) return app.processIdentifier;
    }
    return 0;
}

static BOOL HasMultipleSelected(AXUIElementRef element, int depth, int *budget) {
    if (!element || depth > 12 || (*budget)-- <= 0) return NO;

    const CFStringRef attrs[] = { kAXSelectedChildrenAttribute, CFSTR("AXSelectedRows"), CFSTR("AXSelectedCells") };
    for (size_t i = 0; i < sizeof(attrs) / sizeof(attrs[0]); i++) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(element, attrs[i], &value) == kAXErrorSuccess && value) {
            BOOL multiple = CFGetTypeID(value) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)value) > 1;
            CFRelease(value);
            if (multiple) return YES;
        }
    }

    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &childrenValue) != kAXErrorSuccess || !childrenValue) {
        return NO;
    }

    BOOL found = NO;
    if (CFGetTypeID(childrenValue) == CFArrayGetTypeID()) {
        CFArrayRef children = (CFArrayRef)childrenValue;
        for (CFIndex i = 0; i < CFArrayGetCount(children) && !found && *budget > 0; i++) {
            AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
            if (CFGetTypeID(child) == AXUIElementGetTypeID()) {
                found = HasMultipleSelected(child, depth + 1, budget);
            }
        }
    }
    CFRelease(childrenValue);
    return found;
}

static BOOL PasteNowHasMultiSelection(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return NO;

    CFTypeRef windowsValue = NULL;
    AXError err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windowsValue);
    CFRelease(app);
    if (err != kAXErrorSuccess || !windowsValue || CFGetTypeID(windowsValue) != CFArrayGetTypeID()) {
        if (windowsValue) CFRelease(windowsValue);
        return NO;
    }

    BOOL found = NO;
    CFArrayRef windows = (CFArrayRef)windowsValue;
    for (CFIndex i = 0; i < CFArrayGetCount(windows) && !found; i++) {
        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        int budget = 700;
        found = HasMultipleSelected(window, 0, &budget);
    }
    CFRelease(windowsValue);
    return found;
}

static pid_t TargetPID(pid_t pasteNowPID) {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front && !front.terminated &&
        front.processIdentifier != pasteNowPID &&
        front.processIdentifier != getpid() &&
        ![front.bundleIdentifier isEqualToString:kPasteNowBundleID]) {
        return front.processIdentifier;
    }

    pid_t pid = atomic_load(&gLastTargetPID);
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return (pid > 0 && app && !app.terminated) ? pid : 0;
}

static void PostKey(pid_t pid, CGKeyCode keyCode, CGEventFlags flags) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return;
    }
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPostToPid(pid, down);
    CGEventPostToPid(pid, up);
    CFRelease(down);
    CFRelease(up);
}

static void FinishPaste(pid_t pasteNowPID, pid_t targetPID) {
    PostKey(pasteNowPID, 53, 0);
    NSRunningApplication *target = [NSRunningApplication runningApplicationWithProcessIdentifier:targetPID];
    if (target && !target.terminated) {
        [target activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        PostKey(targetPID, 9, kCGEventFlagMaskCommand);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            atomic_store(&gBusy, false);
        });
    });
}

static void WaitForCopy(pid_t pasteNowPID, pid_t targetPID, NSInteger initialChangeCount, NSInteger attempt) {
    if (NSPasteboard.generalPasteboard.changeCount != initialChangeCount || attempt >= 12) {
        FinishPaste(pasteNowPID, targetPID);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        WaitForCopy(pasteNowPID, targetPID, initialChangeCount, attempt + 1);
    });
}

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    (void)proxy;
    (void)userInfo;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        return event;
    }
    if (type != kCGEventKeyDown || atomic_load(&gBusy)) return event;

    CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (key != 36 && key != 76) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    if (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)) return event;

    pid_t pasteNowPID = gTapPID;
    pid_t targetPID = TargetPID(pasteNowPID);
    if (targetPID <= 0 || !PasteNowHasMultiSelection(pasteNowPID)) return event;

    bool expected = false;
    if (!atomic_compare_exchange_strong(&gBusy, &expected, true)) return event;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger before = NSPasteboard.generalPasteboard.changeCount;
        PostKey(pasteNowPID, 8, kCGEventFlagMaskCommand);
        WaitForCopy(pasteNowPID, targetPID, before, 0);
    });
    return NULL;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *stateItem;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"PN";

    NSMenu *menu = [NSMenu new];
    self.stateItem = [[NSMenuItem alloc] initWithTitle:@"Waiting for PasteNow"
                                                action:@selector(openAccessibility:)
                                         keyEquivalent:@""];
    self.stateItem.target = self;
    [menu addItem:self.stateItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                  action:@selector(quit:)
                                           keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    self.statusItem.menu = menu;

    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(appActivated:)
                                                           name:NSWorkspaceDidActivateApplicationNotification
                                                         object:nil];

    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(refresh:)
                                                userInfo:nil
                                                 repeats:YES];
    [self refresh:nil];
}

- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.terminated || app.processIdentifier == getpid()) return;
    if ([app.bundleIdentifier isEqualToString:kPasteNowBundleID]) return;
    atomic_store(&gLastTargetPID, app.processIdentifier);
}

- (void)removeTap {
    if (gTapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), gTapSource, kCFRunLoopCommonModes);
        CFRelease(gTapSource);
        gTapSource = NULL;
    }
    if (gTap) {
        CFMachPortInvalidate(gTap);
        CFRelease(gTap);
        gTap = NULL;
    }
    gTapPID = 0;
}

- (void)refresh:(NSTimer *)timer {
    (void)timer;

    if (!AXIsProcessTrusted()) {
        self.stateItem.title = @"Accessibility required — click";
        [self removeTap];
        return;
    }

    pid_t pid = PasteNowPID();
    if (pid <= 0) {
        self.stateItem.title = @"Waiting for PasteNow";
        [self removeTap];
        return;
    }

    if (gTap && gTapPID == pid) {
        self.stateItem.title = @"Active for PasteNow";
        return;
    }

    [self removeTap];
    gTapPID = pid;
    gTap = CGEventTapCreateForPid(pid,
                                  kCGHeadInsertEventTap,
                                  kCGEventTapOptionDefault,
                                  CGEventMaskBit(kCGEventKeyDown),
                                  TapCallback,
                                  NULL);
    if (!gTap) {
        gTapPID = 0;
        self.stateItem.title = @"Event access unavailable — click";
        return;
    }

    gTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), gTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gTap, true);
    self.stateItem.title = @"Active for PasteNow";
}

- (void)openAccessibility:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self removeTap];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
