#import "CardboardRuntimeBridge.h"

#import "cardboard.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <mutex>

namespace {

constexpr float kNearPlane = 0.01f;
constexpr float kFarPlane = 10.0f;

uint64_t MetalObjectAddress(id object) {
  return static_cast<uint64_t>(
      reinterpret_cast<uintptr_t>((__bridge void *)object));
}

matrix_float4x4 MatrixFromCardboardArray(const float values[16]) {
  matrix_float4x4 matrix;
  memcpy(&matrix, values, sizeof(matrix));
  return matrix;
}

matrix_float4x4 MatrixFromCardboardPose(const float position[3],
                                        const float orientation[4]) {
  const float x = orientation[0];
  const float y = orientation[1];
  const float z = orientation[2];
  const float w = orientation[3];

  matrix_float4x4 matrix;
  matrix.columns[0] = (vector_float4){
      1.0f - 2.0f * (y * y + z * z),
      2.0f * (x * y + z * w),
      2.0f * (x * z - y * w),
      0.0f,
  };
  matrix.columns[1] = (vector_float4){
      2.0f * (x * y - z * w),
      1.0f - 2.0f * (x * x + z * z),
      2.0f * (y * z + x * w),
      0.0f,
  };
  matrix.columns[2] = (vector_float4){
      2.0f * (x * z + y * w),
      2.0f * (y * z - x * w),
      1.0f - 2.0f * (x * x + y * y),
      0.0f,
  };
  matrix.columns[3] =
      (vector_float4){position[0], position[1], position[2], 1.0f};
  return matrix;
}

CardboardViewportOrientation CardboardOrientation(
    UIDeviceOrientation orientation) {
  switch (orientation) {
    case UIDeviceOrientationLandscapeRight:
      return kLandscapeRight;
    case UIDeviceOrientationPortrait:
      return kPortrait;
    case UIDeviceOrientationPortraitUpsideDown:
      return kPortraitUpsideDown;
    case UIDeviceOrientationLandscapeLeft:
    default:
      return kLandscapeLeft;
  }
}

}  // namespace

