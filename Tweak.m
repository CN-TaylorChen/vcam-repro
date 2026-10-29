#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "VCamSource.h"

// ============================================================
//  虚拟摄像头 —— 核心 Hook
//
//  思路：AVFoundation 在把采集到的 CMSampleBuffer 交给 App 之前，
//        会走 AVCaptureOutput 的私有方法 -_processSampleBuffer:。
//        在这里把 buffer 换成我们自己的，App 就永远拿不到真实画面。
//
//  关键点：假帧的时间戳直接用「真帧的 PTS」，
//          时间轴完全由设备时钟驱动 —— 帧率、音画同步自动正确。
// ============================================================

#define VCAM_LOG(fmt, ...) do { if (gVerbose) NSLog(@"[VCam] " fmt, ##__VA_ARGS__); } while (0)

typedef void (*ProcessSampleBufferFn)(id, SEL, CMSampleBufferRef);

static BOOL gVerbose = YES;

// ---------------- 素材路径 ----------------
// 简化版：固定读这个文件；真要做成产品，换成你自己的设置界面 / 文件选择器
static NSString *VCamMediaPath(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/mobile/Library/Preferences/com.vcam.repro.plist"];
    NSString *p = prefs[@"MediaPath"];
    return p.length ? p : @"/var/mobile/Media/VCam/source.mp4";
}

static void VCamReload(void) {
    NSString *path = VCamMediaPath();
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    VCamSource *src = [VCamSource shared];
    // 顺序不能反：先给素材再开门，避免启动一个没有素材的解码线程
    src.videoURL = exists ? [NSURL fileURLWithPath:path] : nil;
    src.enabled = exists;
    NSLog(@"[VCam] 素材 %@ -> %@", exists ? @"已加载" : @"缺失", path);
}

// ---------------- Hook 本体 ----------------

// 音视频输出可能各自重写了 _processSampleBuffer:，必须分别保存原始 IMP，
// 否则音频会走到视频的原始实现上去（表现为只有画面变、声音还在）。
static NSMapTable<NSValue *, NSValue *> *gOrigIMPs;

static IMP VCamOriginalIMP(id self, SEL _cmd) {
    Method m = class_getInstanceMethod([self class], _cmd);
    if (!m) return NULL;
    NSValue *v = [gOrigIMPs objectForKey:[NSValue valueWithPointer:m]];
    return v ? (IMP)[v pointerValue] : NULL;
}

static void VCamProcessSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    IMP orig = VCamOriginalIMP(self, _cmd);
    if (!orig) return;

    if (!sbuf || ![VCamSource shared].isEnabled) {
        ((ProcessSampleBufferFn)orig)(self, _cmd, sbuf);
        return;
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
    if (!fmt) { ((ProcessSampleBufferFn)orig)(self, _cmd, sbuf); return; }

    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmt);
    CMSampleBufferRef fake = NULL;

    if (mediaType == kCMMediaType_Video) {
        CVImageBufferRef img = CMSampleBufferGetImageBuffer(sbuf);
        if (img) {
            OSType pf = CVPixelBufferGetPixelFormatType(img);
            CMSampleTimingInfo timing = {0};
            // 用真帧的时间信息，保证时序不跳变
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sbuf);
            timing.decodeTimeStamp       = CMSampleBufferGetDecodeTimeStamp(sbuf);
            timing.duration              = CMSampleBufferGetDuration(sbuf);
            if (CMTIME_IS_INVALID(timing.duration)) {
                timing.duration = CMTimeMake(1, 30);
            }
            fake = [[VCamSource shared] copyVideoSampleBufferForFormat:fmt
                                                                timing:timing
                                                           pixelFormat:pf];
        }
    } else if (mediaType == kCMMediaType_Audio) {
        // 只处理未压缩 PCM；AAC 之类的压缩音频直接放行，避免格式错乱
        if (CMFormatDescriptionGetMediaSubType(fmt) == kAudioFormatLinearPCM) {
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
            size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
            if (len > 0) {
                CMSampleTimingInfo timing = {0};
                timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sbuf);
                timing.duration              = CMSampleBufferGetDuration(sbuf);
                fake = [[VCamSource shared] copyAudioSampleBufferForFormat:fmt
                                                                    timing:timing
                                                                  numBytes:len];
            }
        }
    }

    if (fake) {
        ((ProcessSampleBufferFn)orig)(self, _cmd, fake);
        CFRelease(fake);
    } else {
        ((ProcessSampleBufferFn)orig)(self, _cmd, sbuf);   // 拿不到假帧就放真帧，绝不黑屏
    }
}

// ---------------- 安装 Hook ----------------

static void VCamHookMethod(Class owner, Method m) {
    if (!m || !gOrigIMPs) return;
    NSValue *key = [NSValue valueWithPointer:m];
    if ([gOrigIMPs objectForKey:key]) return;          // 已经 hook 过

    IMP old = method_getImplementation(m);
    if (old == (IMP)VCamProcessSampleBuffer) return;

    [gOrigIMPs setObject:[NSValue valueWithPointer:old] forKey:key];
    VCAM_LOG(@"hook -[%s %s]  types=%s", class_getName(owner),
             sel_getName(method_getName(m)), method_getTypeEncoding(m));
    method_setImplementation(m, (IMP)VCamProcessSampleBuffer);
}

/// 不写死 selector，沿继承链找所有名字里带 processSampleBuffer 的方法
static void VCamInstallHooks(void) {
    gOrigIMPs = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory
                                      valueOptions:NSPointerFunctionsOpaqueMemory];

    NSArray *classNames = @[@"AVCaptureVideoDataOutput", @"AVCaptureAudioDataOutput", @"AVCaptureOutput"];

    for (NSString *cn in classNames) {
        Class cls = objc_getClass(cn.UTF8String);
        if (!cls) continue;
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Method *list = class_copyMethodList(c, &n);
            for (unsigned i = 0; i < n; i++) {
                NSString *name = @(sel_getName(method_getName(list[i])));
                if (![name containsString:@"processSampleBuffer"]) continue;
                VCamHookMethod(c, list[i]);
            }
            free(list);
        }
    }

    if (gOrigIMPs.count == 0) {
        NSLog(@"[VCam] 没找到 _processSampleBuffer: —— 该系统版本可能改了私有 API，"
              @"请用 tools/dump_methods 排查");
    } else {
        NSLog(@"[VCam] 共 hook %lu 个方法", (unsigned long)gOrigIMPs.count);
    }
}

// ---------------- 入口 ----------------

static void VCamNotifyCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VCamReload();
}

__attribute__((constructor))
static void VCamInit(void) {
    @autoreleasepool {
        // 控制入口：改 plist 或发 Darwin 通知都能热重载，不用重启 App
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        VCamNotifyCallback, CFSTR("com.vcam.repro.reload"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        VCamInstallHooks();
        VCamReload();
    }
}
