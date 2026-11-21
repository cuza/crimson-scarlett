#ifndef CUSB_H
#define CUSB_H
#include <stdint.h>

typedef struct cusb_device cusb_device;

/// Finds the device and gets its control interface. Does not open it, because
/// other system services own the device; control requests work without an open.
/// Returns NULL when the device is not attached.
cusb_device *cusb_open(uint16_t vid, uint16_t pid);

/// Sends one control request on endpoint 0 with 1 s timeouts. Returns the IOReturn.
int32_t cusb_request(cusb_device *dev, uint8_t type, uint8_t req, uint16_t value, uint16_t index,
                     uint8_t *buf, uint16_t len, uint16_t *done);

void cusb_close(cusb_device *dev);

#endif
