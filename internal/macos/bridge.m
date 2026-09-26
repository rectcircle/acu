#import "bridge.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ColorSync/ColorSync.h>
#import <IOKit/hid/IOHIDManager.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <unistd.h>

static NSStatusItem *gStatusItem;
static NSMenuItem *gStateItem;
static NSMenuItem *gEnableMenuItem;
static NSMenuItem *gKeepAwakeMenuItem;
static NSMenuItem *gLidAutomationMenuItem;
static NSMenuItem *gLidAngleRootItem;
static NSArray<NSMenuItem *> *gLidAngleMenuItems;
static NSArray<NSMenuItem *> *gShieldBackgroundMenuItems;
static NSMenuItem *gHotKeyRootItem;
static NSArray<NSMenuItem *> *gHotKeyMenuItems;
static NSMutableArray<NSPanel *> *gShieldWindows;
static NSTimer *gShieldMotionTimer;
static NSMutableDictionary<NSString *, NSURLSessionDownloadTask *>
    *gShieldVideoDownloads;
static id gMenuTarget;
static id gScreenObserver;
static int gShieldCountdown = -1;
static CGFloat gShieldMotionOffset;
static BOOL gShieldMotionMovesUp = YES;
static BOOL gShieldAnimationEnabled = YES;
static BOOL gInputGuardFailureVisible;
static NSTimer *gPermissionPollTimer;
static IOHIDDeviceRef gLidAngleDevice;
static IOHIDManagerRef gLidAngleManager;
static CFIndex gLidAngleReportID = 1;
static pthread_mutex_t gLidAngleMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL gLidAngleInitializationAttempted;
static double gLidAnglePrevious;
static BOOL gLidAngleKnown;

static const NSInteger ACUShieldStatusTag = 1001;
static NSString *const ACUHotKeyPreferenceKey = @"ACUGlobalHotKeyPreset";
static NSString *const ACUShieldBackgroundPreferenceKey =
    @"ACUShieldBackgroundStyle";
static NSString *const ACUShieldVerticalConstraintIdentifier =
    @"ACUShieldVerticalConstraint";
static NSString *const ACULidAutomationEnabledKey =
    @"ACULidAutomationEnabled";
static NSString *const ACUKeepAwakeEnabledKey =
    @"ACUKeepAwakeEnabled";
static NSString *const ACULidAngleThresholdKey =
    @"ACULidAngleThreshold";

static CFMachPortRef gEventTap;
static CFRunLoopRef gEventRunLoop;
static pthread_t gEventThread;
static pthread_mutex_t gEventMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gEventCondition = PTHREAD_COND_INITIALIZER;
static int gEventStarted;
static int gEventStartResult;
static uint64_t gEventMarker;
static atomic_bool gAuthenticationMode;
static atomic_int gAuthenticationPID;

static BOOL gBrightnessSaved;

static EventHotKeyRef gHotKeyRef;
static EventHandlerRef gHotKeyHandler;
static NSInteger gCurrentHotKeyPreset;

typedef NS_ENUM(NSInteger, ACUHotKeyPreset) {
    ACUHotKeyPresetDefault = 0,
    ACUHotKeyPresetP = 1,
    ACUHotKeyPresetA = 2,
    ACUHotKeyPresetDisabled = 3,
};

static const OSType ACUHotKeySignature = 0x41435531; // ACU1
static const UInt32 ACUHotKeyIdentifier = 1;
static const NSInteger ACULidDefaultThreshold = 45;
static const CGFloat ACUShieldTitleBaseOffset = -24.0;
static const CGFloat ACUShieldMotionDistance = 12.0;
static const NSTimeInterval ACUShieldMotionInterval = 60.0;

typedef NS_ENUM(NSInteger, ACUShieldBackgroundStyle) {
    ACUShieldBackgroundSystem = 0,
    ACUShieldBackgroundBlack = 1,
};

static BOOL initialize_lid_angle_sensor(void);
static void update_lid_automation_menu(void);

static void on_main_sync(dispatch_block_t block) {
    if (pthread_main_np()) {
        block();
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), block);
}

static OSStatus global_hotkey_handler(EventHandlerCallRef nextHandler,
                                      EventRef event,
                                      void *userData) {
    (void)nextHandler;
    (void)userData;
    EventHotKeyID hotKeyID;
    OSStatus status =
        GetEventParameter(event,
                          kEventParamDirectObject,
                          typeEventHotKeyID,
                          NULL,
                          sizeof(hotKeyID),
                          NULL,
                          &hotKeyID);
    if (status == noErr &&
        hotKeyID.signature == ACUHotKeySignature &&
        hotKeyID.id == ACUHotKeyIdentifier) {
        acuMenuAction(ACU_MENU_ENABLE);
        return noErr;
    }
    return eventNotHandledErr;
}

static BOOL register_global_hotkey(ACUHotKeyPreset preset) {
    if (gHotKeyRef != NULL) {
        UnregisterEventHotKey(gHotKeyRef);
        gHotKeyRef = NULL;
    }
    if (preset == ACUHotKeyPresetDisabled) {
        return YES;
    }
    if (gHotKeyHandler == NULL) {
        EventTypeSpec eventType = {
            .eventClass = kEventClassKeyboard,
            .eventKind = kEventHotKeyPressed,
        };
        OSStatus status =
            InstallEventHandler(GetApplicationEventTarget(),
                                global_hotkey_handler,
                                1,
                                &eventType,
                                NULL,
                                &gHotKeyHandler);
        if (status != noErr) {
            return NO;
        }
    }

    UInt32 keyCode = kVK_ANSI_L;
    if (preset == ACUHotKeyPresetP) {
        keyCode = kVK_ANSI_P;
    } else if (preset == ACUHotKeyPresetA) {
        keyCode = kVK_ANSI_A;
    }
    EventHotKeyID hotKeyID = {
        .signature = ACUHotKeySignature,
        .id = ACUHotKeyIdentifier,
    };
    return RegisterEventHotKey(keyCode,
                               controlKey | optionKey | cmdKey,
                               hotKeyID,
                               GetApplicationEventTarget(),
                               0,
                               &gHotKeyRef) == noErr;
}

static void update_hotkey_menu(ACUHotKeyPreset preset, BOOL available) {
    gCurrentHotKeyPreset = preset;
    for (NSMenuItem *item in gHotKeyMenuItems) {
        item.state = item.tag == preset ? NSControlStateValueOn
                                       : NSControlStateValueOff;
    }
    gHotKeyRootItem.title =
        available ? @"开启快捷键" : @"开启快捷键（注册失败）";

    NSString *key = @"";
    if (preset == ACUHotKeyPresetDefault) {
        key = @"l";
    } else if (preset == ACUHotKeyPresetP) {
        key = @"p";
    } else if (preset == ACUHotKeyPresetA) {
        key = @"a";
    }
    gEnableMenuItem.keyEquivalent = key;
    gEnableMenuItem.keyEquivalentModifierMask =
        key.length == 0
            ? 0
            : NSEventModifierFlagControl |
                  NSEventModifierFlagOption |
                  NSEventModifierFlagCommand;
}

static NSInteger lid_angle_threshold(void) {
    NSInteger threshold =
        [[NSUserDefaults standardUserDefaults]
            integerForKey:ACULidAngleThresholdKey];
    if (threshold != 30 && threshold != 45 && threshold != 60) {
        return ACULidDefaultThreshold;
    }
    return threshold;
}

static BOOL lid_automation_enabled(void) {
    id stored =
        [[NSUserDefaults standardUserDefaults]
            objectForKey:ACULidAutomationEnabledKey];
    return stored == nil ? YES : [stored boolValue];
}

static ACUShieldBackgroundStyle shield_background_style(void) {
    NSInteger style =
        [[NSUserDefaults standardUserDefaults]
            integerForKey:ACUShieldBackgroundPreferenceKey];
    if (style != ACUShieldBackgroundSystem &&
        style != ACUShieldBackgroundBlack) {
        return ACUShieldBackgroundSystem;
    }
    return (ACUShieldBackgroundStyle)style;
}

static void update_shield_background_menu(void) {
    ACUShieldBackgroundStyle style = shield_background_style();
    for (NSMenuItem *item in gShieldBackgroundMenuItems) {
        item.state = item.tag == style ? NSControlStateValueOn
                                       : NSControlStateValueOff;
    }
}

static BOOL initialize_lid_angle_sensor(void) {
    @autoreleasepool {
        pthread_mutex_lock(&gLidAngleMutex);
        if (gLidAngleInitializationAttempted) {
            BOOL available = gLidAngleDevice != NULL;
            pthread_mutex_unlock(&gLidAngleMutex);
            return available;
        }
        gLidAngleInitializationAttempted = YES;

        IOHIDManagerRef manager =
            IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        if (manager == NULL) {
            pthread_mutex_unlock(&gLidAngleMutex);
            return NO;
        }
        NSDictionary *matching = @{
          @"VendorID" : @0x05ac,
          @"ProductID" : @0x8104,
          @"UsagePage" : @0x0020,
          @"Usage" : @0x008a,
        };
        IOHIDManagerSetDeviceMatching(
            manager, (__bridge CFDictionaryRef)matching);
        if (IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone) !=
            kIOReturnSuccess) {
            CFRelease(manager);
            pthread_mutex_unlock(&gLidAngleMutex);
            return NO;
        }

        CFSetRef devices = IOHIDManagerCopyDevices(manager);
        if (devices != NULL) {
            CFIndex count = CFSetGetCount(devices);
            const void **values =
                count > 0 ? calloc((size_t)count, sizeof(*values)) : NULL;
            if (values != NULL) {
                CFSetGetValues(devices, values);
                for (CFIndex index = 0; index < count; index++) {
                    IOHIDDeviceRef device = (IOHIDDeviceRef)values[index];
                    if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) !=
                        kIOReturnSuccess) {
                        continue;
                    }
                    for (CFIndex reportID = 1; reportID >= 0; reportID--) {
                        uint8_t report[8] = {0};
                        CFIndex length = sizeof(report);
                        if (IOHIDDeviceGetReport(device,
                                                 kIOHIDReportTypeFeature,
                                                 reportID,
                                                 report,
                                                 &length) ==
                                kIOReturnSuccess &&
                            length >= 3) {
                            gLidAngleDevice =
                                (IOHIDDeviceRef)CFRetain(device);
                            gLidAngleReportID = reportID;
                            gLidAngleManager = manager;
                            break;
                        }
                    }
                    if (gLidAngleDevice != NULL) {
                        break;
                    }
                    IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
                }
                free(values);
            }
            CFRelease(devices);
        }

        if (gLidAngleDevice == NULL) {
            IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
            CFRelease(manager);
        }
        BOOL available = gLidAngleDevice != NULL;
        pthread_mutex_unlock(&gLidAngleMutex);
        return available;
    }
}

