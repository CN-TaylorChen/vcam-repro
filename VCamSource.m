#import "VCamSource.h"
#import <CoreImage/CoreImage.h>
#import <AudioToolbox/AudioToolbox.h>

// 并发模型（重要）：
//   · 解码跑在独立 NSThread 上，长循环不会占住任何 dispatch queue
//   · _lock 只保护「跨线程共享的状态」：最新帧、音频池、管线配置请求
//   · AVAssetReader 及其 output 由解码线程独占，别处不碰

@interface VCamSource () {
    NSLock *_lock;

    // ---- 跨线程共享（受 _lock 保护）----
    CVPixelBufferRef _latestVideo;
    NSString *_pipelineKey;          // "420v:1920x1080"，变了就要重建 reader
    BOOL _reconfigRequested;
    NSMutableData *_audioPCM;
    NSUInteger _audioReadCursor;
    AudioStreamBasicDescription _audioDstASBD;
    BOOL _hasAudioDstASBD;
    AVAudioConverter *_audioConverter;
    NSUInteger _audioBytesPerSecond;

    // ---- 解码线程独占 ----
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_videoOut;
    AVAssetReaderTrackOutput *_audioOut;
    AudioStreamBasicDescription _audioSrcASBD;

    CIContext *_ciContext;
    NSUInteger _generation;
    BOOL _running;
}

// 私有方法前置声明：避免「先调用后定义」在 ARC 下报 selector 不可见
- (void)_restart;
- (BOOL)_hasFrame;
- (void)_decodeLoopWithGeneration:(NSUInteger)gen;
- (BOOL)_pumpAudio;
- (NSData *)_convertAudio:(NSData *)input;
- (void)_buildReaderForKey:(NSString *)key;
- (CVPixelBufferRef)_scale:(CVPixelBufferRef)src
                   toWidth:(size_t)w
                    height:(size_t)h
                    format:(OSType)pf;

@end

@implementation VCamSource

+ (instancetype)shared {
    static VCamSource *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamSource new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _audioPCM = [NSMutableData data];
        _ciContext = [CIContext contextWithOptions:nil];
    }
    return self;
}

#pragma mark - 对外接口

- (void)setVideoURL:(NSURL *)videoURL {
    _videoURL = [videoURL copy];
    [self _restart];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self _restart];
}

- (void)_restart {
    NSUInteger gen;
    [_lock lock];
    gen = ++_generation;
    _reconfigRequested = YES;
    _pipelineKey = nil;
    if (_latestVideo) { CVPixelBufferRelease(_latestVideo); _latestVideo = NULL; }
    [_audioPCM setLength:0];
    _audioReadCursor = 0;
    _running = (_videoURL != nil && _enabled);
    BOOL run = _running;
    [_lock unlock];

    if (run) {
        [NSThread detachNewThreadWithBlock:^{
            [self _decodeLoopWithGeneration:gen];
        }];
    }
}

- (BOOL)_hasFrame {
    [_lock lock];
    BOOL h = (_latestVideo != NULL);
    [_lock unlock];
    return h;
}

#pragma mark - 解码线程

- (void)_decodeLoopWithGeneration:(NSUInteger)gen {
    @autoreleasepool {
        [NSThread currentThread].name = @"vcam.decode";
        [NSThread currentThread].qualityOfService = NSQualityOfServiceUserInitiated;
    }

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            BOOL alive = (gen == _generation) && _running;
            BOOL reconfig = _reconfigRequested;
            _reconfigRequested = NO;
            NSString *key = _pipelineKey;
            [_lock unlock];
            if (!alive) break;

            if (reconfig || !_reader) {
                [self _buildReaderForKey:key];
                if (!_reader) { usleep(30 * 1000); continue; }
            }

            BOOL gotAny = NO;

            if (_videoOut) {
                CMSampleBufferRef sb = [_videoOut copyNextSampleBuffer];
                if (sb) {
                    gotAny = YES;
                    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                    if (pb) {
                        CVPixelBufferRetain(pb);
                        [_lock lock];
                        CVPixelBufferRef old = _latestVideo;
                        _latestVideo = pb;
                        [_lock unlock];
                        if (old) CVPixelBufferRelease(old);
                    }
                    CFRelease(sb);
                }
            }

            if (_audioOut && [self _pumpAudio]) gotAny = YES;

            if (!gotAny) {
                // 一轮播完 —— 重建 reader 实现循环播放
                [self _buildReaderForKey:key];
                if (!_reader) usleep(50 * 1000);
            }
        }
    }
}

