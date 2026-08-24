package main

import (
	"os"
	"testing"
)

func TestReadNodeTokenClearsEnvironment(t *testing.T) {
	t.Setenv("GOCRON_NODE_TOKEN", "shared-token")
	if got := readNodeToken(""); got != "shared-token" {
		t.Fatalf("readNodeToken() = %q, want shared-token", got)
	}
	if got := os.Getenv("GOCRON_NODE_TOKEN"); got != "" {
		t.Fatalf("GOCRON_NODE_TOKEN remains in environment: %q", got)
	}
}

func TestReadNodeTokenPrefersCommandLine(t *testing.T) {
	t.Setenv("GOCRON_NODE_TOKEN", "environment-token")
	if got := readNodeToken("command-line-token"); got != "command-line-token" {
		t.Fatalf("readNodeToken() = %q, want command-line-token", got)
	}
}
