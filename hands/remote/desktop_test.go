package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// Run inside the desktop image as an unprivileged user. The local fixture owns
// only signaling; the compositor, screenshot and input are the real binaries.
func TestServerDesktopLifecycle(t *testing.T) {
	testServerDesktopLifecycle(t, false)
}

func TestFramesDesktopLifecycle(t *testing.T) {
	testServerDesktopLifecycle(t, true)
}

func testServerDesktopLifecycle(t *testing.T, frames bool) {
	if os.Getenv("NANOCODEX_TEST_SERVER_DESKTOP") != "1" {
		t.Skip("requires the isolated Linux desktop image")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	const owner = "11111111-1111-4111-8111-111111111111"
	const id = "22222222-2222-4222-8222-222222222222"
	const prefix = "/v1/hand-hosts/" + owner + "/" + id + "/hands"
	var token atomic.Value
	token.Store(strings.Repeat("a", 43))
	type publication struct {
		socket     *websocket.Conn
		generation string
		messages   chan remoteMessage
	}
	published := make(chan publication, 4)
	var generation atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token.Load().(string) {
			http.Error(w, "unauthorized", 401)
			return
		}
		if r.URL.Path != prefix+"/host" {
			http.NotFound(w, r)
			return
		}
		socket, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer socket.CloseNow()
		socket.SetReadLimit(800_000)
		p := publication{socket, fmt.Sprintf("generation-%d", generation.Add(1)), make(chan remoteMessage, 16)}
		defer close(p.messages)
		send := func(message remoteMessage) error {
			data, _ := json.Marshal(message)
			return socket.Write(ctx, websocket.MessageText, data)
		}
		if send(remoteMessage{Type: "ready", ConnectionID: p.generation}) != nil {
			return
		}
		for {
			_, data, err := socket.Read(ctx)
			if err != nil {
				return
			}
			message := remoteMessage{agentResult: &agentResult{}}
			if json.Unmarshal(data, &message) != nil {
				return
			}
			if message.Type == "catalog" {
				if message.MachineID != "server:"+id || len(message.Surfaces) != 1 || message.Surfaces[0].Kind != "desktop" {
					t.Error("invalid server publication")
					return
				}
				if send(remoteMessage{Type: "published", Generation: p.generation}) != nil {
					return
				}
				select {
				case published <- p:
				case <-ctx.Done():
					return
				}
			} else {
				select {
				case p.messages <- message:
				case <-ctx.Done():
					return
				}
			}
		}
	}))
	defer server.Close()
	workspace := t.TempDir()
	credential := filepath.Join(workspace, "credential")
	writeCredential := func(value string) {
		if err := os.WriteFile(credential+".next", []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(credential+".next", credential); err != nil {
			t.Fatal(err)
		}
	}
	writeCredential(token.Load().(string))
	command := exec.CommandContext(ctx, "/usr/local/bin/nanocodex-remote", "server-host", "--url", server.URL+prefix,
		"--credential-file", credential, "--machine-id", "server:"+id, "--name", "Server lifecycle test", "--workspace", workspace)
	if frames {
		command.Args = append(command.Args, "--frames")
	}
	var diagnostics bytes.Buffer
	command.Stdout, command.Stderr = &diagnostics, &diagnostics
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() { finished <- command.Wait() }()
	defer func() { cancel(); <-finished; t.Log(diagnostics.String()) }()
	waitPublished := func() publication {
		t.Helper()
		select {
		case p := <-published:
			return p
		case <-ctx.Done():
			t.Fatal("server did not publish")
		}
		return publication{}
	}
	first := waitPublished()
	child := func(name string) string {
		data, err := exec.Command("pgrep", "-P", fmt.Sprint(command.Process.Pid), name).Output()
		if err != nil {
			t.Fatal("missing owned desktop process", name, err)
		}
		return strings.TrimSpace(string(data))
	}
	pid, capturePID := child("labwc"), child("waymote-streamd")
	// Publication can precede the terminal's first mapped surface. Wait for its
	// interactive shell before injecting a click into the center of the desktop.
	terminalDeadline := time.Now().Add(5 * time.Second)
	for {
		shells, _ := exec.Command("pgrep", "-x", "bash").Output()
		ready := false
		for _, pid := range strings.Fields(string(shells)) {
			cwd, _ := os.Readlink("/proc/" + pid + "/cwd")
			terminal, _ := os.Readlink("/proc/" + pid + "/fd/0")
			if cwd == workspace && strings.HasPrefix(terminal, "/dev/pts/") {
				ready = true
			}
		}
		if ready {
			break
		}
		if time.Now().After(terminalDeadline) {
			t.Fatal("desktop terminal did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	waitMarker := func(expected string) {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for {
			data, _ := os.ReadFile(filepath.Join(workspace, "server-marker"))
			if string(data) == expected {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("terminal input did not complete")
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	if frames {
		send := func(message remoteMessage) {
			data, err := json.Marshal(message)
			if err != nil {
				t.Fatal(err)
			}
			if err := first.socket.Write(ctx, websocket.MessageText, data); err != nil {
				t.Fatal(err)
			}
		}
		next := func() remoteMessage {
			select {
			case message, open := <-first.messages:
				if !open {
					t.Fatal("frame publisher closed")
				}
				return message
			case <-ctx.Done():
				t.Fatal("missing frame response")
			}
			return remoteMessage{}
		}
		send(remoteMessage{Type: "viewer", ViewerID: owner, SurfaceID: "desktop", Generation: first.generation})
		send(remoteMessage{Type: "frame_request", ViewerID: owner})
		frame := next()
		if frame.Type != "frame" || frame.JPEG == "" || frame.Width != 1280 || frame.Height != 720 || frame.Status != "" {
			t.Fatal("invalid relay frame")
		}
		data, _ := base64.StdEncoding.DecodeString(frame.JPEG)
		if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
			t.Fatal(err)
		}
		send(remoteMessage{Type: "control", ViewerID: owner, Data: json.RawMessage(`{"type":"acquire"}`)})
		granted := next()
		var control controlMessage
		if json.Unmarshal(granted.Data, &control) != nil || control.Type != "granted" {
			t.Fatal("frame control not granted")
		}
		inputs := []remoteInput{
			{Kind: "button", X: pointer(0.5), Y: pointer(0.5), Button: pointer(0), Down: pointer(true)},
			{Kind: "button", X: pointer(0.5), Y: pointer(0.5), Button: pointer(0), Down: pointer(false)},
			{Kind: "text", Text: pointer("printf frame-input > frame-marker")},
			{Kind: "key", Key: pointer(uint16(40)), Down: pointer(true)},
			{Kind: "key", Key: pointer(uint16(40)), Down: pointer(false)},
		}
		for i, input := range inputs {
			input.Sequence = uint64(i + 1)
			input.Generation = control.Generation
			data, _ := json.Marshal(input)
			send(remoteMessage{Type: "input", ViewerID: owner, Data: data})
		}
		deadline := time.Now().Add(3 * time.Second)
		for {
			data, _ := os.ReadFile(filepath.Join(workspace, "frame-marker"))
			if string(data) == "frame-input" {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("frame transport input did not reach terminal")
			}
			time.Sleep(25 * time.Millisecond)
		}
		release, _ := json.Marshal(controlMessage{Type: "release", Generation: control.Generation})
		send(remoteMessage{Type: "control", ViewerID: owner, Data: release})
		if reply := next(); reply.Type != "control" {
			t.Fatal("release was not acknowledged")
		}
		send(remoteMessage{Type: "viewer_left", ViewerID: owner})
		if reply := next(); reply.Type != "close_viewer" {
			t.Fatal("viewer was not closed")
		}
	}
	perform := func(p publication, input agentInput) {
		t.Helper()
		message := remoteMessage{Type: "agent_call", AgentID: "server-test", RequestID: id,
			Generation: p.generation, SurfaceID: "desktop", DeadlineAt: time.Now().Add(5 * time.Second).UnixMilli(), Input: &input}
		data, _ := json.Marshal(message)
		if err := p.socket.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatal(err)
		}
		select {
		case reply, open := <-p.messages:
			if !open {
				t.Fatal("publisher disconnected during input")
			}
			if reply.Type != "agent_result" || reply.agentResult == nil || reply.Status != "ok" {
				t.Fatalf("input failed: %+v", reply)
			}
			jpegBytes, err := base64.StdEncoding.DecodeString(reply.JPEG)
			if err != nil {
				t.Fatal(err)
			}
			if directory := os.Getenv("NANOCODEX_TEST_ARTIFACTS"); directory != "" {
				_ = os.WriteFile(filepath.Join(directory, t.Name()+".jpg"), jpegBytes, 0600)
			}
			frame, err := jpeg.DecodeConfig(bytes.NewReader(jpegBytes))
			if err != nil || frame.Width != 1280 || frame.Height != 720 || reply.Width != frame.Width || reply.Height != frame.Height {
				t.Fatal("invalid desktop snapshot", frame, err)
			}
		case <-ctx.Done():
			t.Fatal("input did not complete")
		}
	}
	perform(first, agentInput{Action: "click", X: pointer(0.5), Y: pointer(0.5)})
	perform(first, agentInput{Action: "type", Text: pointer("printf server-input > server-marker")})
	perform(first, agentInput{Action: "key", Key: pointer(uint16(40))})
	waitMarker("server-input")

	token.Store(strings.Repeat("b", 43))
	writeCredential(token.Load().(string))
	second := waitPublished()
	if second.generation == first.generation || child("labwc") != pid || child("waymote-streamd") != capturePID {
		t.Fatal("credential rotation restarted desktop capture or input")
	}
	perform(second, agentInput{Action: "observe"})
	second.socket.CloseNow()
	third := waitPublished()
	if third.generation == second.generation || child("labwc") != pid || child("waymote-streamd") != capturePID {
		t.Fatal("signaling reconnect restarted desktop capture or input")
	}
	perform(third, agentInput{Action: "type", Text: pointer("printf reconnected >> server-marker")})
	perform(third, agentInput{Action: "key", Key: pointer(uint16(40))})
	waitMarker("server-inputreconnected")

	writeCredential("")
	select {
	case err := <-finished:
		finished <- err // The deferred cleanup owns the final wait.
		if err != nil {
			t.Fatal("credential revocation did not stop cleanly", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("revoked desktop remained running")
	}
	if _, err := os.Stat(credential + ".ready"); !os.IsNotExist(err) {
		t.Fatal("readiness survived shutdown")
	}
	if exec.Command("kill", "-0", pid).Run() == nil {
		t.Fatal("owned compositor survived shutdown")
	}
	if exec.Command("kill", "-0", capturePID).Run() == nil {
		t.Fatal("owned desktop capture survived shutdown")
	}
}