/// 解码线程内调用：音频池不够 2 秒才继续解
- (BOOL)_pumpAudio {
    [_lock lock];
    NSUInteger buffered = _audioPCM.length - _audioReadCursor;
    NSUInteger limit = _audioBytesPerSecond * 2;
    [_lock unlock];
    if (limit && buffered > limit) return NO;

    CMSampleBufferRef sb = [_audioOut copyNextSampleBuffer];
    if (!sb) return NO;

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (len > 0) {
        NSMutableData *raw = [NSMutableData dataWithLength:len];
        CMBlockBufferCopyDataBytes(bb, 0, len, raw.mutableBytes);
        NSData *converted = [self _convertAudio:raw];
        if (converted.length) {
            [_lock lock];
            [_audioPCM appendData:converted];
            [_lock unlock];
        }
    }
    CFRelease(sb);
    return YES;
}

- (NSData *)_convertAudio:(NSData *)input {
    AVAudioConverter *conv;
    AudioStreamBasicDescription dst;
    [_lock lock];
    conv = _audioConverter;
    dst = _audioDstASBD;
    BOOL hasDst = _hasAudioDstASBD;
    AudioStreamBasicDescription src = _audioSrcASBD;
    [_lock unlock];
    if (!hasDst) return nil;

    if (!conv) return input;   // 格式已经一致，直接透传

    AVAudioFormat *srcFmt = [[AVAudioFormat alloc] initWithStreamDescription:&src];
    AVAudioFormat *dstFmt = [[AVAudioFormat alloc] initWithStreamDescription:&dst];
    if (!srcFmt || !dstFmt) return nil;

    AVAudioFrameCount frames = (AVAudioFrameCount)(input.length / srcFmt.streamDescription->mBytesPerFrame);
    if (frames == 0) return nil;

    AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:srcFmt frameCapacity:frames];
    if (!inBuf) return nil;
    inBuf.frameLength = frames;
    memcpy(inBuf.mutableAudioBufferList->mBuffers[0].mData, input.bytes, input.length);

    AVAudioFrameCount cap = (AVAudioFrameCount)((double)frames * dstFmt.sampleRate / srcFmt.sampleRate) + 128;
    AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:cap];
    if (!outBuf) return nil;

    __block BOOL supplied = NO;
    NSError *err = nil;
    AVAudioConverterOutputStatus st = [conv convertToBuffer:outBuf error:&err
        withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *status) {
            if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES;
            *status = AVAudioConverterInputStatus_HaveData;
            return inBuf;
        }];
    if (st == AVAudioConverterOutputStatus_Error || outBuf.frameLength == 0) return nil;

    const AudioBufferList *abl = outBuf.audioBufferList;
    if (abl->mNumberBuffers == 1) {
        return [NSData dataWithBytes:abl->mBuffers[0].mData length:abl->mBuffers[0].mDataByteSize];
    }
    // 非交错多声道：拼成一块，配合 mFormatFlags 里的 NonInterleaved 由下游按 plane 读
    NSMutableData *out = [NSMutableData data];
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        [out appendBytes:abl->mBuffers[i].mData length:abl->mBuffers[i].mDataByteSize];
    }
    return out;
}

#pragma mark - Reader 构建（只在解码线程调用）

