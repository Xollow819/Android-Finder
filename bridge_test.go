package main

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sample = "Android Finder transfer test\n"

type samplePhone struct{}

func (samplePhone) list(_ context.Context, directory mtpObject) ([]mtpObject, error) {
	switch {
	case directory.storage == 0:
		return []mtpObject{{name: "Internal Storage", storage: 1, directory: true}}, nil
	case directory.id == 0:
		return []mtpObject{{name: "USB test.txt", id: 1, storage: 1, size: int64(len(sample))}}, nil
	default:
		return nil, os.ErrNotExist
	}
}

func (samplePhone) readAt(context.Context, mtpObject, []byte, int64) (int, error) {
	return 0, errPartialUnavailable
}

func (samplePhone) download(_ context.Context, _ mtpObject, destination *os.File) error {
	_, err := destination.WriteString(sample)
	return err
}

func testBridge(t *testing.T) *bridge {
	t.Helper()
	fs := &androidFS{storage: samplePhone{}, tempDir: t.TempDir(), folders: make(map[[2]uint32]folderCache)}
	bridge, err := startBridge(fs)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bridge.close)
	return bridge
}

func TestReadOnlyBridge(t *testing.T) {
	b := testBridge(t)
	for _, check := range []struct {
		method, path string
		auth         bool
		status       int
		match        string
	}{
		{"GET", "Internal%20Storage/USB%20test.txt", false, 401, ""},
		{"PROPFIND", "", true, 207, "Internal%20Storage"},
		{"GET", "Internal%20Storage/USB%20test.txt", true, 206, "Android"},
		{"PUT", "Internal%20Storage/USB%20test.txt", true, 405, ""},
		{"DELETE", "Internal%20Storage/USB%20test.txt", true, 405, ""},
	} {
		req, err := http.NewRequest(check.method, b.address+check.path, nil)
		if err != nil {
			t.Fatal(err)
		}
		if check.auth {
			req.SetBasicAuth("androidfinder", b.password)
		}
		req.Header.Set("Depth", "1")
		req.Header.Set("Range", "bytes=0-6")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != check.status || !strings.Contains(string(body), check.match) {
			t.Errorf("%s %s returned %d %q", check.method, check.path, resp.StatusCode, body)
		}
	}
}

func TestMacOSMount(t *testing.T) {
	if os.Getenv("ANDROID_FINDER_TEST_MOUNT") != "1" {
		t.Skip("set ANDROID_FINDER_TEST_MOUNT=1 to exercise macOS WebDAV")
	}
	b := testBridge(t)
	temp, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	mount := filepath.Join(temp, "Android")
	if err := os.Mkdir(mount, 0700); err != nil {
		t.Fatal(err)
	}
	if err := b.mount(mount); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := unmountVolume(mount); err != nil {
			t.Error(err)
		}
	})
	mounted, err := mountedHere(mount)
	if err != nil || !mounted {
		t.Fatalf("expected mounted at %q, got %v, %v", mount, mounted, err)
	}
	body, err := os.ReadFile(filepath.Join(mount, "Internal Storage", "USB test.txt"))
	if err != nil || string(body) != sample {
		t.Fatalf("read through macOS mount = %q, %v", body, err)
	}
	if err := os.WriteFile(filepath.Join(mount, "new.txt"), []byte("reject"), 0600); err == nil {
		t.Fatal("mount allowed a write")
	}
}
