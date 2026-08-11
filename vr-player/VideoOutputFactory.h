#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VideoOutputFactory : NSObject

+ (AVPlayerItemVideoOutput *)makeVideoOutput;

@end

NS_ASSUME_NONNULL_END