- (void)_buildReaderForKey:(NSString *)key {
    [_reader cancelReading];
    _reader = nil; _videoOut = nil; _audioOut = nil;
    if (!key || !_videoURL) return;

    NSArray *parts = [key componentsSeparatedByString:@":"];
    if (parts.count != 2) return;
    OSType pf = (OSType)strtoul([parts[0] UTF8String], NULL, 0);
    NSArray *wh = [parts[1] componentsSeparatedByString:@"x"];
    size_t w = (size_t)[wh[0] integerValue];
    size_t h = (size_t)[wh[1] integerValue];
    if (!w || !h) return;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_videoURL options:nil];
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) { NSLog(@"[VCam] reader 失败: %@", err); return; }

    [_lock lock];
    BOOL wantAudio = _hasAudioDstASBD;
    AudioStreamBasicDescription dstASBD = _audioDstASBD;
    [_lock unlock];

    for (AVAssetTrack *t in asset.tracks) {
        if ([t.mediaType isEqualToString:AVMediaTypeVideo] && !_videoOut) {
            NSDictionary *settings = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(pf),
                (id)kCVPixelBufferWidthKey:  @(w),
                (id)kCVPixelBufferHeightKey: @(h),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:t outputSettings:settings];
            o.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:o]) { [reader addOutput:o]; _videoOut = o; }
        } else if ([t.mediaType isEqualToString:AVMediaTypeAudio] && !_audioOut && wantAudio) {
            // 统一解成 float32 单声道非交错，再由 AVAudioConverter 转成 App 要的格式
            AudioStreamBasicDescription src = dstASBD;
            src.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
            src.mChannelsPerFrame = 1;
            src.mBitsPerChannel = 32;
            src.mBytesPerFrame = 4;
            src.mBytesPerPacket = 4;
            [_lock lock];
            _audioSrcASBD = src;
            [_lock unlock];

            NSDictionary *settings = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVSampleRateKey: @(src.mSampleRate),
                AVNumberOfChannelsKey: @(1),
                AVLinearPCMBitDepthKey: @32,
                AVLinearPCMIsFloatKey: @YES,
                AVLinearPCMIsBigEndianKey: @NO,
                AVLinearPCMIsNonInterleaved: @YES,
            };
            AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:t outputSettings:settings];
            o.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:o]) { [reader addOutput:o]; _audioOut = o; }
        }
    }

    if (![reader startReading]) { NSLog(@"[VCam] startReading 失败: %@", reader.error); return; }
    _reader = reader;
    NSLog(@"[VCam] 管线就绪 %@ (video=%@ audio=%@)", key, _videoOut ? @"Y" : @"N", _audioOut ? @"Y" : @"N");
}

#pragma mark - 造 SampleBuffer

- (CMSampleBufferRef)copyVideoSampleBufferForFormat:(CMFormatDescriptionRef)incomingFormat
                                             timing:(CMSampleTimingInfo)timing
                                        pixelFormat:(OSType)pixelFormat {
    if (!incomingFormat || !_enabled || !_videoURL) return NULL;

    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(incomingFormat);
    if (dim.width <= 0 || dim.height <= 0) return NULL;

    NSString *key = [NSString stringWithFormat:@"%u:%dx%d", (unsigned)pixelFormat, dim.width, dim.height];

    [_lock lock];
    BOOL changed = ![_pipelineKey isEqualToString:key];
    if (changed) { _pipelineKey = key; _reconfigRequested = YES; }
    [_lock unlock];

    if (changed) {
        for (int i = 0; i < 300 && ![self _hasFrame]; i++) usleep(5 * 1000);  // 最多等 1.5s
        if (![self _hasFrame]) return NULL;
    }

    [_lock lock];
    CVPixelBufferRef pb = _latestVideo ? (CVPixelBufferRef)CVPixelBufferRetain(_latestVideo) : NULL;
    [_lock unlock];
    if (!pb) return NULL;

    if (CVPixelBufferGetWidth(pb) != (size_t)dim.width ||
        CVPixelBufferGetHeight(pb) != (size_t)dim.height) {
        CVPixelBufferRef scaled = [self _scale:pb toWidth:dim.width height:dim.height format:pixelFormat];
        CVPixelBufferRelease(pb);
        pb = scaled;
        if (!pb) return NULL;
    }

    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, incomingFormat, &timing, &out);
    CVPixelBufferRelease(pb);
    if (st != noErr) return NULL;
    return out;
}