static void update_lid_automation_menu(void) {
    BOOL available = gLidAngleDevice != NULL;
    BOOL enabled = lid_automation_enabled();
    NSInteger threshold = lid_angle_threshold();

    gLidAutomationMenuItem.enabled = available;
    gLidAutomationMenuItem.state =
        available && enabled ? NSControlStateValueOn
                             : NSControlStateValueOff;
    gLidAutomationMenuItem.title =
        available ? @"半合盖自动保护"
                  : @"半合盖自动保护（传感器不可用）";
    gLidAngleRootItem.enabled = available;
    for (NSMenuItem *item in gLidAngleMenuItems) {
        item.state = item.tag == threshold ? NSControlStateValueOn
                                           : NSControlStateValueOff;
    }
}

@interface ACUMenuTarget : NSObject
- (void)enable:(id)sender;
- (void)toggleKeepAwake:(id)sender;
- (void)testProtection:(id)sender;
- (void)unlock:(id)sender;
- (void)diagnostics:(id)sender;
- (void)toggleLidAutomation:(id)sender;
- (void)selectLidAngle:(id)sender;
- (void)selectShieldBackground:(id)sender;
- (void)selectHotKey:(id)sender;
- (void)quit:(id)sender;
@end

@implementation ACUMenuTarget
- (void)enable:(id)sender {
    (void)sender;
    acuMenuAction(ACU_MENU_ENABLE);
}
- (void)toggleKeepAwake:(id)sender {
    (void)sender;
    acuMenuAction(ACU_MENU_KEEP_AWAKE);
}
- (void)testProtection:(id)sender {
    (void)sender;
    acuMenuAction(ACU_MENU_TEST);
}
- (void)unlock:(id)sender {
    (void)sender;
    acuMenuAction(ACU_MENU_UNLOCK);
}
- (void)diagnostics:(id)sender {
    (void)sender;
    acuMenuAction(ACU_MENU_DIAGNOSTICS);
}
- (void)toggleLidAutomation:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = !lid_automation_enabled();
    [defaults setBool:enabled forKey:ACULidAutomationEnabledKey];
    update_lid_automation_menu();
    acuMenuAction(ACU_MENU_LID_CONFIGURATION);
}
- (void)selectLidAngle:(id)sender {
    NSInteger threshold = [sender tag];
    if (threshold != 30 && threshold != 45 && threshold != 60) {
        return;
    }
    [[NSUserDefaults standardUserDefaults]
        setInteger:threshold
            forKey:ACULidAngleThresholdKey];
    update_lid_automation_menu();
    acuMenuAction(ACU_MENU_LID_CONFIGURATION);
}
- (void)selectShieldBackground:(id)sender {
    NSInteger style = [sender tag];
    if (style != ACUShieldBackgroundSystem &&
        style != ACUShieldBackgroundBlack) {
        return;
    }
    [[NSUserDefaults standardUserDefaults]
        setInteger:style
            forKey:ACUShieldBackgroundPreferenceKey];
    update_shield_background_menu();
}
- (void)selectHotKey:(id)sender {
    ACUHotKeyPreset preset = (ACUHotKeyPreset)[sender tag];
    ACUHotKeyPreset previous = (ACUHotKeyPreset)gCurrentHotKeyPreset;
    if (!register_global_hotkey(preset)) {
        BOOL restored = register_global_hotkey(previous);
        update_hotkey_menu(previous, restored);
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"全局快捷键不可用";
        alert.informativeText =
            @"该组合键已被其他应用占用，请选择另一个组合键。";
        [alert addButtonWithTitle:@"确定"];
        [alert runModal];
        return;
    }
    [[NSUserDefaults standardUserDefaults]
        setInteger:preset
            forKey:ACUHotKeyPreferenceKey];
    update_hotkey_menu(preset, YES);
}
- (void)quit:(id)sender {
    (void)sender;
    acuMenuAction(ACU_MENU_QUIT);
}
@end

int acu_init_menu(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        gMenuTarget = [ACUMenuTarget new];
        gStatusItem = [[NSStatusBar systemStatusBar]
            statusItemWithLength:NSVariableStatusItemLength];
        if (gStatusItem == nil) {
            return 0;
        }

        NSString *statusIconPath =
            [[NSBundle mainBundle] pathForResource:@"StatusIconTemplate"
                                            ofType:@"pdf"];
        NSImage *statusIcon =
            [[NSImage alloc] initWithContentsOfFile:statusIconPath];
        if (statusIcon != nil) {
            statusIcon.template = YES;
            statusIcon.size = NSMakeSize(18.0, 18.0);
            gStatusItem.button.image = statusIcon;
            gStatusItem.button.imagePosition = NSImageOnly;
            gStatusItem.button.toolTip = @"ACU";
        } else {
            gStatusItem.button.title = @"ACU";
        }
        NSMenu *menu = [NSMenu new];
        gStateItem = [[NSMenuItem alloc] initWithTitle:@"状态：未启用"
                                                action:nil
                                         keyEquivalent:@""];
        [gStateItem setEnabled:NO];
        [menu addItem:gStateItem];
        [menu addItem:[NSMenuItem separatorItem]];

        gEnableMenuItem =
            [[NSMenuItem alloc] initWithTitle:@"开启模拟锁屏"
                                      action:@selector(enable:)
                               keyEquivalent:@""];
        gEnableMenuItem.target = gMenuTarget;
        [menu addItem:gEnableMenuItem];

        gKeepAwakeMenuItem =
            [[NSMenuItem alloc] initWithTitle:@"仅阻止系统锁屏"
                                      action:@selector(toggleKeepAwake:)
                               keyEquivalent:@""];
        gKeepAwakeMenuItem.target = gMenuTarget;
        [menu addItem:gKeepAwakeMenuItem];

        NSMenuItem *shieldBackgroundRootItem =
            [[NSMenuItem alloc] initWithTitle:@"模拟锁屏背景"
                                      action:nil
                               keyEquivalent:@""];
        NSMenu *shieldBackgroundMenu =
            [[NSMenu alloc] initWithTitle:@"模拟锁屏背景"];
        NSArray<NSString *> *backgroundTitles =
            @[@"当前系统背景（不支持生成式墙纸）", @"纯黑"];
        NSMutableArray<NSMenuItem *> *backgroundItems =
            [NSMutableArray new];
        for (NSInteger index = 0; index < backgroundTitles.count; index++) {
            NSMenuItem *item =
                [[NSMenuItem alloc]
                    initWithTitle:backgroundTitles[index]
                          action:@selector(selectShieldBackground:)
                   keyEquivalent:@""];
            item.target = gMenuTarget;
            item.tag = index;
            [shieldBackgroundMenu addItem:item];
            [backgroundItems addObject:item];
        }
        gShieldBackgroundMenuItems = backgroundItems;
        shieldBackgroundRootItem.submenu = shieldBackgroundMenu;
        [menu addItem:shieldBackgroundRootItem];

        gLidAutomationMenuItem =
            [[NSMenuItem alloc] initWithTitle:@"半合盖自动保护"
                                      action:@selector(toggleLidAutomation:)
                               keyEquivalent:@""];
        gLidAutomationMenuItem.target = gMenuTarget;
        [menu addItem:gLidAutomationMenuItem];

        gLidAngleRootItem =
            [[NSMenuItem alloc] initWithTitle:@"半合盖触发角度"
                                      action:nil
                               keyEquivalent:@""];
        NSMenu *lidAngleMenu =
            [[NSMenu alloc] initWithTitle:@"半合盖触发角度"];
        NSMutableArray<NSMenuItem *> *lidAngleItems = [NSMutableArray new];
        for (NSNumber *threshold in @[@30, @45, @60]) {
            NSMenuItem *item =
                [[NSMenuItem alloc]
                    initWithTitle:[NSString stringWithFormat:@"%@°",
                                                            threshold]
                          action:@selector(selectLidAngle:)
                   keyEquivalent:@""];
            item.target = gMenuTarget;
            item.tag = threshold.integerValue;
            [lidAngleMenu addItem:item];
            [lidAngleItems addObject:item];
        }
        gLidAngleMenuItems = lidAngleItems;
        gLidAngleRootItem.submenu = lidAngleMenu;
        [menu addItem:gLidAngleRootItem];

        NSMenuItem *testProtection =
            [[NSMenuItem alloc] initWithTitle:@"测试模拟锁屏（15 秒自动退出）"
                                      action:@selector(testProtection:)
                               keyEquivalent:@""];
        testProtection.target = gMenuTarget;
        [menu addItem:testProtection];

        NSMenuItem *unlock = [[NSMenuItem alloc] initWithTitle:@"解除保护"
                                                       action:@selector(unlock:)
                                                keyEquivalent:@""];
        unlock.target = gMenuTarget;
        [menu addItem:unlock];

        NSMenuItem *diagnostics =
            [[NSMenuItem alloc] initWithTitle:@"权限诊断"
                                      action:@selector(diagnostics:)
                               keyEquivalent:@""];
        diagnostics.target = gMenuTarget;
        [menu addItem:diagnostics];

        gHotKeyRootItem =
            [[NSMenuItem alloc] initWithTitle:@"开启快捷键"
                                      action:nil
                               keyEquivalent:@""];
        NSMenu *hotKeyMenu = [[NSMenu alloc] initWithTitle:@"开启快捷键"];
        NSArray<NSString *> *titles = @[
          @"⌃⌥⌘L（默认）",
          @"⌃⌥⌘P",
          @"⌃⌥⌘A",
          @"关闭全局快捷键",
        ];
        NSMutableArray<NSMenuItem *> *items = [NSMutableArray new];
        for (NSInteger index = 0; index < titles.count; index++) {
            NSMenuItem *item =
                [[NSMenuItem alloc] initWithTitle:titles[index]
                                          action:@selector(selectHotKey:)
                                   keyEquivalent:@""];
            item.target = gMenuTarget;
            item.tag = index;
            [hotKeyMenu addItem:item];
            [items addObject:item];
        }
        gHotKeyMenuItems = items;
        gHotKeyRootItem.submenu = hotKeyMenu;
        [menu addItem:gHotKeyRootItem];

        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出"
                                                     action:@selector(quit:)
                                              keyEquivalent:@"q"];
        quit.target = gMenuTarget;
        [menu addItem:quit];
        gStatusItem.menu = menu;

        NSInteger storedPreset =
            [[NSUserDefaults standardUserDefaults]
                integerForKey:ACUHotKeyPreferenceKey];
        if (storedPreset < ACUHotKeyPresetDefault ||
            storedPreset > ACUHotKeyPresetDisabled) {
            storedPreset = ACUHotKeyPresetDefault;
        }
        BOOL available =
            register_global_hotkey((ACUHotKeyPreset)storedPreset);
        update_hotkey_menu(available ? (ACUHotKeyPreset)storedPreset
                                     : ACUHotKeyPresetDisabled,
                           available);
        initialize_lid_angle_sensor();
        update_lid_automation_menu();
        update_shield_background_menu();
        // 进程重启后立即恢复防锁屏的勾选状态（不必等子进程上报 awake）。
        if (acu_keep_awake_persisted()) {
            gKeepAwakeMenuItem.title = @"停止阻止系统锁屏";
            gKeepAwakeMenuItem.state = NSControlStateValueOn;
        }
        return 1;
    }
}

