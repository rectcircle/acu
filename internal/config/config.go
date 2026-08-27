package config

import "time"

type Config struct {
	PollInterval     time.Duration
	IdleBeforeNudge  time.Duration
	NudgeDistance    float64
	RestoreDelay     time.Duration
	FailureThreshold int
}

func Default() Config {
	return Config{
		PollInterval:     5 * time.Second,
		IdleBeforeNudge:  45 * time.Second,
		NudgeDistance:    1,
		RestoreDelay:     10 * time.Millisecond,
		FailureThreshold: 3,
	}
}

func (c Config) Validate() error {
	if c.PollInterval < time.Second {
		return errPollInterval
	}
	if c.IdleBeforeNudge <= 0 {
		return errIdleBeforeNudge
	}
	if c.NudgeDistance <= 0 {
		return errNudgeDistance
	}
	if c.RestoreDelay < 0 {
		return errRestoreDelay
	}
	if c.FailureThreshold < 1 {
		return errFailureThreshold
	}
	return nil
}
