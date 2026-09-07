package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoteServiceKeepsAllocationCredentialScoped(t *testing.T) {
	credential := filepath.Join(t.TempDir(), "credential")
	if err := os.WriteFile(credential, []byte("allocation-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
	allocation := "/v1/vm-host-attachments/" + strings.Repeat("p", 43) + "/11111111-1111-4111-8111-111111111111/hands"
	server := "/v1/hand-hosts/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/hands"
	for _, test := range []struct{ origin, path string }{
		{"https://managed.example", "/v1/account/hands"},
		{"http://127.0.0.1:4011/", "/v1/account/hands"},
		{"https://managed.example" + allocation, allocation},
		{"https://managed.example" + server, server},
	} {
		service, err := newRemoteService(test.origin, credential)
		if err != nil || service.base.Path != test.path {
			t.Fatalf("valid endpoint: %v", err)
		}
	}
	for _, origin := range []string{
		"http://managed.example", "https://user:password@managed.example", "https://managed.example?token=secret",
		"https://managed.example#fragment", "https://managed.example/v1/account/hands",
		"https://managed.example" + allocation + "/view", "https://managed.example" + strings.Replace(allocation, "/hands", "/%68ands", 1),
		"https://managed.example" + server + "/view", "https://managed.example" + strings.Replace(server, "/hands", "/%68ands", 1),
	} {
		if _, err := newRemoteService(origin, credential); err == nil {
			t.Fatalf("accepted invalid endpoint %q", origin)
		}
	}
}

func TestRemoteCredentialIsPrivateAndBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "credential")
	for _, test := range []struct {
		token string
		mode  os.FileMode
	}{
		{"", 0600}, {"one\ntwo", 0600}, {strings.Repeat("x", 8193), 0600}, {"secret", 0644},
	} {
		if err := os.WriteFile(path, []byte(test.token), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, test.mode); err != nil {
			t.Fatal(err)
		}
		if _, err := newRemoteService("https://managed.example", path); err == nil {
			t.Fatal("accepted invalid credential file")
		}
	}
}
