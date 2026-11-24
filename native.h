#include <libmtp.h>

int mount_android(const char *url, const char *directory, const char *password);
int download_object(LIBMTP_mtpdevice_t *device, uint32_t object, int fd, uintptr_t context);
int open_usb_monitor(void);
void close_usb_monitor(void);
int android_usb_present(uint32_t bus, uint8_t address, uint16_t vendor, uint16_t product);