void acu_run_app(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp run];
    }
}

void acu_stop_app(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp terminate:nil];
    });
}

void acu_set_menu_state(const char *state) {
    if (state == NULL) {
        return;
    }
    NSString *value = [NSString stringWithUTF8String:state];
    on_main_sync(^{
      gStateItem.title = [NSString stringWithFormat:@"状态：%@", value];
    });
}

void acu_set_keep_awake_active(int active) {
    on_main_sync(^{
      gKeepAwakeMenuItem.title =
          active ? @"停止阻止系统锁屏" : @"仅阻止系统锁屏";
      gKeepAwakeMenuItem.state =
          active ? NSControlStateValueOn : NSControlStateValueOff;
    });
}

int acu_show_alert(const char *title, const char *message, int confirm) {
    if (title == NULL || message == NULL) {
        return 0;
    }
    NSString *alertTitle = [NSString stringWithUTF8String:title];
    NSString *alertMessage = [NSString stringWithUTF8String:message];
    __block NSInteger response = NSAlertFirstButtonReturn;
    on_main_sync(^{
      NSAlert *alert = [NSAlert new];
      alert.messageText = alertTitle;
      alert.informativeText = alertMessage;
      [alert addButtonWithTitle:confirm ? @"继续" : @"确定"];
      if (confirm) {
          [alert addButtonWithTitle:@"取消"];
      }
      response = [alert runModal];
    });
    return response == NSAlertFirstButtonReturn;
}

static BOOL permission_granted(uint32_t permission) {
    if (permission == ACU_PREFLIGHT_ACCESSIBILITY) {
        return AXIsProcessTrusted();
    }
    if (permission == ACU_PREFLIGHT_LISTEN_EVENTS) {
        return CGPreflightListenEventAccess();
    }
    return NO;
}

static void restart_application(void) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
      @"-c",
      @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
      @"acu-restart",
      [NSString stringWithFormat:@"%d", getpid()],
      [NSBundle mainBundle].bundlePath,
    ];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *error = nil;
    if ([task launchAndReturnError:&error]) {
        [NSApp terminate:nil];
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"无法重新启动 ACU";
    alert.informativeText = error.localizedDescription;
    [alert addButtonWithTitle:@"确定"];
    [alert runModal];
}

static void monitor_permission_until_granted(uint32_t permission) {
    [gPermissionPollTimer invalidate];
    gPermissionPollTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         repeats:YES
                                           block:^(NSTimer *timer) {
      if (!permission_granted(permission)) {
          return;
      }
      [timer invalidate];
      gPermissionPollTimer = nil;
      [NSApp activateIgnoringOtherApps:YES];

      NSAlert *alert = [NSAlert new];
      alert.messageText = @"权限已启用";
      alert.informativeText =
          @"需要重新启动 ACU 才能可靠应用新的系统权限。";
      [alert addButtonWithTitle:@"立即重启"];
      [alert addButtonWithTitle:@"稍后"];
      if ([alert runModal] == NSAlertFirstButtonReturn) {
          restart_application();
      }
    }];
}

void acu_show_preflight_alert(const char *title,
                              const char *message,
                              uint32_t failures) {
    if (title == NULL || message == NULL) {
        return;
    }
    NSString *alertTitle = [NSString stringWithUTF8String:title];
    NSString *alertMessage = [NSString stringWithUTF8String:message];
    BOOL needsAccessibility =
        (failures &
         (ACU_PREFLIGHT_ACCESSIBILITY | ACU_PREFLIGHT_POST_EVENTS)) != 0;
    BOOL needsListenEvents =
        !needsAccessibility &&
        (failures & ACU_PREFLIGHT_LISTEN_EVENTS) != 0;

    on_main_sync(^{
      NSAlert *alert = [NSAlert new];
      alert.messageText = alertTitle;
      if (needsAccessibility || needsListenEvents) {
          alert.informativeText = [alertMessage stringByAppendingString:
              @"\n\n操作步骤：\n"
               "1. 在打开的系统设置页面中启用“ACU”。\n"
               "2. 检测到授权后，按提示立即重启 ACU。"];
      } else {
          alert.informativeText = alertMessage;
      }

      NSMutableArray<NSURL *> *settingsURLs = [NSMutableArray new];
      NSMutableArray<NSNumber *> *permissions = [NSMutableArray new];
      if (needsAccessibility) {
          [alert addButtonWithTitle:@"打开辅助功能设置"];
          [settingsURLs addObject:[NSURL URLWithString:
              @"x-apple.systempreferences:com.apple.preference.security?"
               "Privacy_Accessibility"]];
          [permissions addObject:@(ACU_PREFLIGHT_ACCESSIBILITY)];
      }
      if (needsListenEvents) {
          [alert addButtonWithTitle:@"打开输入监控设置"];
          [settingsURLs addObject:[NSURL URLWithString:
              @"x-apple.systempreferences:com.apple.preference.security?"
               "Privacy_ListenEvent"]];
          [permissions addObject:@(ACU_PREFLIGHT_LISTEN_EVENTS)];
      }
      [alert addButtonWithTitle:
          settingsURLs.count == 0 ? @"确定" : @"稍后"];

      NSInteger response = [alert runModal];
      NSInteger selectedIndex = response - NSAlertFirstButtonReturn;
      if (selectedIndex >= 0 &&
          selectedIndex < (NSInteger)settingsURLs.count) {
          [[NSWorkspace sharedWorkspace]
              openURL:settingsURLs[(NSUInteger)selectedIndex]];
          monitor_permission_until_granted(
              permissions[(NSUInteger)selectedIndex].unsignedIntValue);
      }
    });
}

static BOOL preference_forced(CFStringRef key, CFStringRef domain) {
    return CFPreferencesAppValueIsForced(key, domain);
}

int acu_managed_policy_status(void) {
    if (preference_forced(CFSTR("idleTime"), CFSTR("com.apple.screensaver")) ||
        preference_forced(CFSTR("askForPassword"), CFSTR("com.apple.screensaver")) ||
        preference_forced(CFSTR("askForPasswordDelay"), CFSTR("com.apple.screensaver")) ||
        preference_forced(CFSTR("DisableScreenLockImmediate"), CFSTR("com.apple.loginwindow"))) {
        return 1;
    }
    return 0;
}

int acu_session_locked(void) {
    int locked = 0;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (session == NULL) {
        return 0;
    }
    CFBooleanRef value =
        CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
    if (value != NULL && CFGetTypeID(value) == CFBooleanGetTypeID()) {
        locked = CFBooleanGetValue(value) ? 1 : 0;
    }
    CFRelease(session);
    return locked;
}

int acu_lid_automation_enabled(void) {
    return lid_automation_enabled() ? 1 : 0;
}

double acu_lid_angle_threshold(void) {
    return (double)lid_angle_threshold();
}

int acu_read_lid_angle(double *angle) {
    if (angle == NULL) {
        return 0;
    }
    if (!initialize_lid_angle_sensor()) {
        return 0;
    }

    pthread_mutex_lock(&gLidAngleMutex);
    uint8_t report[8] = {0};
    CFIndex length = sizeof(report);
    IOReturn result =
        IOHIDDeviceGetReport(gLidAngleDevice,
                             kIOHIDReportTypeFeature,
                             gLidAngleReportID,
                             report,
                             &length);
    BOOL valid = result == kIOReturnSuccess && length >= 3;
    if (valid) {
        uint16_t raw = ((uint16_t)report[2] << 8) | report[1];
        valid = raw <= 180;
        if (valid) {
            *angle = (double)raw;
        }
    }
    pthread_mutex_unlock(&gLidAngleMutex);
    if (!valid) {
        return 0;
    }

    pthread_mutex_lock(&gLidAngleMutex);
    if (gLidAngleKnown) {
        if (fabs(*angle - gLidAnglePrevious) >= 0.5) {
            acuLidAngleChanged();
        }
    }
    gLidAnglePrevious = *angle;
    gLidAngleKnown = YES;
    pthread_mutex_unlock(&gLidAngleMutex);
    return 1;
}

