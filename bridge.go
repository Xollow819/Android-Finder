package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/webdav"
)

const allowedMethods = "OPTIONS, PROPFIND, HEAD, GET"

type bridge struct {
	address, password string
	server            *http.Server
}

func startBridge(fs webdav.FileSystem) (*bridge, error) {
	var entropy [32]byte
	rand.Read(entropy[:])
	password := hex.EncodeToString(entropy[:])
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	host := listener.Addr().String()
	dav := &webdav.Handler{FileSystem: fs, LockSystem: webdav.NewMemLS()}
	server := &http.Server{
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       45 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Host != host || r.Header.Get("Origin") != "" {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
			username, secret, valid := r.BasicAuth()
			if !valid || username != "androidfinder" ||
				subtle.ConstantTimeCompare([]byte(secret), []byte(password)) != 1 {
				w.Header().Set("WWW-Authenticate", `Basic realm="Android Finder"`)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			switch r.Method {
			case "OPTIONS":
				w.Header().Set("DAV", "1")
				w.Header().Set("Allow", allowedMethods)
			case "PROPFIND":
				if depth := r.Header.Get("Depth"); depth != "0" && depth != "1" {
					http.Error(w, "Depth 0 or 1 required", http.StatusForbidden)
					return
				}
				r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
				dav.ServeHTTP(w, r)
			case "HEAD", "GET":
				dav.ServeHTTP(w, r)
			default:
				w.Header().Set("Allow", allowedMethods)
				http.Error(w, "Android storage is read-only", http.StatusMethodNotAllowed)
			}
		}),
	}
	go server.Serve(listener)
	return &bridge{address: "http://" + host + "/", password: password, server: server}, nil
}

func (b *bridge) mount(directory string) error {
	return mountVolume(b.address, directory, b.password)
}

func (b *bridge) close() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if b.server.Shutdown(ctx) != nil {
		b.server.Close()
	}
}

func mountedHere(directory string) (bool, error) {
	const mountNowait = 2 // Darwin MNT_NOWAIT reads cached mount information.
	count, err := syscall.Getfsstat(nil, mountNowait)
	if err != nil {
		return false, err
	}
	mounts := make([]syscall.Statfs_t, count+16)
	count, err = syscall.Getfsstat(mounts, mountNowait)
	if err != nil {
		return false, err
	}
	readName := func(value []int8) string {
		var result strings.Builder
		for _, ch := range value {
			if ch == 0 {
				break
			}
			result.WriteByte(byte(ch))
		}
		return result.String()
	}
	for _, info := range mounts[:min(count, len(mounts))] {
		if filepath.Clean(readName(info.Mntonname[:])) != directory {
			continue
		}
		source := strings.TrimPrefix(readName(info.Mntfromname[:]), "http://")
		source = strings.TrimPrefix(source, "androidfinder@")
		if readName(info.Fstypename[:]) != "webdav" || !strings.HasPrefix(source, "127.0.0.1:") {
			return false, fmt.Errorf("another filesystem is mounted at %s", directory)
		}
		return true, nil
	}
	return false, nil
}

func unmountVolume(directory string) error {
	mounted, err := mountedHere(directory)
	if err != nil || !mounted {
		return err
	}
	const mountForce = 0x00080000 // Darwin MNT_FORCE also works after the phone was unplugged.
	return syscall.Unmount(directory, mountForce)
}
