#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// 虚拟帧源：从本地视频文件循环解码，按「宿主 App 的真实帧节奏」吐出同格式的假帧。
@interface VCamSource : NSObject

+ (instancetype)shared;

/// 当前生效的素材（传 nil 关闭替换）
@property (nonatomic, copy, nullable) NSURL *videoURL;

/// 总开关
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 视频：返回 +1 的 CMSampleBuffer，尺寸/像素格式与 incomingFormat 一致；失败返回 NULL
- (CMSampleBufferRef)copyVideoSampleBufferForFormat:(CMFormatDescriptionRef)incomingFormat
                                             timing:(CMSampleTimingInfo)timing
                                        pixelFormat:(OSType)pixelFormat
    CF_RETURNS_RETAINED;

/// 音频：返回 +1 的 CMSampleBuffer，格式与 incomingFormat 一致；失败返回 NULL
- (CMSampleBufferRef)copyAudioSampleBufferForFormat:(CMFormatDescriptionRef)incomingFormat
                                             timing:(CMSampleTimingInfo)timing
                                            numBytes:(size_t)numBytes
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