int acu_has_external_display(void) {
    CGDirectDisplayID displays[32];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) {
        return 0;
    }
    for (uint32_t index = 0; index < count; index++) {
        if (!CGDisplayIsBuiltin(displays[index])) {
            return 1;
        }
    }
    return 0;
}

int acu_preflight(int request_permissions) {
    int failures = 0;
    NSDictionary *options =
        @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @(request_permissions != 0)};
    BOOL accessibilityTrusted =
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (!accessibilityTrusted) {
        failures |= ACU_PREFLIGHT_ACCESSIBILITY;
    } else {
        if (!CGPreflightListenEventAccess()) {
            if (request_permissions) {
                CGRequestListenEventAccess();
            }
            failures |= ACU_PREFLIGHT_LISTEN_EVENTS;
        }
        if (!CGPreflightPostEventAccess()) {
            if (request_permissions) {
                CGRequestPostEventAccess();
            }
            failures |= ACU_PREFLIGHT_POST_EVENTS;
        }
    }

    LAContext *context = [LAContext new];
    NSError *error = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        failures |= ACU_PREFLIGHT_AUTH;
    }
    if ([NSScreen screens].count == 0) {
        failures |= ACU_PREFLIGHT_DISPLAY;
    }
    if (acu_session_locked()) {
        failures |= ACU_PREFLIGHT_SESSION_LOCKED;
    }
    return failures;
}

int acu_preflight_keep_awake(int request_permissions) {
    int failures = 0;
    NSDictionary *options =
        @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @(request_permissions != 0)};
    BOOL accessibilityTrusted =
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (!accessibilityTrusted) {
        failures |= ACU_PREFLIGHT_ACCESSIBILITY;
    } else if (!CGPreflightPostEventAccess()) {
        if (request_permissions) {
            CGRequestPostEventAccess();
        }
        failures |= ACU_PREFLIGHT_POST_EVENTS;
    }
    if ([NSScreen screens].count == 0) {
        failures |= ACU_PREFLIGHT_DISPLAY;
    }
    if (acu_session_locked()) {
        failures |= ACU_PREFLIGHT_SESSION_LOCKED;
    }
    return failures;
}

static BOOL refresh_authentication_pid(void) {
    __block pid_t authenticationPID = 0;
    __block pid_t fallbackPID = 0;
    on_main_sync(^{
      for (NSRunningApplication *application
               in [[NSWorkspace sharedWorkspace] runningApplications]) {
          NSString *bundleID = application.bundleIdentifier ?: @"";
          NSString *path = application.executableURL.path ?: @"";
          if ([bundleID isEqualToString:@"com.apple.LocalAuthentication.UIAgent"]) {
              authenticationPID = application.processIdentifier;
              break;
          }
          if ([bundleID hasPrefix:@"com.apple.LocalAuthentication"] ||
              [path containsString:@"LocalAuthentication"]) {
              fallbackPID = application.processIdentifier;
          }
      }
    });
    atomic_store(&gAuthenticationPID,
                 authenticationPID != 0 ? authenticationPID : fallbackPID);
    return authenticationPID != 0;
}

static CGEventRef event_callback(CGEventTapProxy proxy,
                                 CGEventType type,
                                 CGEventRef event,
                                 void *context) {
    (void)proxy;
    (void)context;
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (gEventTap != NULL) {
            CGEventTapEnable(gEventTap, true);
            if (!CGEventTapIsEnabled(gEventTap)) {
                acuTapDegraded();
            }
        }
        return event;
    }

    int64_t marker =
        CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if ((uint64_t)marker == gEventMarker) {
        return event;
    }

    int64_t stateID =
        CGEventGetIntegerValueField(event, kCGEventSourceStateID);
    int64_t sourcePID =
        CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    BOOL physical =
        stateID == kCGEventSourceStateHIDSystemState || sourcePID <= 0;

    if (atomic_load(&gAuthenticationMode)) {
        if (!physical) {
            return event;
        }

        pid_t authenticationPID = atomic_load(&gAuthenticationPID);
        if (authenticationPID <= 0) {
            return NULL;
        }
        int64_t targetPID =
            CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID);
        if (targetPID == authenticationPID || targetPID == getpid()) {
            return event;
        }

        CGEventRef forwarded = CGEventCreateCopy(event);
        if (forwarded != NULL) {
            CGEventSetIntegerValueField(
                forwarded, kCGEventSourceUserData, (int64_t)gEventMarker);
            CGEventPostToPid(authenticationPID, forwarded);
            CFRelease(forwarded);
        }
        return NULL;
    }

    if (!physical) {
        return event;
    }

    acuPhysicalActivity();

    if (type == kCGEventKeyDown) {
        int64_t keycode =
            CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == 36 || keycode == 76) {
            acuGuardianEnter();
        }
    }
    return NULL;
}

static void *event_thread_main(void *unused) {
    (void)unused;
    @autoreleasepool {
        CGEventMask mask =
            CGEventMaskBit(kCGEventKeyDown) |
            CGEventMaskBit(kCGEventKeyUp) |
            CGEventMaskBit(kCGEventFlagsChanged) |
            CGEventMaskBit(kCGEventLeftMouseDown) |
            CGEventMaskBit(kCGEventLeftMouseUp) |
            CGEventMaskBit(kCGEventRightMouseDown) |
            CGEventMaskBit(kCGEventRightMouseUp) |
            CGEventMaskBit(kCGEventOtherMouseDown) |
            CGEventMaskBit(kCGEventOtherMouseUp) |
            CGEventMaskBit(kCGEventMouseMoved) |
            CGEventMaskBit(kCGEventLeftMouseDragged) |
            CGEventMaskBit(kCGEventRightMouseDragged) |
            CGEventMaskBit(kCGEventOtherMouseDragged) |
            CGEventMaskBit(kCGEventScrollWheel);

        CFMachPortRef tap =
            CGEventTapCreate(kCGHIDEventTap,
                             kCGHeadInsertEventTap,
                             kCGEventTapOptionDefault,
                             mask,
                             event_callback,
                             NULL);

        if (tap == NULL) {
            pthread_mutex_lock(&gEventMutex);
            gEventStartResult = 0;
            gEventStarted = 1;
            pthread_cond_signal(&gEventCondition);
            pthread_mutex_unlock(&gEventMutex);
            return NULL;
        }

        CFRunLoopSourceRef source =
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
        if (source == NULL) {
            CFRelease(tap);
            pthread_mutex_lock(&gEventMutex);
            gEventStartResult = 0;
            gEventStarted = 1;
            pthread_cond_signal(&gEventCondition);
            pthread_mutex_unlock(&gEventMutex);
            return NULL;
        }
        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        CFRetain(runLoop);
        CFRunLoopAddSource(runLoop, source, kCFRunLoopCommonModes);

        pthread_mutex_lock(&gEventMutex);
        gEventTap = tap;
        gEventRunLoop = runLoop;
        gEventStartResult = 1;
        gEventStarted = 1;
        pthread_cond_signal(&gEventCondition);
        pthread_mutex_unlock(&gEventMutex);

        CGEventTapEnable(tap, true);
        CFRunLoopRun();

        CFRunLoopRemoveSource(runLoop, source, kCFRunLoopCommonModes);
        pthread_mutex_lock(&gEventMutex);
        gEventRunLoop = NULL;
        gEventTap = NULL;
        pthread_mutex_unlock(&gEventMutex);
        CFRelease(source);
        CFRelease(runLoop);
        CFRelease(tap);
    }
    return NULL;
}

int acu_start_input_guard(uint64_t marker) {
    pthread_mutex_lock(&gEventMutex);
    if (gEventTap != NULL) {
        pthread_mutex_unlock(&gEventMutex);
        return 1;
    }
    gEventMarker = marker;
    gEventStarted = 0;
    gEventStartResult = 0;
    atomic_store(&gAuthenticationMode, false);
    atomic_store(&gAuthenticationPID, 0);
    if (pthread_create(&gEventThread, NULL, event_thread_main, NULL) != 0) {
        pthread_mutex_unlock(&gEventMutex);
        return 0;
    }
    while (!gEventStarted) {
        pthread_cond_wait(&gEventCondition, &gEventMutex);
    }
    int result = gEventStartResult;
    pthread_mutex_unlock(&gEventMutex);
    if (!result) {
        pthread_join(gEventThread, NULL);
        return result;
    }
    return result;
}

void acu_stop_input_guard(void) {
    pthread_mutex_lock(&gEventMutex);
    CFRunLoopRef runLoop = gEventRunLoop;
    if (runLoop != NULL) {
        CFRetain(runLoop);
    }
    pthread_mutex_unlock(&gEventMutex);
    if (runLoop == NULL) {
        return;
    }
    CFRunLoopStop(runLoop);
    CFRelease(runLoop);
    pthread_join(gEventThread, NULL);
}

void acu_set_input_authentication_mode(int enabled) {
    if (enabled) {
        refresh_authentication_pid();
        atomic_store(&gAuthenticationMode, true);
        return;
    }
    atomic_store(&gAuthenticationMode, false);
    atomic_store(&gAuthenticationPID, 0);
}

