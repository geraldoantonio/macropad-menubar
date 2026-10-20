#ifndef PADUSB_H
#define PADUSB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result codes of padusb_send.
enum {
    PADUSB_OK = 0,
    PADUSB_NOT_FOUND = 1,       // no device with that vendor/product
    PADUSB_NO_ENDPOINT = 2,     // no interface with an interrupt OUT pipe could be opened
    PADUSB_WRITE_FAILED = 3,    // a packet write failed
};

/// Writes `count` packets of `packet_size` bytes each (laid out back to back in `packets`)
/// to the first interface of the USB device `vendor:product` that has an interrupt OUT pipe.
///
/// Uses IOUSBLib (IOUSBInterfaceInterface), the same API libusb uses on macOS, which needs no
/// entitlements or permissions. On failure, a human-readable explanation is written to `err`.
int padusb_send(uint16_t vendor, uint16_t product,
                const uint8_t *packets, size_t count, size_t packet_size,
                char *err, size_t err_len);

#ifdef __cplusplus
}
#endif

#endif
