// Development-only renderer. Reuses the production shield view without starting
// Guardian, event taps, activity maintenance, Bluetooth, or authentication.
#import "../internal/macos/bridge.m"

void acuMenuAction(int action) { (void)action; }
void acuGuardianEnter(void) {}
void acuTapDegraded(void) {}
void acuPhysicalActivity(void) {}
void acuLidAngleChanged(void) {}
void acuSessionLockEvent(char *source) { (void)source; }
void acuLog(int level, char *message) { (void)level; (void)message; }
void acuBluetoothDisconnected(char *address) { (void)address; }

@interface ACUPreviewDelegate : NSObject <NSApplicationDelegate>
@end
@implementation ACUPreviewDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *output = argc > 1
            ? [NSString stringWithUTF8String:argv[1]]
            : [NSTemporaryDirectory() stringByAppendingPathComponent:@"acu-shield-preview.png"];
        BOOL showWindow = argc == 1;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--show") == 0) showWindow = YES;
        }
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) ACUPreviewDelegate *delegate = [ACUPreviewDelegate new];
        application.delegate = delegate;
        // Override only this preview process. Never write the user's ACU settings.
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            ACUShieldBackgroundPreferenceKey: @(ACUShieldBackgroundBlack)
        }];
        NSPanel *shield = create_shield(NSScreen.mainScreen);
        NSView *view = shield.contentView;
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 960, 600)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                        backing:NSBackingStoreBuffered defer:NO];
        window.title = @"ACU — Protection interface preview (no input interception)";
        window.backgroundColor = shield.backgroundColor;
        window.contentView = view;
        [view setFrame:NSMakeRect(0, 0, 960, 600)];
        [view layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error = nil;
        if (![png writeToFile:output options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("Rendered production shield view: %s\n", output.UTF8String);
        if (showWindow) {
            [window center];
            [window makeKeyAndOrderFront:nil];
            [application activateIgnoringOtherApps:YES];
            [application run];
        }
        return 0;
    }
}