static NSDictionary *selected_desktop_wallpaper_choice(NSScreen *screen) {
    NSString *path =
        [NSHomeDirectory()
            stringByAppendingPathComponent:
                @"Library/Application Support/com.apple.wallpaper/"
                 "Store/Index.plist"];
    NSDictionary *store =
        [NSDictionary dictionaryWithContentsOfFile:path];
    NSNumber *displayNumber =
        screen.deviceDescription[@"NSScreenNumber"];
    CGDirectDisplayID displayID =
        (CGDirectDisplayID)displayNumber.unsignedIntValue;
    CFUUIDRef displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID);
    NSString *displayKey = nil;
    if (displayUUID != NULL) {
        displayKey =
            CFBridgingRelease(
                CFUUIDCreateString(kCFAllocatorDefault, displayUUID));
        CFRelease(displayUUID);
    }

    NSDictionary *displayRecord =
        displayKey == nil ? nil : store[@"Displays"][displayKey];
    NSArray *choices =
        displayRecord[@"Desktop"][@"Content"][@"Choices"];
    if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) {
        choices =
            store[@"Spaces"][@""]
                 [@"Default"][@"Desktop"][@"Content"][@"Choices"];
    }
    NSDictionary *choice =
        [choices isKindOfClass:[NSArray class]] ? choices.firstObject : nil;
    return [choice isKindOfClass:[NSDictionary class]] ? choice : nil;
}

static NSURL *wallpaper_extension_url(NSString *provider) {
    if (provider.length == 0) {
        return nil;
    }
    NSString *extensionProvider = provider;
    NSString *choicePrefix = @"com.apple.wallpaper.choice.";
    if ([provider hasPrefix:choicePrefix]) {
        extensionProvider =
            [@"com.apple.wallpaper.extension."
                stringByAppendingString:
                    [provider substringFromIndex:choicePrefix.length]];
    }
    NSURL *directory =
        [NSURL fileURLWithPath:@"/System/Library/ExtensionKit/Extensions"
                  isDirectory:YES];
    NSArray<NSURL *> *extensions =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:directory
          includingPropertiesForKeys:nil
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:nil];
    for (NSURL *extension in extensions) {
        NSBundle *bundle = [NSBundle bundleWithURL:extension];
        if ([bundle.bundleIdentifier isEqualToString:provider] ||
            [bundle.bundleIdentifier isEqualToString:extensionProvider]) {
            return extension;
        }
    }
    return nil;
}

static BOOL image_can_fill_screen(NSURL *url, NSScreen *screen) {
    NSImage *image =
        url == nil ? nil : [[NSImage alloc] initWithContentsOfURL:url];
    if (image == nil || !image.isValid) {
        return NO;
    }
    NSInteger pixelWidth = 0;
    NSInteger pixelHeight = 0;
    for (NSImageRep *representation in image.representations) {
        pixelWidth = MAX(pixelWidth, representation.pixelsWide);
        pixelHeight = MAX(pixelHeight, representation.pixelsHigh);
    }
    CGFloat scale = screen.backingScaleFactor;
    return pixelWidth >= NSWidth(screen.frame) * scale &&
           pixelHeight >= NSHeight(screen.frame) * scale;
}

static NSURL *wallpaper_extension_preview_url(NSURL *extension,
                                              BOOL dark,
                                              NSScreen *screen) {
    if (extension == nil) {
        return nil;
    }
    NSURL *resources =
        [extension URLByAppendingPathComponent:@"Contents/Resources"
                                    isDirectory:YES];
    NSArray<NSString *> *names =
        dark
            ? @[@"thumbnail dark.heic", @"thumbnail.heic",
                @"thumbnail light.heic"]
            : @[@"thumbnail light.heic", @"thumbnail.heic",
                @"thumbnail dark.heic"];
    for (NSString *name in names) {
        NSURL *candidate =
            [resources URLByAppendingPathComponent:name isDirectory:NO];
        if (image_can_fill_screen(candidate, screen)) {
            return candidate;
        }
    }
    return nil;
}

static NSURL *wallpaper_file_url(id value) {
    if ([value isKindOfClass:[NSURL class]]) {
        NSURL *url = value;
        return url.isFileURL ? url : nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *path = value;
        if ([[NSFileManager defaultManager] isReadableFileAtPath:path]) {
            return [NSURL fileURLWithPath:path];
        }
        return nil;
    }
    if ([value isKindOfClass:[NSData class]]) {
        BOOL stale = NO;
        NSURL *url =
            [NSURL URLByResolvingBookmarkData:value
                                       options:NSURLBookmarkResolutionWithoutUI |
                                               NSURLBookmarkResolutionWithoutMounting
                                 relativeToURL:nil
                           bookmarkDataIsStale:&stale
                                         error:nil];
        return url.isFileURL ? url : nil;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)value) {
            NSURL *url = wallpaper_file_url(child);
            if (url != nil) {
                return url;
            }
        }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        for (id child in [(NSDictionary *)value allValues]) {
            NSURL *url = wallpaper_file_url(child);
            if (url != nil) {
                return url;
            }
        }
    }
    return nil;
}

static NSDictionary *wallpaper_entry_with_id(id value,
                                              NSString *identifier) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"id"] isEqualToString:identifier]) {
            return dictionary;
        }
        for (id child in dictionary.allValues) {
            NSDictionary *match =
                wallpaper_entry_with_id(child, identifier);
            if (match != nil) {
                return match;
            }
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)value) {
            NSDictionary *match =
                wallpaper_entry_with_id(child, identifier);
            if (match != nil) {
                return match;
            }
        }
    }
    return nil;
}

