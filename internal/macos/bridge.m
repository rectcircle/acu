#import "bridge.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <IOKit/hid/IOHIDManager.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <Security/Security.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unistd.h>

static NSStatusItem *gStatusItem;
static NSMenuItem *gStateItem;
static NSMenuItem *gEnableMenuItem;
static NSMenuItem *gKeepAwakeMenuItem;
static NSMenuItem *gLidAutomationMenuItem;
static NSMenuItem *gLidAngleRootItem;
static NSArray<NSMenuItem *> *gLidAngleMenuItems;
static NSMenuItem *gHotKeyRootItem;
static NSArray<NSMenuItem *> *gHotKeyMenuItems;
static NSMutableArray<NSPanel *> *gShieldWindows;
static id gMenuTarget;
static id gScreenObserver;
static int gShieldCountdown = -1;
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
static NSString *const ACUTrustedTeamIdentifiersKey =
    @"ACUTrustedTeamIdentifiers";
static NSString *const ACULidAutomationEnabledKey =
    @"ACULidAutomationEnabled";
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
static atomic_int gTrustedPIDs[64];
static atomic_size_t gTrustedPIDCount;
static atomic_uint_fast64_t gTrustedPIDGeneration;

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

static const OSType ACUHotKeySignature = 0x41435548; // ACUH
static const UInt32 ACUHotKeyIdentifier = 1;
static const NSInteger ACULidDefaultThreshold = 45;

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

        gStatusItem.button.title = @"ACU";
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
      @"acu-helper-restart",
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
    alert.messageText = @"无法重新启动 ACU Helper";
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
          @"需要重新启动 ACU Helper 才能可靠应用新的系统权限。";
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
               "1. 在打开的系统设置页面中启用“ACU Helper”。\n"
               "2. 检测到授权后，按提示立即重启 ACU Helper。"];
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

static NSString *team_identifier_for_pid(pid_t pid) {
    NSDictionary *attributes = @{
      (__bridge NSString *)kSecGuestAttributePid : @(pid),
    };
    SecCodeRef code = NULL;
    if (SecCodeCopyGuestWithAttributes(
            NULL,
            (__bridge CFDictionaryRef)attributes,
            kSecCSDefaultFlags,
            &code) != errSecSuccess ||
        code == NULL) {
        return nil;
    }

    CFDictionaryRef signingInformation = NULL;
    OSStatus status =
        SecCodeCopySigningInformation(
            code, kSecCSSigningInformation, &signingInformation);
    CFRelease(code);
    if (status != errSecSuccess || signingInformation == NULL) {
        return nil;
    }

    NSDictionary *information =
        (__bridge NSDictionary *)signingInformation;
    NSString *teamIdentifier =
        information[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    NSString *result = [teamIdentifier copy];
    CFRelease(signingInformation);
    return result;
}

static void clear_trusted_pids(void) {
    atomic_store_explicit(&gTrustedPIDCount, 0, memory_order_release);
}

static void refresh_trusted_pids(uint64_t generation) {
    pid_t trustedPIDs[64];
    size_t trustedPIDCount = 0;
    id stored =
        [[NSUserDefaults standardUserDefaults]
            objectForKey:ACUTrustedTeamIdentifiersKey];
    if (![stored isKindOfClass:[NSArray class]]) {
        return;
    }
    NSSet<NSString *> *trustedTeams =
        [NSSet setWithArray:(NSArray<NSString *> *)stored];
    if (trustedTeams.count == 0) {
        return;
    }

    for (NSRunningApplication *application
             in [[NSWorkspace sharedWorkspace] runningApplications]) {
        NSString *teamIdentifier =
            team_identifier_for_pid(application.processIdentifier);
        BOOL trusted =
            teamIdentifier != nil &&
            [trustedTeams containsObject:teamIdentifier];
        if (trusted && trustedPIDCount < 64) {
            trustedPIDs[trustedPIDCount++] = application.processIdentifier;
        }
    }

    if (generation != atomic_load_explicit(
                          &gTrustedPIDGeneration, memory_order_acquire)) {
        return;
    }
    for (size_t index = 0; index < trustedPIDCount; index++) {
        atomic_store_explicit(
            &gTrustedPIDs[index], trustedPIDs[index], memory_order_relaxed);
    }
    atomic_store_explicit(
        &gTrustedPIDCount, trustedPIDCount, memory_order_release);
}

static void refresh_trusted_pids_async(uint64_t generation) {
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          @autoreleasepool {
              refresh_trusted_pids(generation);
          }
        });
}

