package main

import (
	"fmt"
	"log/slog"
	"os"
	"runtime"

	"github.com/rectcircle/acu/internal/app"
	"github.com/rectcircle/acu/internal/config"
	"github.com/rectcircle/acu/internal/guardian"
	"github.com/rectcircle/acu/internal/ipc"
	"github.com/rectcircle/acu/internal/logging"
)

func main() {
	runtime.LockOSThread()

	role := "controller"
	if len(os.Args) == 2 && os.Args[1] == "guardian" {
		role = "guardian"
	}
	closeLogs, logErr := logging.Init(role)
	defer closeLogs()
	if logErr != nil {
		slog.Warn("persistent logging unavailable", "error", logErr)
	}
	slog.Info("process started")
	var err error
	if len(os.Args) == 2 && os.Args[1] == "guardian" {
		err = runGuardian()
	} else {
		err = app.Run()
	}
	if err != nil {
		slog.Error("process failed", "error", err)
		os.Exit(1)
	}
	slog.Info("process stopped")
}

func runGuardian() error {
	controllerReader := os.NewFile(3, "controller-to-guardian")
	controllerWriter := os.NewFile(4, "guardian-to-controller")
	if controllerReader == nil || controllerWriter == nil {
		return fmt.Errorf("guardian IPC descriptors are unavailable")
	}
	conn := ipc.New(
		controllerReader,
		controllerWriter,
		controllerReader,
		controllerWriter,
	)
	defer conn.Close()
	return guardian.Run(conn, config.Default())
}
