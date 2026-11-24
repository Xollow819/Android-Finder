package main

/*
#cgo darwin LDFLAGS: -framework CoreFoundation -framework NetFS
#include <stdlib.h>
#include "native.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"runtime/cgo"
	"sync"
	"time"
	"unicode/utf8"
	"unsafe"
)

type usbAddress struct {
	bus             uint32
	port            uint8
	vendor, product uint16
}

type mtpObject struct {
	name        string
	storage, id uint32
	size        int64
	modified    time.Time
	directory   bool
}

type mtpDevice struct {
	mu           sync.Mutex
	handle       *C.LIBMTP_mtpdevice_t
	address      usbAddress
	partialReads bool
}

func addressOf(raw C.LIBMTP_raw_device_t) usbAddress {
	return usbAddress{
		uint32(raw.bus_location), uint8(raw.devnum),
		uint16(raw.device_entry.vendor_id), uint16(raw.device_entry.product_id),
	}
}

func scanMTP() ([]C.LIBMTP_raw_device_t, func(), error) {
	var raw *C.LIBMTP_raw_device_t
	var count C.int
	status := C.LIBMTP_Detect_Raw_Devices(&raw, &count)
	free := func() { C.free(unsafe.Pointer(raw)) }
	switch status {
	case C.LIBMTP_ERROR_NONE:
		return unsafe.Slice(raw, int(count)), free, nil
	case C.LIBMTP_ERROR_NO_DEVICE_ATTACHED:
		return nil, free, nil
	default:
		return nil, free, fmt.Errorf("MTP device scan failed (%d)", status)
	}
}

func openMTP(raw *C.LIBMTP_raw_device_t) *mtpDevice {
	handle := C.LIBMTP_Open_Raw_Device_Uncached(raw)
	if handle == nil {
		return nil
	}
	if C.LIBMTP_Get_Storage(handle, C.LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 || handle.storage == nil {
		C.LIBMTP_Release_Device(handle)
		return nil
	}
	return &mtpDevice{
		handle: handle, address: addressOf(*raw),
		partialReads: C.LIBMTP_Check_Capability(handle, C.LIBMTP_DEVICECAP_GetPartialObject) != 0,
	}
}

func (device *mtpDevice) close() {
	device.mu.Lock()
	defer device.mu.Unlock()
	C.LIBMTP_Release_Device(device.handle)
	device.handle = nil
}

func (device *mtpDevice) list(ctx context.Context, folder mtpObject) ([]mtpObject, error) {
	device.mu.Lock()
	defer device.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if device.handle == nil {
		return nil, os.ErrNotExist
	}

	var items []mtpObject
	if folder.storage == 0 {
		for storage := device.handle.storage; storage != nil; storage = storage.next {
			items = append(items, mtpObject{
				name: C.GoString(storage.StorageDescription), storage: uint32(storage.id),
				id: uint32(C.LIBMTP_FILES_AND_FOLDERS_ROOT), directory: true,
			})
		}
		return items, nil
	}

	C.LIBMTP_Clear_Errorstack(device.handle)
	entry := C.LIBMTP_Get_Files_And_Folders(device.handle, C.uint32_t(folder.storage), C.uint32_t(folder.id))
	if entry == nil && C.LIBMTP_Get_Errorstack(device.handle) != nil {
		return nil, device.transferError("list Android folder")
	}
	for entry != nil {
		directory := entry.filetype == C.LIBMTP_FILETYPE_FOLDER
		size := uint64(entry.filesize)
		if directory {
			size = 0
		}
		if size <= math.MaxInt64 {
			items = append(items, mtpObject{
				name: C.GoString(entry.filename), storage: folder.storage, id: uint32(entry.item_id),
				size: int64(size), modified: time.Unix(int64(entry.modificationdate), 0),
				directory: directory,
			})
		}
		next := entry.next
		C.LIBMTP_destroy_file_t(entry)
		entry = next
	}
	return items, nil
}

func (device *mtpDevice) transferError(action string) error {
	defer C.LIBMTP_Clear_Errorstack(device.handle)
	if entry := C.LIBMTP_Get_Errorstack(device.handle); entry != nil {
		message := C.GoString(entry.error_text)
		if utf8.ValidString(message) && message != "" {
			return fmt.Errorf("%s: %s", action, message)
		}
	}
	return errors.New(action)
}

var errPartialUnavailable = errors.New("MTP partial reads unavailable")

func (device *mtpDevice) readAt(ctx context.Context, object mtpObject, buffer []byte, offset int64) (int, error) {
	device.mu.Lock()
	defer device.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if device.handle == nil {
		return 0, os.ErrNotExist
	}
	if !device.partialReads {
		return 0, errPartialUnavailable
	}
	var data *C.uchar
	var size C.uint
	status := C.LIBMTP_GetPartialObject(device.handle, C.uint32_t(object.id), C.uint64_t(offset),
		C.uint32_t(len(buffer)), &data, &size)
	defer C.free(unsafe.Pointer(data))
	if status != 0 || data == nil || size == 0 || uint64(size) > uint64(len(buffer)) {
		device.partialReads = false
		C.LIBMTP_Clear_Errorstack(device.handle)
		return 0, errPartialUnavailable
	}
	return copy(buffer, unsafe.Slice((*byte)(unsafe.Pointer(data)), int(size))), nil
}

func (device *mtpDevice) download(ctx context.Context, object mtpObject, destination *os.File) error {
	device.mu.Lock()
	defer device.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if device.handle == nil {
		return os.ErrNotExist
	}
	C.LIBMTP_Clear_Errorstack(device.handle)
	handle := cgo.NewHandle(ctx)
	defer handle.Delete()
	if C.download_object(device.handle, C.uint32_t(object.id), C.int(destination.Fd()), C.uintptr_t(handle)) != 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		return device.transferError("download Android file")
	}
	info, err := destination.Stat()
	if err != nil {
		return err
	}
	if info.Size() != object.size {
		return io.ErrUnexpectedEOF
	}
	return nil
}

//export download_cancelled
func download_cancelled(value C.uintptr_t) C.int {
	if cgo.Handle(value).Value().(context.Context).Err() != nil {
		return 1
	}
	return 0
}

func mountVolume(address, directory, password string) error {
	url, path, secret := C.CString(address), C.CString(directory), C.CString(password)
	defer C.free(unsafe.Pointer(url))
	defer C.free(unsafe.Pointer(path))
	defer C.free(unsafe.Pointer(secret))
	if status := C.mount_android(url, path, secret); status != 0 {
		return fmt.Errorf("macOS WebDAV mount failed (%d)", status)
	}
	return nil
}

func initializeMTP() error {
	C.LIBMTP_Init()
	if status := C.open_usb_monitor(); status != 0 {
		return fmt.Errorf("open USB monitor (%d)", status)
	}
	return nil
}

func closeUSBMonitor() {
	C.close_usb_monitor()
}

func usbPresent(address usbAddress) (bool, error) {
	status := C.android_usb_present(C.uint32_t(address.bus), C.uint8_t(address.port),
		C.uint16_t(address.vendor), C.uint16_t(address.product))
	if status < 0 {
		return false, fmt.Errorf("check USB connection (%d)", status)
	}
	return status != 0, nil
}
