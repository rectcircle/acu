package main

import (
	"fmt"
	"os"
	"runtime"

	"github.com/rectcircle/acu-helper/internal/app"
	"github.com/rectcircle/acu-helper/internal/config"
	"github.com/rectcircle/acu-helper/internal/guardian"
	"github.com/rectcircle/acu-helper/internal/ipc"
)

func main() {
	runtime.LockOSThread()

	var err error
	if len(os.Args) == 2 && os.Args[1] == "guardian" {
		err = runGuardian()
	} else {
		err = app.Run()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "acu-helper:", err)
		os.Exit(1)
	}
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
