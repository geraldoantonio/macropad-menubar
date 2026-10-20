#include "padusb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef IOUSBInterfaceInterface190 **Interface;

static void append(char *err, size_t err_len, const char *fmt, ...) {
    if (!err || err_len == 0) return;
    size_t used = strnlen(err, err_len);
    if (used >= err_len - 1) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(err + used, err_len - used, fmt, args);
    va_end(args);
}

static CFMutableDictionaryRef device_matching(uint16_t vendor, uint16_t product) {
    CFMutableDictionaryRef dict = IOServiceMatching("IOUSBHostDevice");
    if (!dict) return NULL;
    int v = vendor, p = product;
    CFNumberRef vn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
    CFDictionarySetValue(dict, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(dict, CFSTR(kUSBProductID), pn);
    CFRelease(vn);
    CFRelease(pn);
    return dict;
}

static int interface_number(io_service_t service) {
    int number = -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBInterfaceNumber), kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &number);
        CFRelease(value);
    }
    return number;
}

static Interface open_interface(io_service_t service, int number, char *err, size_t err_len) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) {
        append(err, err_len, "\ninterface %d: plug-in 0x%x", number, kr);
        return NULL;
    }
    Interface intf = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190), (LPVOID *)&intf);
    IODestroyPlugInInterface(plugin);
    if (hr != S_OK || !intf) {
        append(err, err_len, "\ninterface %d: QueryInterface 0x%x", number, (unsigned)hr);
        return NULL;
    }
    kr = (*intf)->USBInterfaceOpen(intf);
    if (kr != kIOReturnSuccess) {
        // Interfaces 0, 2 and 3 are owned by the HID driver; that's expected.
        append(err, err_len, "\ninterface %d: open 0x%x", number, kr);
        (*intf)->Release(intf);
        return NULL;
    }
    return intf;
}

/// Pipe index (1-based) of the first interrupt OUT pipe, or 0.
static UInt8 interrupt_out_pipe(Interface intf, int number, char *err, size_t err_len) {
    UInt8 endpoints = 0;
    if ((*intf)->GetNumEndpoints(intf, &endpoints) != kIOReturnSuccess) return 0;
    for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
        UInt8 direction, endpoint, type, interval;
        UInt16 max_packet;
        if ((*intf)->GetPipeProperties(intf, pipe, &direction, &endpoint, &type, &max_packet, &interval) != kIOReturnSuccess)
            continue;
        if (direction == kUSBOut && type == kUSBInterrupt) return pipe;
    }
    append(err, err_len, "\ninterface %d: no interrupt OUT pipe (%d endpoints)", number, endpoints);
    return 0;
}

int padusb_send(uint16_t vendor, uint16_t product,
                const uint8_t *packets, size_t count, size_t packet_size,
                char *err, size_t err_len) {
    if (err && err_len) err[0] = 0;

    io_service_t device = IOServiceGetMatchingService(kIOMainPortDefault, device_matching(vendor, product));
    if (!device) {
        append(err, err_len, "device %04x:%04x not found", vendor, product);
        return PADUSB_NOT_FOUND;
    }

    io_iterator_t children = 0;
    kern_return_t kr = IORegistryEntryGetChildIterator(device, kIOServicePlane, &children);
    IOObjectRelease(device);
    if (kr != KERN_SUCCESS) {
        append(err, err_len, "child iterator 0x%x", kr);
        return PADUSB_NO_ENDPOINT;
    }

    int result = PADUSB_NO_ENDPOINT;
    io_service_t child;
    while (result == PADUSB_NO_ENDPOINT && (child = IOIteratorNext(children))) {
        if (IOObjectConformsTo(child, "IOUSBHostInterface") || IOObjectConformsTo(child, "IOUSBInterface")) {
            int number = interface_number(child);
            Interface intf = open_interface(child, number, err, err_len);
            if (intf) {
                UInt8 pipe = interrupt_out_pipe(intf, number, err, err_len);
                if (pipe) {
                    result = PADUSB_OK;
                    for (size_t i = 0; i < count; i++) {
                        // WritePipeTO only supports bulk pipes; interrupt pipes use WritePipe.
                        IOReturn ret = (*intf)->WritePipe(intf, pipe, (void *)(packets + i * packet_size), (UInt32)packet_size);
                        if (ret != kIOReturnSuccess) {
                            if (err && err_len) err[0] = 0;
                            append(err, err_len, "interface %d pipe %d: packet %zu of %zu: 0x%x", number, pipe, i + 1, count, ret);
                            result = PADUSB_WRITE_FAILED;
                            break;
                        }
                    }
                }
                (*intf)->USBInterfaceClose(intf);
                (*intf)->Release(intf);
            }
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
    return result;
}
