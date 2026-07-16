// SPDX-License-Identifier: MIT
#include "usb_pd.h"

#include <assert.h>
#include <stdint.h>

int main(void)
{
    const uint16_t header = usb_pd_header(USB_PD_DATA_SOURCE_CAP, 1u, 5u,
                                          true, true);
    const uint32_t pdo = usb_pd_fixed_source_pdo(5000u, 1000u);
    const uint32_t valid_rdo = (UINT32_C(1) << 28) |
                               (UINT32_C(100) << 10) | UINT32_C(100);
    const uint32_t excessive_rdo = (UINT32_C(1) << 28) |
                                   (UINT32_C(101) << 10) | UINT32_C(101);
    const uint32_t inverted_rdo = (UINT32_C(1) << 28) |
                                  (UINT32_C(100) << 10) | UINT32_C(50);
    const uint32_t vdm = usb_pd_svdm_header(USB_PD_DISPLAYPORT_SID,
                                            USB_PD_SVDM_DP_CONFIGURE,
                                            USB_PD_SVDM_REQUEST, 1u);
    const uint32_t receptacle_mode = ((uint32_t)USB_PD_DP_PIN_C << 16) |
                                     (UINT32_C(1) << 6) |
                                     USB_PD_DP_MODE_SINK;

    assert(usb_pd_header_type(header) == USB_PD_DATA_SOURCE_CAP);
    assert(usb_pd_header_count(header) == 1u);
    assert(usb_pd_header_id(header) == 5u);
    assert(((pdo >> 10) & 0x3ffu) == 100u); /* 5000 mV / 50 mV */
    assert((pdo & 0x3ffu) == 100u);          /* 1000 mA / 10 mA */
    assert(usb_pd_fixed_rdo_is_acceptable(valid_rdo, 1000u));
    assert(!usb_pd_fixed_rdo_is_acceptable(excessive_rdo, 1000u));
    assert(!usb_pd_fixed_rdo_is_acceptable(inverted_rdo, 1000u));
    assert(usb_pd_svdm_svid(vdm) == USB_PD_DISPLAYPORT_SID);
    assert(usb_pd_svdm_is_structured(vdm));
    assert(usb_pd_svdm_command(vdm) == USB_PD_SVDM_DP_CONFIGURE);
    assert(usb_pd_svdm_object_position(vdm) == 1u);
    assert(usb_pd_dp_mode_is_sink(receptacle_mode));
    assert(usb_pd_dp_partner_pin_assignments(receptacle_mode) ==
           USB_PD_DP_PIN_C);
    assert((usb_pd_dp_configure_vdo() & 0x3u) == 2u);
    return 0;
}