static NSDictionary *decode_wallpaper_configuration(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return nil;
    }
    id value =
        [NSPropertyListSerialization propertyListWithData:data
                                                   options:0
                                                    format:nil
                                                     error:nil];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSURL *aerial_remote_video_url(NSDictionary *choice,
                                      NSScreen *screen,
                                      NSURL **posterURL,
                                      NSURL **localVideoURL) {
    NSDictionary *configuration =
        decode_wallpaper_configuration(choice[@"Configuration"]);
    NSString *selectedID = configuration[@"assetID"];
    if (![selectedID isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *aerialsRoot =
        [NSHomeDirectory()
            stringByAppendingPathComponent:
                @"Library/Application Support/com.apple.wallpaper/aerials"];
    NSString *manifestPath =
        [aerialsRoot stringByAppendingPathComponent:
                         @"manifest/entries.json"];
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    if (manifestData == nil) {
        manifestPath =
            @"/System/Library/ExtensionKit/Extensions/"
             "WallpaperAerialsExtension.appex/Contents/Resources/"
             "entries.json";
        manifestData = [NSData dataWithContentsOfFile:manifestPath];
    }
    NSDictionary *manifest =
        manifestData == nil
            ? nil
            : [NSJSONSerialization JSONObjectWithData:manifestData
                                              options:0
                                                error:nil];
    NSArray<NSDictionary *> *assets = manifest[@"assets"];
    if (![assets isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSString *appearance =
        [[NSApp effectiveAppearance]
            bestMatchFromAppearancesWithNames:
                @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
    NSString *wantedAppearance =
        [appearance isEqualToString:NSAppearanceNameDarkAqua]
            ? @"dark"
            : @"light";
    NSString *wantedOrientation =
        NSHeight(screen.frame) > NSWidth(screen.frame)
            ? @"portrait"
            : @"landscape";

    NSDictionary *selectedAsset = nil;
    for (NSDictionary *asset in assets) {
        if ([asset[@"id"] isEqualToString:selectedID]) {
            selectedAsset = asset;
            break;
        }
    }
    if (selectedAsset == nil) {
        for (NSDictionary *asset in assets) {
            NSArray *subcategories = asset[@"subcategories"];
            NSDictionary *variant = asset[@"variant"];
            if ([subcategories containsObject:selectedID] &&
                [variant[@"appearance"] isEqualToString:wantedAppearance] &&
                [variant[@"orientation"] isEqualToString:wantedOrientation]) {
                selectedAsset = asset;
                break;
            }
        }
    }
    if (selectedAsset == nil) {
        NSDictionary *group =
            wallpaper_entry_with_id(manifest[@"categories"], selectedID);
        NSString *representativeID = group[@"representativeAssetID"];
        for (NSDictionary *asset in assets) {
            if ([asset[@"id"] isEqualToString:representativeID]) {
                selectedAsset = asset;
                break;
            }
        }
    }
    NSString *assetID = selectedAsset[@"id"];
    if (![assetID isKindOfClass:[NSString class]]) {
        return nil;
    }

    if (localVideoURL != NULL) {
        NSString *localPath =
            [[aerialsRoot stringByAppendingPathComponent:@"videos"]
                stringByAppendingPathComponent:
                    [assetID stringByAppendingPathExtension:@"mov"]];
        if ([[NSFileManager defaultManager]
                isReadableFileAtPath:localPath]) {
            *localVideoURL = [NSURL fileURLWithPath:localPath];
        }
    }
    if (posterURL != NULL) {
        NSString *posterPath =
            [[aerialsRoot stringByAppendingPathComponent:@"thumbnails"]
                stringByAppendingPathComponent:
                    [assetID stringByAppendingPathExtension:@"png"]];
        if ([[NSFileManager defaultManager]
                isReadableFileAtPath:posterPath]) {
            *posterURL = [NSURL fileURLWithPath:posterPath];
        }
    }

    NSString *videoString = selectedAsset[@"url-4K-SDR-240FPS"];
    if (![videoString isKindOfClass:[NSString class]]) {
        for (NSString *key in selectedAsset) {
            id value = selectedAsset[key];
            if ([key hasPrefix:@"url-"] &&
                [value isKindOfClass:[NSString class]]) {
                videoString = value;
                break;
            }
        }
    }
    return [videoString isKindOfClass:[NSString class]]
               ? [NSURL URLWithString:videoString]
               : nil;
}

static NSURL *extension_remote_video_url(NSString *provider,
                                         NSScreen *screen,
                                         NSURL **posterURL) {
    NSURL *extension = wallpaper_extension_url(provider);
    NSString *appearance =
        [[NSApp effectiveAppearance]
            bestMatchFromAppearancesWithNames:
                @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
    BOOL dark = [appearance isEqualToString:NSAppearanceNameDarkAqua];
    if (posterURL != NULL) {
        *posterURL =
            wallpaper_extension_preview_url(extension, dark, screen);
    }
    NSURL *manifestURL =
        [extension URLByAppendingPathComponent:
                       @"Contents/Resources/manifest.json"];
    NSData *manifestData =
        manifestURL == nil ? nil : [NSData dataWithContentsOfURL:manifestURL];
    NSDictionary *manifest =
        manifestData == nil
            ? nil
            : [NSJSONSerialization JSONObjectWithData:manifestData
                                              options:0
                                                error:nil];
    if (![manifest isKindOfClass:[NSDictionary class]]) {
        fprintf(stderr,
                "acu: dynamic lock background provider %s has no "
                "supported manifest\n",
                provider.UTF8String ?: "(unknown)");
        return nil;
    }

    BOOL portrait = NSHeight(screen.frame) > NSWidth(screen.frame);
    NSString *videoKey =
        dark
            ? (portrait ? @"darkPortraitRemoteURL"
                        : @"darkLandscapeRemoteURL")
            : (portrait ? @"lightPortraitRemoteURL"
                        : @"lightLandscapeRemoteURL");
    NSString *videoString = manifest[videoKey];
    if (![videoString isKindOfClass:[NSString class]]) {
        return nil;
    }

    if (posterURL != NULL) {
        NSString *identifier = manifest[@"identifier"];
        if ([identifier isKindOfClass:[NSString class]]) {
            NSString *posterName =
                [NSString stringWithFormat:@"%@%@.heic",
                                           identifier,
                                           dark ? @"Dark" : @"Light"];
            NSURL *candidate =
                [extension URLByAppendingPathComponent:
                               [@"Contents/Resources"
                                   stringByAppendingPathComponent:posterName]];
            if ([[NSFileManager defaultManager]
                    isReadableFileAtPath:candidate.path]) {
                *posterURL = candidate;
            }
        }
    }
    return [NSURL URLWithString:videoString];
}

static NSURL *selected_desktop_remote_video_url(NSScreen *screen,
                                                NSURL **posterURL,
                                                NSURL **localVideoURL) {
    NSDictionary *choice =
        selected_desktop_wallpaper_choice(screen);
    NSString *provider = choice[@"Provider"];
    if ([provider isEqualToString:@"com.apple.wallpaper.choice.aerials"]) {
        return aerial_remote_video_url(
            choice, screen, posterURL, localVideoURL);
    }
    NSURL *remoteURL =
        extension_remote_video_url(provider, screen, posterURL);
    if (posterURL != NULL && *posterURL == nil) {
        *posterURL = wallpaper_file_url(choice[@"Files"]);
        if (*posterURL == nil &&
            ([provider containsString:@".image"] ||
             [provider containsString:@".legacy"])) {
            *posterURL =
                [[NSWorkspace sharedWorkspace]
                    desktopImageURLForScreen:screen];
        }
    }
    return remoteURL;
}

static NSURL *lock_screen_video_cache_url(NSURL *remoteURL) {
    NSURL *applicationSupport =
        [[[NSFileManager defaultManager]
            URLsForDirectory:NSApplicationSupportDirectory
                   inDomains:NSUserDomainMask] firstObject];
    if (applicationSupport == nil || remoteURL.lastPathComponent.length == 0) {
        return nil;
    }
    return [[[applicationSupport
                URLByAppendingPathComponent:@"ACU"
                                isDirectory:YES]
                URLByAppendingPathComponent:@"LockScreenBackgrounds"
                                isDirectory:YES]
                URLByAppendingPathComponent:remoteURL.lastPathComponent
                                isDirectory:NO];
}

static NSURL *cached_lock_screen_video_url(NSURL *remoteURL) {
    NSURL *cacheURL = lock_screen_video_cache_url(remoteURL);
    NSDictionary *attributes =
        cacheURL == nil
            ? nil
            : [[NSFileManager defaultManager]
                  attributesOfItemAtPath:cacheURL.path
                                  error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue] > 0) {
        return cacheURL;
    }
    return nil;
}

@interface ACUShieldBackgroundView : NSView
@property(nonatomic, strong) AVQueuePlayer *player;
@property(nonatomic, strong) AVPlayerLooper *looper;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CALayer *dimmingLayer;
@property(nonatomic, strong) NSURL *remoteVideoURL;
- (instancetype)initWithFrame:(NSRect)frame
                     videoURL:(NSURL *)videoURL
                    posterURL:(NSURL *)posterURL
               remoteVideoURL:(NSURL *)remoteVideoURL;
- (void)startVideoAtURL:(NSURL *)videoURL;
- (void)setPlaybackEnabled:(BOOL)enabled;
- (void)stopPlayback;
@end

@implementation ACUShieldBackgroundView
- (instancetype)initWithFrame:(NSRect)frame
                     videoURL:(NSURL *)videoURL
                    posterURL:(NSURL *)posterURL
               remoteVideoURL:(NSURL *)remoteVideoURL {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    self.remoteVideoURL = remoteVideoURL;
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.035 alpha:1.0].CGColor;
    NSImage *poster =
        posterURL == nil ? nil : [[NSImage alloc] initWithContentsOfURL:posterURL];
    if (poster != nil && poster.isValid) {
        self.layer.contents = poster;
        self.layer.contentsGravity = kCAGravityResizeAspectFill;
    }
    self.dimmingLayer = [CALayer layer];
    self.dimmingLayer.backgroundColor =
        [NSColor colorWithWhite:0.0 alpha:0.30].CGColor;
    self.dimmingLayer.frame = self.bounds;
    [self.layer addSublayer:self.dimmingLayer];
    if (videoURL != nil) {
        [self startVideoAtURL:videoURL];
    }
    return self;
}

- (void)startVideoAtURL:(NSURL *)videoURL {
    if (videoURL == nil || self.player != nil) {
        return;
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoURL];
    self.player = [AVQueuePlayer queuePlayerWithItems:@[]];
    self.player.muted = YES;
    self.looper =
        [AVPlayerLooper playerLooperWithPlayer:self.player
                                  templateItem:item];
    self.playerLayer =
        [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer insertSublayer:self.playerLayer below:self.dimmingLayer];
    if (gShieldAnimationEnabled) {
        [self.player play];
    }
}

- (void)layout {
    [super layout];
    self.playerLayer.frame = self.bounds;
    self.dimmingLayer.frame = self.bounds;
}

- (void)setPlaybackEnabled:(BOOL)enabled {
    if (enabled) {
        [self.player play];
    } else {
        [self.player pause];
    }
}

- (void)stopPlayback {
    [self.player pause];
    [self.player removeAllItems];
    self.looper = nil;
    self.player = nil;
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
}
@end

static void apply_downloaded_lock_screen_video(NSURL *remoteURL,
                                               NSURL *localURL) {
    dispatch_async(dispatch_get_main_queue(), ^{
      for (NSPanel *window in gShieldWindows) {
          if (![window.contentView
                  isKindOfClass:[ACUShieldBackgroundView class]]) {
              continue;
          }
          ACUShieldBackgroundView *view =
              (ACUShieldBackgroundView *)window.contentView;
          if ([view.remoteVideoURL isEqual:remoteURL]) {
              [view startVideoAtURL:localURL];
          }
      }
    });
}

static void download_lock_screen_video(NSURL *remoteURL) {
    if (remoteURL == nil ||
        ![remoteURL.scheme.lowercaseString isEqualToString:@"https"] ||
        ![remoteURL.host.lowercaseString hasSuffix:@".apple.com"]) {
        return;
    }
    NSURL *cacheURL = lock_screen_video_cache_url(remoteURL);
    if (cacheURL == nil || cached_lock_screen_video_url(remoteURL) != nil) {
        return;
    }

    @synchronized([ACUShieldBackgroundView class]) {
        if (gShieldVideoDownloads == nil) {
            gShieldVideoDownloads = [NSMutableDictionary new];
        }
        if (gShieldVideoDownloads[remoteURL.absoluteString] != nil) {
            return;
        }

        NSURLSessionDownloadTask *task =
            [[NSURLSession sharedSession]
                downloadTaskWithURL:remoteURL
                  completionHandler:^(NSURL *location,
                                      NSURLResponse *response,
                                      NSError *downloadError) {
          NSError *fileError = downloadError;
          NSHTTPURLResponse *httpResponse =
              [response isKindOfClass:[NSHTTPURLResponse class]]
                  ? (NSHTTPURLResponse *)response
                  : nil;
          if (fileError == nil &&
              (location == nil || httpResponse == nil ||
               httpResponse.statusCode < 200 ||
               httpResponse.statusCode >= 300)) {
              fileError =
                  [NSError errorWithDomain:@"ACUShieldBackground"
                                      code:httpResponse == nil
                                               ? -1
                                               : httpResponse.statusCode
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"invalid video download response",
                                  }];
          }
          if (fileError == nil) {
              NSFileManager *manager = [NSFileManager defaultManager];
              NSURL *directory = [cacheURL URLByDeletingLastPathComponent];
              [manager createDirectoryAtURL:directory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&fileError];
              if (fileError == nil &&
                  ![manager isReadableFileAtPath:cacheURL.path]) {
                  [manager moveItemAtURL:location
                                  toURL:cacheURL
                                  error:&fileError];
              }
          }
          if (fileError == nil &&
              [[NSFileManager defaultManager]
                  isReadableFileAtPath:cacheURL.path]) {
              apply_downloaded_lock_screen_video(remoteURL, cacheURL);
          } else {
              const char *message =
                  fileError.localizedDescription.UTF8String;
              fprintf(stderr,
                      "acu: download lock screen video failed: %s\n",
                      message != NULL ? message : "unknown error");
          }
          @synchronized([ACUShieldBackgroundView class]) {
              [gShieldVideoDownloads
                  removeObjectForKey:remoteURL.absoluteString];
          }
        }];
        gShieldVideoDownloads[remoteURL.absoluteString] = task;
        [task resume];
    }
}

static void set_shield_background_animation_enabled(BOOL enabled) {
    on_main_sync(^{
      gShieldAnimationEnabled = enabled;
      for (NSPanel *window in gShieldWindows) {
          if ([window.contentView
                  isKindOfClass:[ACUShieldBackgroundView class]]) {
              [(ACUShieldBackgroundView *)window.contentView
                  setPlaybackEnabled:enabled];
          }
      }
    });
}

static void close_shield_window(NSPanel *window) {
    if ([window.contentView
            isKindOfClass:[ACUShieldBackgroundView class]]) {
        [(ACUShieldBackgroundView *)window.contentView stopPlayback];
    }
    [window close];
}

static NSLayoutConstraint *shield_vertical_constraint(NSPanel *panel) {
    for (NSLayoutConstraint *constraint in panel.contentView.constraints) {
        if ([constraint.identifier
                isEqualToString:ACUShieldVerticalConstraintIdentifier]) {
            return constraint;
        }
    }
    return nil;
}

static void move_shield_text(void) {
    gShieldMotionOffset =
        gShieldMotionMovesUp ? ACUShieldMotionDistance
                             : -ACUShieldMotionDistance;
    gShieldMotionMovesUp = !gShieldMotionMovesUp;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.8;
      context.allowsImplicitAnimation = YES;
      for (NSPanel *window in gShieldWindows) {
          NSLayoutConstraint *constraint =
              shield_vertical_constraint(window);
          if (constraint == nil) {
              continue;
          }
          constraint.constant =
              ACUShieldTitleBaseOffset + gShieldMotionOffset;
          [[window.contentView animator] layoutSubtreeIfNeeded];
      }
    } completionHandler:nil];
}

static void start_shield_motion_timer(void) {
    if (gShieldMotionTimer != nil) {
        return;
    }
    gShieldMotionOffset = 0;
    gShieldMotionMovesUp = YES;
    gShieldMotionTimer =
        [NSTimer timerWithTimeInterval:ACUShieldMotionInterval
                               repeats:YES
                                 block:^(NSTimer *timer) {
                                   (void)timer;
                                   move_shield_text();
                                 }];
    [[NSRunLoop mainRunLoop] addTimer:gShieldMotionTimer
                              forMode:NSRunLoopCommonModes];
}

static void stop_shield_motion_timer(void) {
    [gShieldMotionTimer invalidate];
    gShieldMotionTimer = nil;
    gShieldMotionOffset = 0;
    gShieldMotionMovesUp = YES;
}

static NSPanel *create_shield(NSScreen *screen) {
    NSPanel *panel =
        [[NSPanel alloc] initWithContentRect:NSZeroRect
                                   styleMask:NSWindowStyleMaskBorderless |
                                             NSWindowStyleMaskNonactivatingPanel
                                     backing:NSBackingStoreBuffered
                                       defer:NO
                                      screen:screen];
    [panel setFrame:screen.frame display:NO];
    panel.level = CGWindowLevelForKey(kCGScreenSaverWindowLevelKey);
    panel.opaque = YES;
    panel.backgroundColor = [NSColor colorWithWhite:0.035 alpha:1.0];
    panel.hidesOnDeactivate = NO;
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.sharingType = NSWindowSharingNone;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorStationary;

    NSURL *remoteVideoURL = nil;
    NSURL *videoURL = nil;
    NSURL *posterURL = nil;
    NSURL *systemVideoURL = nil;
    if (shield_background_style() ==
        ACUShieldBackgroundSystem) {
        remoteVideoURL =
            selected_desktop_remote_video_url(
                screen, &posterURL, &systemVideoURL);
        videoURL = systemVideoURL != nil
                       ? systemVideoURL
                       : cached_lock_screen_video_url(remoteVideoURL);
        if (videoURL == nil && remoteVideoURL == nil && posterURL == nil) {
            fprintf(stderr,
                    "acu: selected system background unavailable; "
                    "using black background\n");
        }
    }
    ACUShieldBackgroundView *content =
        [[ACUShieldBackgroundView alloc]
            initWithFrame:NSMakeRect(0, 0,
                                     NSWidth(screen.frame),
                                     NSHeight(screen.frame))
                 videoURL:videoURL
                posterURL:posterURL
           remoteVideoURL:remoteVideoURL];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel.contentView = content;
    if (remoteVideoURL != nil && videoURL == nil) {
        download_lock_screen_video(remoteVideoURL);
    }

    NSTextField *title = [NSTextField labelWithString:@"ACU"];
    title.textColor = [NSColor whiteColor];
    title.font = [NSFont systemFontOfSize:32 weight:NSFontWeightSemibold];
    title.alignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *statusText =
        gShieldCountdown >= 0
            ? [NSString stringWithFormat:
                  @"模拟锁屏保护中\n按 Enter 认证，%d 秒后自动退出",
                  gShieldCountdown]
            : @"模拟锁屏保护中\n按 Enter 后使用 Touch ID 或系统密码认证";
    NSTextField *status = [NSTextField labelWithString:statusText];
    status.tag = ACUShieldStatusTag;
    status.textColor = [NSColor colorWithWhite:0.75 alpha:1.0];
    status.font = [NSFont systemFontOfSize:16];
    status.alignment = NSTextAlignmentCenter;
    status.maximumNumberOfLines = 2;
    status.translatesAutoresizingMaskIntoConstraints = NO;

    [content addSubview:title];
    [content addSubview:status];
    NSLayoutConstraint *verticalConstraint =
        [title.centerYAnchor
            constraintEqualToAnchor:content.centerYAnchor
                           constant:ACUShieldTitleBaseOffset +
                                    gShieldMotionOffset];
    verticalConstraint.identifier =
        ACUShieldVerticalConstraintIdentifier;
    [NSLayoutConstraint activateConstraints:@[
      [title.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
      verticalConstraint,
      [status.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
      [status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18]
    ]];
    return panel;
}

static int rebuild_shields(void) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0) {
        return 0;
    }
    NSMutableArray<NSPanel *> *newWindows = [NSMutableArray new];
    for (NSScreen *screen in screens) {
        NSPanel *panel = create_shield(screen);
        if (panel == nil) {
            for (NSPanel *window in newWindows) {
                close_shield_window(window);
            }
            return 0;
        }
        [panel setFrame:screen.frame display:YES];
        [newWindows addObject:panel];
    }
    for (NSPanel *window in newWindows) {
        [window orderFrontRegardless];
    }
    for (NSPanel *window in gShieldWindows) {
        close_shield_window(window);
    }
    gShieldWindows = newWindows;
    return 1;
}

int acu_show_shields(void) {
    __block int result = 0;
    on_main_sync(^{
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      result = rebuild_shields();
      if (result) {
          start_shield_motion_timer();
      }
      if (result && gScreenObserver == nil) {
          gScreenObserver = [[NSNotificationCenter defaultCenter]
              addObserverForName:NSApplicationDidChangeScreenParametersNotification
                          object:nil
                           queue:[NSOperationQueue mainQueue]
                      usingBlock:^(NSNotification *note) {
                        (void)note;
                        rebuild_shields();
                      }];
      }
    });
    return result;
}

void acu_hide_shields(void) {
    on_main_sync(^{
      stop_shield_motion_timer();
      if (gScreenObserver != nil) {
          [[NSNotificationCenter defaultCenter] removeObserver:gScreenObserver];
          gScreenObserver = nil;
      }
      for (NSPanel *window in gShieldWindows) {
          close_shield_window(window);
      }
      gShieldWindows = nil;
    });
}

void acu_set_shield_authentication_mode(int enabled) {
    on_main_sync(^{
      for (NSPanel *window in gShieldWindows) {
          window.ignoresMouseEvents = enabled ? NO : YES;
          window.level = enabled
                             ? NSStatusWindowLevel
                             : CGWindowLevelForKey(kCGScreenSaverWindowLevelKey);
      }
    });
}

void acu_set_shield_countdown(int seconds) {
    on_main_sync(^{
      gShieldCountdown = seconds;
      for (NSPanel *window in gShieldWindows) {
          NSTextField *status =
              [window.contentView viewWithTag:ACUShieldStatusTag];
          if (status != nil) {
              status.stringValue =
                  [NSString stringWithFormat:
                      @"模拟锁屏保护中\n按 Enter 认证，%d 秒后自动退出",
                      seconds];
          }
      }
    });
}

void acu_show_input_guard_failure(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gInputGuardFailureVisible) {
          return;
      }
      gInputGuardFailureVisible = YES;
      [NSApp activateIgnoringOtherApps:YES];

      NSAlert *alert = [NSAlert new];
      alert.messageText = @"物理输入保护异常";
      alert.informativeText =
          @"ACU 无法恢复输入拦截，遮罩仍会保留。"
           "请完成身份认证后退出保护并重新开启应用。";
      [alert addButtonWithTitle:@"开始身份认证"];
      [alert addButtonWithTitle:@"保持遮罩"];
      alert.window.level =
          CGWindowLevelForKey(kCGScreenSaverWindowLevelKey) + 1;
      alert.window.collectionBehavior =
          NSWindowCollectionBehaviorCanJoinAllSpaces |
          NSWindowCollectionBehaviorFullScreenAuxiliary |
          NSWindowCollectionBehaviorStationary;
      NSInteger response = [alert runModal];
      gInputGuardFailureVisible = NO;
      if (response == NSAlertFirstButtonReturn) {
          acuGuardianEnter();
      }
    });
}

