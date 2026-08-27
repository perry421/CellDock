package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestBlockedStageKeepsRuntimeHealthyUntilStopped(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status.json")
	store := &statusStore{path: path, s: status{Running: true, Phase: "starting"}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := store.block(ctx, "tunnel_blocked", errors.New("IKE response timeout")); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got status
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if !got.Running || got.Phase != "tunnel_blocked" || got.LastErrorClass != "" || got.LastReason != "IKE response timeout" {
		t.Fatalf("blocked status=%+v", got)
	}
}

func TestShouldProtectOuterIP(t *testing.T) {
	for _, value := range []string{"127.0.0.1", "127.20.30.40", "::1", "0.0.0.0", "::"} {
		if shouldProtectOuterIP(net.ParseIP(value)) {
			t.Fatalf("should not protect local address %s", value)
		}
	}
	for _, value := range []string{"1.1.1.1", "208.54.39.131", "2001:4860:4860::8888"} {
		if !shouldProtectOuterIP(net.ParseIP(value)) {
			t.Fatalf("should protect outer address %s", value)
		}
	}
}

func TestDirectEPDGCandidatesPreferIPv4AndDeduplicate(t *testing.T) {
	got := directEPDGCandidates([]net.IPAddr{
		{IP: net.ParseIP("2001:db8::1")},
		{IP: net.ParseIP("208.54.39.131")},
		{IP: net.ParseIP("208.54.39.131")},
		{IP: net.ParseIP("208.54.5.195")},
	}, 3)
	want := []string{"208.54.39.131", "208.54.5.195", "2001:db8::1"}
	if len(got) != len(want) {
		t.Fatalf("candidates=%v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("candidates=%v, want %v", got, want)
		}
	}
}

func TestRepeatDirectEPDGCandidatesUsesCompleteRounds(t *testing.T) {
	got := repeatDirectEPDGCandidates([]string{"192.0.2.1", "192.0.2.2"}, 2)
	want := []string{"192.0.2.1", "192.0.2.2", "192.0.2.1", "192.0.2.2"}
	if len(got) != len(want) {
		t.Fatalf("candidates=%v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("candidates=%v, want %v", got, want)
		}
	}
	if got := repeatDirectEPDGCandidates([]string{"192.0.2.1"}, 0); got != nil {
		t.Fatalf("zero rounds=%v, want nil", got)
	}
}

func TestRetryableDirectEPDGError(t *testing.T) {
	if !isRetryableDirectEPDGError(errors.New("SWU tunnel establishment failed: read udp: i/o timeout")) ||
		isRetryableDirectEPDGError(errors.New("IMS registration failed: i/o timeout")) ||
		isRetryableDirectEPDGError(errors.New("AKA authentication rejected")) {
		t.Fatal("direct ePDG retry classification changed")
	}
}
