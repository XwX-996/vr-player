#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C++ owner for the Cardboard C API. All render methods are
/// called from the MTKView render thread.
@interface CardboardRuntimeBridge : NSObject

@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, readonly, getter=isHeadTrackingReady) BOOL headTrackingReady;
@property(nonatomic, readonly, copy) NSString *profileName;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                    pixelFormat:(MTLPixelFormat)pixelFormat;

- (void)updateDistortionStrengthMultiplier:(float)distortionStrengthMultiplier
                  edgeCorrectionMultiplier:(float)edgeCorrectionMultiplier;
- (void)updateDrawableWidth:(NSInteger)width height:(NSInteger)height;
- (matrix_float4x4)headViewMatrixForTimestamp:(NSTimeInterval)timestamp
                            deviceOrientation:(UIDeviceOrientation)deviceOrientation;
- (void)recenterHeadTracking;
- (void)pauseHeadTracking;
- (void)resumeHeadTracking;
- (matrix_float4x4)projectionMatrixForEye:(NSInteger)eye;
- (matrix_float4x4)eyeFromHeadMatrixForEye:(NSInteger)eye;

- (void)renderEyeTexture:(id<MTLTexture>)eyeTexture
          commandEncoder:(id<MTLRenderCommandEncoder>)commandEncoder
             screenWidth:(NSInteger)screenWidth
            screenHeight:(NSInteger)screenHeight;

@end

NS_ASSUME_NONNULL_END
