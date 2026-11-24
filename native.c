#include "native.h"
#include <CoreFoundation/CoreFoundation.h>
#include <NetFS/NetFS.h>
#include <errno.h>
#include <string.h>
#include <sys/mount.h>

int mount_android(const char *address, const char *directory, const char *secret) {
    CFURLRef url = CFURLCreateWithBytes(NULL, (const UInt8 *)address, strlen(address),
                                        kCFStringEncodingUTF8, NULL);
    CFURLRef path = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)directory,
                                                            strlen(directory), true);
    CFStringRef password = CFStringCreateWithCString(NULL, secret, kCFStringEncodingUTF8);
    CFMutableDictionaryRef session = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int flags = MNT_RDONLY | MNT_NOSUID | MNT_NODEV | MNT_NOEXEC;
    CFNumberRef mount_flags = CFNumberCreate(NULL, kCFNumberIntType, &flags);
    CFArrayRef results = NULL;
    int status = ENOMEM;

    if (url && path && password && session && options && mount_flags) {
        CFDictionarySetValue(session, kNAUIOptionKey, kNAUIOptionNoUI);
        CFDictionarySetValue(session, kNetFSAllowLoopbackKey, kCFBooleanTrue);
        CFDictionarySetValue(options, kNetFSMountAtMountDirKey, kCFBooleanTrue);
        CFDictionarySetValue(options, kNetFSMountFlagsKey, mount_flags);
        status = NetFSMountURLSync(url, path, CFSTR("androidfinder"), password,
                                  session, options, &results);
    }
    if (results) CFRelease(results);
    if (mount_flags) CFRelease(mount_flags);
    if (options) CFRelease(options);
    if (session) CFRelease(session);
    if (password) CFRelease(password);
    if (path) CFRelease(path);
    if (url) CFRelease(url);
    return status;
}

extern int download_cancelled(uintptr_t context);

static int transfer_progress(uint64_t sent, uint64_t total, const void *context) {
    (void)sent;
    (void)total;
    return download_cancelled((uintptr_t)context);
}

int download_object(LIBMTP_mtpdevice_t *device, uint32_t object, int fd, uintptr_t context) {
    return LIBMTP_Get_File_To_File_Descriptor(device, object, fd, transfer_progress,
                                             (const void *)context);
}

#include <libusb.h>

static libusb_context *usb_monitor;

int open_usb_monitor(void) {
    return libusb_init(&usb_monitor);
}

void close_usb_monitor(void) {
    libusb_exit(usb_monitor);
}

int android_usb_present(uint32_t bus, uint8_t address, uint16_t vendor, uint16_t product) {
    libusb_device **devices;
    ssize_t count = libusb_get_device_list(usb_monitor, &devices);
    if (count < 0) return (int)count;

    int present = 0;
    for (ssize_t index = 0; index < count; index++) {
        libusb_device *device = devices[index];
        if (libusb_get_bus_number(device) != bus || libusb_get_device_address(device) != address)
            continue;
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(device, &descriptor) == 0 &&
            descriptor.idVendor == vendor && descriptor.idProduct == product) {
            present = 1;
            break;
        }
    }
    libusb_free_device_list(devices, 1);
    return present;
}
