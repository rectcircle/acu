#ifndef ACU_HELPER_BRIDGE_H
#define ACU_HELPER_BRIDGE_H

#include <stdint.h>

enum {
    ACU_MENU_ENABLE = 1,
    ACU_MENU_TEST = 2,
    ACU_MENU_UNLOCK = 3,
    ACU_MENU_DIAGNOSTICS = 4,
    ACU_MENU_QUIT = 5,
    ACU_MENU_KEEP_AWAKE = 6,
    ACU_MENU_LID_CONFIGURATION = 7,
};

enum {
    ACU_PREFLIGHT_ACCESSIBILITY = 1 << 0,
    ACU_PREFLIGHT_LISTEN_EVENTS = 1 << 1,
    ACU_PREFLIGHT_POST_EVENTS = 1 << 2,
    ACU_PREFLIGHT_AUTH = 1 << 3,
    ACU_PREFLIGHT_DISPLAY = 1 << 4,
    ACU_PREFLIGHT_SESSION_LOCKED = 1 << 5,
};

int acu_init_menu(void);
void acu_run_app(void);
void acu_stop_app(void);
void acu_set_menu_state(const char *state);
void acu_set_keep_awake_active(int active);
int acu_show_alert(const char *title, const char *message, int confirm);
void acu_show_preflight_alert(const char *title,
                              const char *message,
                              uint32_t failures);

int acu_preflight(int request_permissions);
int acu_preflight_keep_awake(int request_permissions);
int acu_managed_policy_status(void);
int acu_session_locked(void);
int acu_lid_automation_enabled(void);
double acu_lid_angle_threshold(void);
int acu_read_lid_angle(double *angle);
int acu_has_external_display(void);

int acu_start_input_guard(uint64_t marker);
void acu_stop_input_guard(void);
void acu_set_input_authentication_mode(int enabled);

int acu_show_shields(void);
void acu_hide_shields(void);
void acu_set_shield_authentication_mode(int enabled);
void acu_set_shield_countdown(int seconds);
void acu_show_input_guard_failure(void);

double acu_idle_seconds(void);
int acu_nudge_cursor(double distance, int restore_delay_ms, uint64_t marker);
int acu_authenticate(void);

int acu_save_power_settings(void);
int acu_restore_power_settings(void);

int acu_keep_awake_persisted(void);
void acu_set_keep_awake_persisted(int enabled);

void acuMenuAction(int action);
void acuGuardianEnter(void);
void acuTapDegraded(void);
void acuPhysicalActivity(void);
void acuLidAngleChanged(void);

#endif