@implementation CardboardRuntimeBridge {
  id<MTLDevice> _device;
  MTLPixelFormat _pixelFormat;
  CardboardLensDistortion *_lensDistortion;
  CardboardDistortionRenderer *_distortionRenderer;
  CardboardHeadTracker *_headTracker;
  BOOL _headTrackingRunning;
  std::mutex _headTrackerMutex;
  NSData *_viewerProfile;
  NSInteger _drawableWidth;
  NSInteger _drawableHeight;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                    pixelFormat:(MTLPixelFormat)pixelFormat {
  self = [super init];
  if (self) {
    _device = device;
    _pixelFormat = pixelFormat;
    _profileName = @"Cardboard v1 fallback";
    _headTracker = CardboardHeadTracker_create();
    if (_headTracker != nullptr) {
      CardboardHeadTracker_resume(_headTracker);
      _headTrackingRunning = YES;
    }

    NSURL *profileURL = [[NSBundle mainBundle] URLForResource:@"viewer_profile"
                                                withExtension:@"bin"];
    if (profileURL != nil) {
      _viewerProfile = [NSData dataWithContentsOfURL:profileURL];
      if (_viewerProfile.length > 0) {
        _profileName = @"Bundled viewer profile";
      } else {
        _viewerProfile = nil;
      }
    }
  }
  return self;
}

- (void)dealloc {
  {
    std::lock_guard<std::mutex> lock(_headTrackerMutex);
    if (_headTracker != nullptr) {
      if (_headTrackingRunning) {
        CardboardHeadTracker_pause(_headTracker);
      }
      CardboardHeadTracker_destroy(_headTracker);
      _headTracker = nullptr;
      _headTrackingRunning = NO;
    }
  }
  CardboardDistortionRenderer_destroy(_distortionRenderer);
  CardboardLensDistortion_destroy(_lensDistortion);
}

- (BOOL)isReady {
  return _lensDistortion != nullptr && _distortionRenderer != nullptr;
}

- (BOOL)isHeadTrackingReady {
  std::lock_guard<std::mutex> lock(_headTrackerMutex);
  return _headTracker != nullptr;
}

- (matrix_float4x4)headViewMatrixForTimestamp:(NSTimeInterval)timestamp
                            deviceOrientation:(UIDeviceOrientation)deviceOrientation {
  std::lock_guard<std::mutex> lock(_headTrackerMutex);
  if (_headTracker == nullptr) {
    return matrix_identity_float4x4;
  }

  float position[3];
  float orientation[4];
  const int64_t timestampNs =
      static_cast<int64_t>(std::llround(std::max(timestamp, 0.0) * 1.0e9));
  CardboardHeadTracker_getPose(
      _headTracker, timestampNs, CardboardOrientation(deviceOrientation),
      position, orientation);

  // Cardboard returns the display-space view transform used by its reference
  // renderer. Quaternion components are ordered x, y, z, w.
  return MatrixFromCardboardPose(position, orientation);
}

- (void)recenterHeadTracking {
  std::lock_guard<std::mutex> lock(_headTrackerMutex);
  if (_headTracker != nullptr) {
    CardboardHeadTracker_recenter(_headTracker);
  }
}

- (void)pauseHeadTracking {
  std::lock_guard<std::mutex> lock(_headTrackerMutex);
  if (_headTracker != nullptr && _headTrackingRunning) {
    CardboardHeadTracker_pause(_headTracker);
    _headTrackingRunning = NO;
  }
}

- (void)resumeHeadTracking {
  std::lock_guard<std::mutex> lock(_headTrackerMutex);
  if (_headTracker != nullptr && !_headTrackingRunning) {
    CardboardHeadTracker_resume(_headTracker);
    _headTrackingRunning = YES;
  }
}

- (void)updateDrawableWidth:(NSInteger)width height:(NSInteger)height {
  if (width <= 0 || height <= 0 ||
      (_drawableWidth == width && _drawableHeight == height && self.ready)) {
    return;
  }

  _drawableWidth = width;
  _drawableHeight = height;
  CardboardDistortionRenderer_destroy(_distortionRenderer);
  _distortionRenderer = nullptr;
  CardboardLensDistortion_destroy(_lensDistortion);
  _lensDistortion = nullptr;

  const uint8_t *profileBytes = nullptr;
  int profileSize = 0;
  uint8_t *fallbackBytes = nullptr;
  if (_viewerProfile.length > 0) {
    profileBytes = static_cast<const uint8_t *>(_viewerProfile.bytes);
    profileSize = static_cast<int>(_viewerProfile.length);
  } else {
    CardboardQrCode_getCardboardV1DeviceParams(&fallbackBytes, &profileSize);
    profileBytes = fallbackBytes;
  }

  if (profileBytes == nullptr || profileSize == 0) {
    return;
  }

  _lensDistortion = CardboardLensDistortion_create(
      profileBytes, profileSize, static_cast<int>(width),
      static_cast<int>(height));
  if (_lensDistortion == nullptr) {
    return;
  }

  CardboardMetalDistortionRendererConfig config = {
      .mtl_device = MetalObjectAddress(_device),
      .color_attachment_pixel_format = static_cast<uint64_t>(_pixelFormat),
      .depth_attachment_pixel_format = static_cast<uint64_t>(MTLPixelFormatInvalid),
      .stencil_attachment_pixel_format = static_cast<uint64_t>(MTLPixelFormatInvalid),
  };
  _distortionRenderer = CardboardMetalDistortionRenderer_create(&config);
  if (_distortionRenderer == nullptr) {
    return;
  }

  CardboardMesh leftMesh;
  CardboardMesh rightMesh;
  CardboardLensDistortion_getDistortionMesh(_lensDistortion, kLeft, &leftMesh);
  CardboardLensDistortion_getDistortionMesh(_lensDistortion, kRight, &rightMesh);
  CardboardDistortionRenderer_setMesh(_distortionRenderer, &leftMesh, kLeft);
  CardboardDistortionRenderer_setMesh(_distortionRenderer, &rightMesh, kRight);
}

- (matrix_float4x4)projectionMatrixForEye:(NSInteger)eye {
  if (_lensDistortion == nullptr) {
    return matrix_identity_float4x4;
  }
  float values[16];
  CardboardLensDistortion_getProjectionMatrix(
      _lensDistortion, eye == 0 ? kLeft : kRight, kNearPlane, kFarPlane,
      values);
  return MatrixFromCardboardArray(values);
}

- (matrix_float4x4)eyeFromHeadMatrixForEye:(NSInteger)eye {
  if (_lensDistortion == nullptr) {
    return matrix_identity_float4x4;
  }
  float values[16];
  CardboardLensDistortion_getEyeFromHeadMatrix(
      _lensDistortion, eye == 0 ? kLeft : kRight, values);
  return MatrixFromCardboardArray(values);
}

- (void)renderEyeTexture:(id<MTLTexture>)eyeTexture
          commandEncoder:(id<MTLRenderCommandEncoder>)commandEncoder
             screenWidth:(NSInteger)screenWidth
            screenHeight:(NSInteger)screenHeight {
  if (!self.ready) {
    return;
  }

  CardboardEyeTextureDescription leftEye = {
      .texture = MetalObjectAddress(eyeTexture),
      .left_u = 0.0f,
      .right_u = 0.5f,
      .top_v = 1.0f,
      .bottom_v = 0.0f,
  };
  CardboardEyeTextureDescription rightEye = {
      .texture = MetalObjectAddress(eyeTexture),
      .left_u = 0.5f,
      .right_u = 1.0f,
      .top_v = 1.0f,
      .bottom_v = 0.0f,
  };
  CardboardMetalDistortionRendererTargetConfig target = {
      .render_command_encoder = MetalObjectAddress(commandEncoder),
      .screen_width = static_cast<int>(screenWidth),
      .screen_height = static_cast<int>(screenHeight),
  };
  CardboardDistortionRenderer_renderEyeToDisplay(
      _distortionRenderer, reinterpret_cast<uint64_t>(&target), 0, 0,
      static_cast<int>(screenWidth), static_cast<int>(screenHeight), &leftEye,
      &rightEye);
}

@end
