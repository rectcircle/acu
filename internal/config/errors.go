package config

import "errors"

var (
	errPollInterval     = errors.New("poll interval must be at least one second")
	errIdleBeforeNudge  = errors.New("idle-before-nudge must be positive")
	errNudgeDistance    = errors.New("nudge distance must be positive")
	errRestoreDelay     = errors.New("restore delay cannot be negative")
	errFailureThreshold = errors.New("failure threshold must be positive")
)