double acu_idle_seconds(void) {
    return CGEventSourceSecondsSinceLastEventType(
        kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}

int acu_nudge_cursor(double distance, int restore_delay_ms, uint64_t marker) {
    CGEventRef current = CGEventCreate(NULL);
    if (current == NULL) {
        return 0;
    }
    CGPoint original = CGEventGetLocation(current);
    CFRelease(current);

    CGPoint moved = CGPointMake(original.x + distance, original.y);
    CGDirectDisplayID display;
    uint32_t count = 0;
    if (CGGetDisplaysWithPoint(moved, 1, &display, &count) != kCGErrorSuccess ||
        count == 0) {
        moved.x = original.x - distance;
    }

    CGEventRef out =
        CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, moved, kCGMouseButtonLeft);
    CGEventRef back =
        CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, original, kCGMouseButtonLeft);
    if (out == NULL || back == NULL) {
        if (out != NULL) {
            CFRelease(out);
        }
        if (back != NULL) {
            CFRelease(back);
        }
        return 0;
    }
    CGEventSetIntegerValueField(out, kCGEventSourceUserData, (int64_t)marker);
    CGEventSetIntegerValueField(back, kCGEventSourceUserData, (int64_t)marker);
    CGEventPost(kCGHIDEventTap, out);
    usleep((useconds_t)(restore_delay_ms * 1000));
    CGEventPost(kCGHIDEventTap, back);
    CFRelease(out);
    CFRelease(back);
    return 1;
}

