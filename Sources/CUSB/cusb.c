#include "cusb.h"
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

struct cusb_device {
    IOUSBDeviceInterface650 **intf;
};

static void set_int(CFMutableDictionaryRef dict, CFStringRef key, int value) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFDictionarySetValue(dict, key, n);
    CFRelease(n);
}

cusb_device *cusb_open(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return NULL;
    set_int(match, CFSTR(kUSBVendorID), vid);
    set_int(match, CFSTR(kUSBProductID), pid);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) return NULL;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plug) return NULL;

    IOUSBDeviceInterface650 **intf = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&intf);
    IODestroyPlugInInterface(plug);
    if (!intf) return NULL;

    cusb_device *dev = malloc(sizeof *dev);
    if (!dev) { (*intf)->Release(intf); return NULL; }
    dev->intf = intf;
    return dev;
}

int32_t cusb_request(cusb_device *dev, uint8_t type, uint8_t req, uint16_t value, uint16_t index,
                     uint8_t *buf, uint16_t len, uint16_t *done) {
    IOUSBDevRequestTO r = {
        .bmRequestType = type, .bRequest = req, .wValue = value, .wIndex = index,
        .wLength = len, .pData = buf, .noDataTimeout = 1000, .completionTimeout = 1000,
    };
    IOReturn kr = (*dev->intf)->DeviceRequestTO(dev->intf, &r);
    if (done) *done = (uint16_t)r.wLenDone;
    return kr;
}

void cusb_close(cusb_device *dev) {
    if (!dev) return;
    (*dev->intf)->Release(dev->intf);
    free(dev);
}
