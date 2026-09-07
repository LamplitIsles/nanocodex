package main

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// The VM owner runs this process through its trusted guest command channel.
// Its private credential file is atomically replaced on lease rotation and
// emptied on shutdown. The compositor survives signaling/credential reconnects.
func serveDesktop(parent context.Context, config hostConfig, workspace string) error {
	if !filepath.IsAbs(workspace) {
		return errors.New("desktop workspace must be absolute")
	}
	service, err := newRemoteService(config.Origin, config.CredentialFile)
	if err != nil {
		return err
	}
	if !strings.HasPrefix(service.base.Path, "/v1/vm-host-attachments/") {
		return errors.New("VM desktops require an allocation-scoped endpoint")
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	runtime, err := os.MkdirTemp("/run", "nanocodex-desktop-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(runtime)
	// This executable owns its process environment and all desktop children.
	for key, value := range map[string]string{
		"XDG_RUNTIME_DIR": runtime, "WAYLAND_DISPLAY": "wayland-0",
		"WLR_BACKENDS": "headless", "WLR_RENDERER": "pixman", "WLR_HEADLESS_OUTPUTS": "1",
		"XDG_SESSION_TYPE": "wayland", "XDG_CURRENT_DESKTOP": "labwc",
	} {
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}
	compositor := exec.CommandContext(ctx, "labwc", "--config-dir", "/etc/nanocodex-desktop")
	compositor.Dir = workspace
	compositor.Stdout, compositor.Stderr = io.Discard, io.Discard
	compositor.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	compositor.Cancel = func() error {
		err := syscall.Kill(-compositor.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	compositor.WaitDelay = time.Second
	if err := compositor.Start(); err != nil {
		return errors.New("cannot start VM compositor")
	}
	done := make(chan struct{})
	go func() { _ = compositor.Wait(); cancel(); close(done) }()
	defer func() { cancel(); <-done }()
	readyPath := config.CredentialFile + ".ready"
	_ = os.Remove(readyPath)
	defer os.Remove(readyPath)
	deadline := time.NewTimer(20 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if info, err := os.Stat(filepath.Join(runtime, "wayland-0")); err == nil && info.Mode()&os.ModeSocket != 0 {
			break
		}
		select {
		case <-ctx.Done():
			return errors.New("VM compositor stopped")
		case <-deadline.C:
			return errors.New("VM compositor did not become ready")
		case <-tick.C:
		}
	}
	config.quiet = true
	// Compositor readiness is independent of the remote signaling service.
	// A relay outage must not prevent the VM's shell attachment from starting.
	if err := os.WriteFile(readyPath, []byte("ready\n"), 0600); err != nil {
		return err
	}
	statusPath := config.CredentialFile + ".status"
	defer os.Remove(statusPath)
	config.published = func() { _ = os.WriteFile(statusPath, []byte("published\n"), 0600) }
	for ctx.Err() == nil {
		hostCtx, stop := context.WithCancel(ctx)
		finished := make(chan error, 1)
		go func() { finished <- serveWayland(hostCtx, config) }()
		changed := false
		for !changed {
			select {
			case <-ctx.Done():
				stop()
				<-finished
				return ctx.Err()
			case err := <-finished:
				if err != nil {
					_ = os.WriteFile(statusPath, []byte(err.Error()+"\n"), 0600)
				}
				changed = true
			case <-tick.C:
				next, err := newRemoteService(config.Origin, config.CredentialFile)
				if err != nil {
					stop()
					<-finished
					return nil
				} // Cleared/revoked by owner.
				if next.token != service.token {
					service = next
					stop()
					<-finished
					changed = true
				}
			}
		}
		stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return ctx.Err()
}