int acu_authenticate(void) {
    @autoreleasepool {
        on_main_sync(^{
          [NSApp activateIgnoringOtherApps:YES];
        });

        LAContext *context = [LAContext new];
        context.localizedCancelTitle = @"保持保护";
        NSError *error = nil;
        if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                                  error:&error]) {
            return -1;
        }

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL success = NO;
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:@"解除 ACU 模拟锁屏"
                          reply:^(BOOL authenticated, NSError *replyError) {
                            (void)replyError;
                            success = authenticated;
                            dispatch_semaphore_signal(done);
                          }];
        for (int attempt = 0; attempt < 20; attempt++) {
            if (refresh_authentication_pid()) {
                break;
            }
            usleep(50000);
        }
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        return success ? 1 : 0;
    }
}

#define ACU_MAX_DISPLAYS 16

typedef bool (*ACUDisplayServicesCanChangeBrightness)(
    CGDirectDisplayID display);
typedef int (*ACUDisplayServicesGetLinearBrightness)(
    CGDirectDisplayID display,
    float *brightness);
typedef int (*ACUDisplayServicesSetLinearBrightness)(
    CGDirectDisplayID display,
    float brightness);

typedef enum {
    ACUBrightnessBackendNone,
    ACUBrightnessBackendDisplayServicesLinear,
    ACUBrightnessBackendIODisplay,
} ACUBrightnessBackend;

static struct {
    CGDirectDisplayID display;
    float brightness;
    ACUBrightnessBackend backend;
    int valid;
} gDisplayBrightness[ACU_MAX_DISPLAYS];
static pthread_mutex_t gBrightnessMutex = PTHREAD_MUTEX_INITIALIZER;
static ACUDisplayServicesCanChangeBrightness gCanChangeBrightness;
static ACUDisplayServicesGetLinearBrightness gGetLinearBrightness;
static ACUDisplayServicesSetLinearBrightness gSetLinearBrightness;

static void initialize_display_services(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *framework = dlopen(
          "/System/Library/PrivateFrameworks/DisplayServices.framework/"
          "DisplayServices",
          RTLD_LAZY | RTLD_LOCAL);
      if (framework == NULL) {
          return;
      }
      gCanChangeBrightness =
          (ACUDisplayServicesCanChangeBrightness)dlsym(
              framework, "DisplayServicesCanChangeBrightness");
      gGetLinearBrightness =
          (ACUDisplayServicesGetLinearBrightness)dlsym(
              framework, "DisplayServicesGetLinearBrightness");
      gSetLinearBrightness =
          (ACUDisplayServicesSetLinearBrightness)dlsym(
              framework, "DisplayServicesSetLinearBrightness");
      if (gCanChangeBrightness == NULL || gGetLinearBrightness == NULL ||
          gSetLinearBrightness == NULL) {
          gCanChangeBrightness = NULL;
          gGetLinearBrightness = NULL;
          gSetLinearBrightness = NULL;
      }
    });
}

static io_service_t io_display_service(CGDirectDisplayID display) {
    io_service_t framebuffer = CGDisplayIOServicePort(display);
    if (framebuffer != MACH_PORT_NULL) {
        return IODisplayForFramebuffer(framebuffer, 0);
    }
    return MACH_PORT_NULL;
}

static BOOL valid_brightness(float brightness) {
    return isfinite(brightness) && brightness >= 0.0f && brightness <= 1.0f;
}

static void clear_display_brightness(void) {
    for (uint32_t i = 0; i < ACU_MAX_DISPLAYS; i++) {
        gDisplayBrightness[i].valid = 0;
        gDisplayBrightness[i].display = 0;
        gDisplayBrightness[i].brightness = 0;
        gDisplayBrightness[i].backend = ACUBrightnessBackendNone;
    }
}

int acu_save_power_settings(void) {
    CGDirectDisplayID displays[ACU_MAX_DISPLAYS];
    uint32_t displayCount = 0;
    CGError listResult =
        CGGetOnlineDisplayList(ACU_MAX_DISPLAYS, displays, &displayCount);
    if (listResult != kCGErrorSuccess) {
        fprintf(stderr,
                "acu: list displays for dimming failed: %d\n",
                listResult);
        return 0;
    }
    uint32_t count =
        displayCount > ACU_MAX_DISPLAYS ? ACU_MAX_DISPLAYS : displayCount;

    pthread_mutex_lock(&gBrightnessMutex);
    if (gBrightnessSaved) {
        pthread_mutex_unlock(&gBrightnessMutex);
        return 1;
    }

    clear_display_brightness();
    BOOL saved = NO;
    initialize_display_services();
    for (uint32_t i = 0; i < count; i++) {
        float current = 0;
        ACUBrightnessBackend backend = ACUBrightnessBackendNone;

        if (gCanChangeBrightness != NULL &&
            gCanChangeBrightness(displays[i])) {
            // The regular brightness value is the user-slider domain and may
            // exceed the current panel output while auto brightness is active.
            int readResult =
                gGetLinearBrightness(displays[i], &current);
            if (readResult == kIOReturnSuccess &&
                valid_brightness(current)) {
                int writeResult =
                    gSetLinearBrightness(displays[i], 0.0f);
                if (writeResult == kIOReturnSuccess) {
                    backend = ACUBrightnessBackendDisplayServicesLinear;
                } else {
                    fprintf(
                        stderr,
                        "acu: dim display 0x%x failed: %d\n",
                        displays[i],
                        writeResult);
                    (void)gSetLinearBrightness(displays[i], current);
                    continue;
                }
            }
        }

        if (backend == ACUBrightnessBackendNone) {
            io_service_t service = io_display_service(displays[i]);
            if (service != MACH_PORT_NULL) {
                int readResult = IODisplayGetFloatParameter(
                    service, 0, CFSTR("brightness"), &current);
                if (readResult == kIOReturnSuccess &&
                    valid_brightness(current)) {
                    int writeResult = IODisplaySetFloatParameter(
                        service, 0, CFSTR("brightness"), 0.0f);
                    if (writeResult == kIOReturnSuccess) {
                        backend = ACUBrightnessBackendIODisplay;
                    } else {
                        fprintf(
                            stderr,
                            "acu: dim display 0x%x via IODisplay "
                            "failed: %d\n",
                            displays[i],
                            writeResult);
                        (void)IODisplaySetFloatParameter(
                            service,
                            0,
                            CFSTR("brightness"),
                            current);
                    }
                }
                IOObjectRelease(service);
            }
        }

        if (backend == ACUBrightnessBackendNone) {
            continue;
        }
        gDisplayBrightness[i].display = displays[i];
        gDisplayBrightness[i].brightness = current;
        gDisplayBrightness[i].backend = backend;
        gDisplayBrightness[i].valid = 1;
        saved = YES;
    }
    gBrightnessSaved = saved;
    pthread_mutex_unlock(&gBrightnessMutex);
    if (saved) {
        set_shield_background_animation_enabled(NO);
    }
    return saved ? 1 : 0;
}

int acu_restore_power_settings(void) {
    pthread_mutex_lock(&gBrightnessMutex);
    if (!gBrightnessSaved) {
        pthread_mutex_unlock(&gBrightnessMutex);
        return 1;
    }
    BOOL restored = YES;
    initialize_display_services();
    for (uint32_t i = 0; i < ACU_MAX_DISPLAYS; i++) {
        if (!gDisplayBrightness[i].valid) {
            continue;
        }
        int result = kIOReturnError;
        if (gDisplayBrightness[i].backend ==
                ACUBrightnessBackendDisplayServicesLinear &&
            gSetLinearBrightness != NULL) {
            result = gSetLinearBrightness(
                gDisplayBrightness[i].display,
                gDisplayBrightness[i].brightness);
        } else if (gDisplayBrightness[i].backend ==
                   ACUBrightnessBackendIODisplay) {
            io_service_t service =
                io_display_service(gDisplayBrightness[i].display);
            if (service != MACH_PORT_NULL) {
                result = IODisplaySetFloatParameter(
                    service,
                    0,
                    CFSTR("brightness"),
                    gDisplayBrightness[i].brightness);
                IOObjectRelease(service);
            }
        }
        if (result != kIOReturnSuccess) {
            fprintf(stderr,
                    "acu: restore display 0x%x brightness failed: %d\n",
                    gDisplayBrightness[i].display,
                    result);
            restored = NO;
        }
    }
    if (restored) {
        gBrightnessSaved = NO;
        clear_display_brightness();
    }
    pthread_mutex_unlock(&gBrightnessMutex);
    if (restored) {
        set_shield_background_animation_enabled(YES);
    }
    return restored ? 1 : 0;
}

int acu_keep_awake_persisted(void) {
    id stored =
        [[NSUserDefaults standardUserDefaults]
            objectForKey:ACUKeepAwakeEnabledKey];
    return stored == nil ? 0 : ([stored boolValue] ? 1 : 0);
}

void acu_set_keep_awake_persisted(int enabled) {
    [[NSUserDefaults standardUserDefaults]
        setBool:enabled != 0
         forKey:ACUKeepAwakeEnabledKey];
}
