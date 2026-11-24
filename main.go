package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const pollInterval = 3 * time.Second

func openPrivateDirectory(path string) (string, error) {
	if err := os.Mkdir(path, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return "", err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
		return "", fmt.Errorf("%s must be a private directory owned by the current user", path)
	}
	return filepath.EvalSymlinks(path)
}

func run(ctx context.Context) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	stateDir, err := openPrivateDirectory(filepath.Join(home, "Library", "Application Support", "Android Finder"))
	if err != nil {
		return err
	}
	logPath := filepath.Join(stateDir, "agent.log")
	if info, err := os.Stat(logPath); err == nil && info.Size() >= 1<<20 {
		_ = os.Rename(logPath, logPath+".previous")
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	log.SetOutput(logFile)
	defer log.SetOutput(os.Stderr)

	lock, err := os.OpenFile(filepath.Join(stateDir, "agent.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("another Android Finder helper is running: %w", err)
	}
	directory := filepath.Join(stateDir, "Android")
	if err := os.Mkdir(directory, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	if err := unmountVolume(directory); err != nil {
		return fmt.Errorf("clear stale Android mount: %w", err)
	}
	if info, err := os.Lstat(directory); err != nil || !info.IsDir() {
		return fmt.Errorf("invalid mount directory %s", directory)
	}

	if err := initializeMTP(); err != nil {
		return err
	}
	defer closeUSBMonitor()
	log.Println("Waiting for an unlocked USB device in File transfer mode")
	var device *mtpDevice
	var active *bridge
	var ejected *usbAddress
	var failure string
	report := func(err error) {
		if message := err.Error(); message != failure {
			log.Println(message)
			failure = message
		}
	}
	stop := func() {
		if active != nil {
			if err := unmountVolume(directory); err != nil {
				report(err)
			}
			active.close()
			active = nil
		}
		if device != nil {
			device.close()
			device = nil
		}
	}
	defer stop()

	check := func() {
		if ejected != nil {
			present, err := usbPresent(*ejected)
			if err != nil {
				report(err)
				return
			}
			if !present {
				ejected = nil
			}
		}
		if device != nil {
			present, err := usbPresent(device.address)
			if err != nil {
				report(err)
				return
			}
			if present {
				mounted, err := mountedHere(directory)
				if err != nil {
					report(err)
				} else if !mounted {
					address := device.address
					ejected = &address
					stop()
					log.Println("Android volume ejected")
				}
				return
			}
			stop()
			log.Println("Android disconnected")
		}

		raw, free, err := scanMTP()
		defer free()
		if err != nil {
			report(err)
			return
		}
		for index := range raw {
			if ejected != nil && addressOf(raw[index]) == *ejected {
				continue
			}
			device = openMTP(&raw[index])
			if device != nil {
				break
			}
		}
		if device == nil {
			return
		}

		filesystem := &androidFS{
			storage: device, tempDir: stateDir, folders: make(map[[2]uint32]folderCache),
		}
		active, err = startBridge(filesystem)
		if err == nil {
			err = active.mount(directory)
		}
		if err == nil {
			var mounted bool
			mounted, err = mountedHere(directory)
			if err == nil && !mounted {
				err = errors.New("macOS did not mount Android at the requested directory")
			}
		}
		if err != nil {
			report(err)
			stop()
			select {
			case <-time.After(15 * time.Second):
			case <-ctx.Done():
			}
			return
		}
		failure = ""
		log.Printf("Mounted Android at %s", directory)
	}

	tick := time.NewTicker(pollInterval)
	defer tick.Stop()
	for ctx.Err() == nil {
		check()
		select {
		case <-ctx.Done():
		case <-tick.C:
		}
	}
	return nil
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}