- (CVPixelBufferRef)_scale:(CVPixelBufferRef)src toWidth:(size_t)w height:(size_t)h format:(OSType)pf {
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, pf, (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess)
        return NULL;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale((CGFloat)w / CVPixelBufferGetWidth(src),
                                                                   (CGFloat)h / CVPixelBufferGetHeight(src))];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, w, h) colorSpace:cs];
    CGColorSpaceRelease(cs);
    return dst;
}

- (CMSampleBufferRef)copyAudioSampleBufferForFormat:(CMFormatDescriptionRef)incomingFormat
                                             timing:(CMSampleTimingInfo)timing
                                           numBytes:(size_t)numBytes {
    if (!incomingFormat || !_enabled || !_videoURL || numBytes == 0) return NULL;

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(incomingFormat);
    if (!asbd || asbd->mBytesPerFrame == 0) return NULL;

    [_lock lock];
    BOOL firstTime = !_hasAudioDstASBD || memcmp(asbd, &_audioDstASBD, sizeof(*asbd)) != 0;
    if (firstTime) {
        _audioDstASBD = *asbd;
        _hasAudioDstASBD = YES;
        _audioBytesPerSecond = (NSUInteger)(asbd->mSampleRate * asbd->mBytesPerFrame);

        // 解码侧固定输出 float32 / 单声道 / 非交错，这里就地推导源格式，
        // 不依赖解码线程，避免首次请求时 converter 拿到全零 ASBD
        AudioStreamBasicDescription src = *asbd;
        src.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        src.mChannelsPerFrame = 1;
        src.mBitsPerChannel = 32;
        src.mBytesPerFrame = 4;
        src.mBytesPerPacket = 4;
        _audioSrcASBD = src;

        _audioConverter = nil;
        BOOL needConvert = !(asbd->mFormatFlags & kAudioFormatFlagIsFloat)
                        || !(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
                        || asbd->mChannelsPerFrame != 1;
        if (needConvert) {
            AVAudioFormat *sf = [[AVAudioFormat alloc] initWithStreamDescription:&src];
            AVAudioFormat *df = [[AVAudioFormat alloc] initWithStreamDescription:&_audioDstASBD];
            if (sf && df) {
                _audioConverter = [[AVAudioConverter alloc] initFromFormat:sf toFormat:df];
                if (!_audioConverter) NSLog(@"[VCam] 音频转换器创建失败，将只换画面");
            }
        }
        _reconfigRequested = YES;   // 让解码线程把音频轨挂上
    }
    [_lock unlock];

    NSMutableData *chunk = [NSMutableData dataWithLength:numBytes];
    NSUInteger got = 0;
    [_lock lock];
    NSUInteger avail = _audioPCM.length - _audioReadCursor;
    if (avail > 0) {
        got = MIN(avail, numBytes);
        memcpy(chunk.mutableBytes, (uint8_t *)_audioPCM.bytes + _audioReadCursor, got);
        _audioReadCursor += got;
        if (_audioReadCursor > 44100 * 32) {
            [_audioPCM replaceBytesInRange:NSMakeRange(0, _audioReadCursor) withBytes:NULL length:0];
            _audioReadCursor = 0;
        }
    }
    [_lock unlock];
    if (got == 0) return NULL;
    if (got < numBytes) memset((uint8_t *)chunk.mutableBytes + got, 0, numBytes - got);  // 不够补静音

    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, numBytes, kCFAllocatorDefault,
                                           NULL, 0, numBytes, kCMBlockBufferAssureMemoryNowFlag, &bb) != kCMBlockBufferNoErr)
        return NULL;
    CMBlockBufferReplaceDataBytes(chunk.bytes, bb, 0, numBytes);

    CMSampleTimingInfo t = timing;
    t.duration = CMTimeMake(1, (int32_t)asbd->mSampleRate);
    CMItemCount frames = numBytes / asbd->mBytesPerFrame;

    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, incomingFormat,
                                       frames, 1, &t, 0, NULL, &out);
    CFRelease(bb);
    if (st != noErr) return NULL;
    return out;
}

@end
