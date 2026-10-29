#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// 用途：在目标 iOS 版本上确认 _processSampleBuffer: 到底定义在哪个类、
//      类型编码是什么。换 iOS 大版本后先跑这个，再改 Tweak.m。
//
// 编译（theos）：
//   在主 Makefile 里加：
//     TOOLS = dump_methods
//     dump_methods_FILES = tools/dump_methods.m
//     dump_methods_FRAMEWORKS = Foundation AVFoundation
//     include $(THEOS_MAKE_PATH)/tool.mk
//   然后 make package，把 .theos/obj/.../dump_methods 拷到设备执行。

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *names = @[
            @"AVCaptureOutput",
            @"AVCaptureVideoDataOutput",
            @"AVCaptureAudioDataOutput",
            @"AVCaptureSession",
            @"AVCaptureConnection",
        ];
        for (NSString *n in names) {
            Class cls = objc_getClass(n.UTF8String);
            if (!cls) { printf("!! %s 不存在\n", n.UTF8String); continue; }
            printf("\n===== %s =====\n", n.UTF8String);
            for (Class c = cls; c; c = class_getSuperclass(c)) {
                unsigned int cnt = 0;
                Method *list = class_copyMethodList(c, &cnt);
                for (unsigned i = 0; i < cnt; i++) {
                    const char *sel = sel_getName(method_getName(list[i]));
                    // 只打印私有/相关方法，减少噪音
                    if (!strstr(sel, "process") && !strstr(sel, "Sample") &&
                        !strstr(sel, "capture") && !strstr(sel, "Output")) continue;
                    printf("  [%-28s] -%s   %s\n", class_getName(c), sel,
                           method_getTypeEncoding(list[i]));
                }
                free(list);
            }
        }
        printf("\n提示：找形如 -_processSampleBuffer: 的方法，确认它属于哪个类。\n");
    }
    return 0;
}