static bool is_trusted_pid(pid_t pid) {
    size_t count =
        atomic_load_explicit(&gTrustedPIDCount, memory_order_acquire);
    for (size_t index = 0; index < count; index++) {
        if (atomic_load_explicit(
                &gTrustedPIDs[index], memory_order_relaxed) == pid) {
            return true;
        }
    }
    return false;
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
            return NULL;
        }
        if (type == kCGEventMouseMoved) {
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

    if (!physical && is_trusted_pid((pid_t)sourcePID)) {
        return event;
    }

    if (physical) {
        acuPhysicalActivity();
    }

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
    uint64_t trustedPIDGeneration =
        atomic_fetch_add_explicit(
            &gTrustedPIDGeneration, 1, memory_order_acq_rel) + 1;
    clear_trusted_pids();
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
    refresh_trusted_pids_async(trustedPIDGeneration);
    return result;
}

void acu_stop_input_guard(void) {
    atomic_fetch_add_explicit(
        &gTrustedPIDGeneration, 1, memory_order_acq_rel);
    clear_trusted_pids();
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

    NSView *content = panel.contentView;
    NSTextField *title = [NSTextField labelWithString:@"ACU Helper"];
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
    [NSLayoutConstraint activateConstraints:@[
      [title.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
      [title.centerYAnchor constraintEqualToAnchor:content.centerYAnchor
                                          constant:-24],
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
                [window close];
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
        [window close];
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
      if (gScreenObserver != nil) {
          [[NSNotificationCenter defaultCenter] removeObserver:gScreenObserver];
          gScreenObserver = nil;
      }
      for (NSPanel *window in gShieldWindows) {
          [window close];
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
          @"ACU Helper 无法恢复输入拦截，遮罩仍会保留。"
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
                localizedReason:@"解除 ACU Helper 模拟锁屏"
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

typedef int (*ACUDisplayServicesCanChangeBrightness)(
    CGDirectDisplayID display);
typedef int (*ACUDisplayServicesGetBrightness)(
    CGDirectDisplayID display,
    float *brightness);
typedef int (*ACUDisplayServicesSetBrightness)(
    CGDirectDisplayID display,
    float brightness);

typedef enum {
    ACUBrightnessBackendNone,
    ACUBrightnessBackendDisplayServices,
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
static ACUDisplayServicesGetBrightness gGetBrightness;
static ACUDisplayServicesSetBrightness gSetBrightness;

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
      gGetBrightness =
          (ACUDisplayServicesGetBrightness)dlsym(
              framework, "DisplayServicesGetBrightness");
      gSetBrightness =
          (ACUDisplayServicesSetBrightness)dlsym(
              framework, "DisplayServicesSetBrightness");
      if (gCanChangeBrightness == NULL || gGetBrightness == NULL ||
          gSetBrightness == NULL) {
          gCanChangeBrightness = NULL;
          gGetBrightness = NULL;
          gSetBrightness = NULL;
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
    if (CGGetOnlineDisplayList(ACU_MAX_DISPLAYS, displays, &displayCount) !=
        kCGErrorSuccess) {
        return 0;
    }
    uint32_t count = displayCount > ACU_MAX_DISPLAYS ? ACU_MAX_DISPLAYS : displayCount;

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
        int readResult = kIOReturnError;
        int writeResult = kIOReturnError;

        if (gCanChangeBrightness != NULL &&
            gCanChangeBrightness(displays[i]) != 0) {
            readResult = gGetBrightness(displays[i], &current);
            writeResult = readResult == kIOReturnSuccess
                ? gSetBrightness(displays[i], 0.0f)
                : kIOReturnError;
            if (readResult == kIOReturnSuccess &&
                writeResult == kIOReturnSuccess) {
                backend = ACUBrightnessBackendDisplayServices;
            }
        }

        if (backend == ACUBrightnessBackendNone) {
            io_service_t service = io_display_service(displays[i]);
            if (service != MACH_PORT_NULL) {
                readResult = IODisplayGetFloatParameter(
                    service, 0, CFSTR("brightness"), &current);
                writeResult = readResult == kIOReturnSuccess
                    ? IODisplaySetFloatParameter(
                          service, 0, CFSTR("brightness"), 0.0f)
                    : kIOReturnError;
                if (readResult == kIOReturnSuccess &&
                    writeResult == kIOReturnSuccess) {
                    backend = ACUBrightnessBackendIODisplay;
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
                ACUBrightnessBackendDisplayServices &&
            gSetBrightness != NULL) {
            result = gSetBrightness(
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
            restored = NO;
        }
    }
    if (restored) {
        gBrightnessSaved = NO;
        clear_display_brightness();
    }
    pthread_mutex_unlock(&gBrightnessMutex);
    return restored ? 1 : 0;
}
