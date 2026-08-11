// This app deliberately ships a fixed viewer profile and never opens the
// Cardboard camera scanner. These no-op implementations satisfy the public SDK
// surface while keeping camera code and camera permission out of the binary.
#include "qr_code.h"

#include "qrcode/cardboard_v1/cardboard_v1.h"

namespace cardboard::qrcode {

std::vector<uint8_t> getCurrentSavedDeviceParams() {
  return getCardboardV1DeviceParams();
}

void scanQrCodeAndSaveDeviceParams() {}

void saveDeviceParams(const uint8_t* /*uri*/, int /*size*/) {}

int getDeviceParamsChangedCount() { return 0; }

}  // namespace cardboard::qrcode
