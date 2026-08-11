#import "VideoOutputFactory.h"

#import <CoreVideo/CoreVideo.h>

@implementation VideoOutputFactory

+ (AVPlayerItemVideoOutput *)makeVideoOutput {
  NSDictionary<NSString *, id> *attributes = @{
    (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  return [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
}

@end
