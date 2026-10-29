/*
 * VCam 探针 —— 不用编译任何东西，先确认目标机能不能玩
 *
 * 用法（越狱机 + frida）：
 *   frida -U -f com.apple.camera -l frida_probe.js --no-pause
 *
 * 它会：
 *   1. 列出 AVCaptureOutput 家族里所有含 processSampleBuffer 的方法
 *   2. 挂一个只读监听，打印每帧的媒体类型 / PTS / 尺寸 / 格式
 *      —— 这一步不改变任何行为，纯粹确认 Hook 点对不对
 */

if (!ObjC.available) {
    console.log('[-] 这个进程没有 ObjC runtime，换个目标');
} else {
    var CLASSES = ['AVCaptureOutput', 'AVCaptureVideoDataOutput',
                   'AVCaptureAudioDataOutput', 'AVCaptureSession'];
    var found = [];

    CLASSES.forEach(function (name) {
        var cls = ObjC.classes[name];
        if (!cls) { console.log('[-] ' + name + ' 不存在'); return; }

        // 沿继承链收集
        var cur = cls;
        while (cur) {
            var own = cur.$ownMethods || [];
            own.forEach(function (sig) {
                if (sig.indexOf('processSampleBuffer') === -1) return;
                console.log('[+] ' + cur.$className + ' ' + sig);
                var m = cur[sig];
                if (m) found.push({ cls: cur.$className, sig: sig, method: m });
            });
            cur = cur.$superClass;
        }
    });

    if (found.length === 0) {
        console.log('[!] 没找到 processSampleBuffer —— 这个 iOS 版本改了私有 API，');
        console.log('    你得先自己找新的拦截点（dump 整个 AVCapture* 的私有方法）');
    }

    found.forEach(function (f) {
        try {
            Interceptor.attach(f.method.implementation, {
                onEnter: function (args) {
                    var sbuf = args[2];
                    if (sbuf.isNull()) return;
                    var fmt = new ObjC.Object(
                        Module.findExportByName('CoreMedia', 'CMSampleBufferGetFormatDescription')(sbuf));
                    if (fmt.isNull()) return;

                    var mediaType = MediaType(fmt);
                    var pts = PTS(sbuf);
                    if (mediaType === 'vide') {
                        var dims = Dimensions(fmt);
                        console.log('    [video] ' + dims + '  pts=' + pts.toFixed(3));
                    } else if (mediaType === 'soun') {
                        console.log('    [audio] pts=' + pts.toFixed(3));
                    }
                }
            });
            console.log('[>] 已监听 ' + f.cls + ' ' + f.sig);
        } catch (e) {
            console.log('[-] 挂载失败 ' + f.sig + ': ' + e);
        }
    });
}

function MediaType(fmt) {
    var fn = Module.findExportByName('CoreMedia', 'CMFormatDescriptionGetMediaType');
    if (!fn) return '?';
    var t = new NativeFunction(fn, 'uint32', ['pointer'])(fmt.handle);
    return String.fromCharCode((t >> 24) & 0xff, (t >> 16) & 0xff, (t >> 8) & 0xff, t & 0xff);
}

function Dimensions(fmt) {
    var fn = Module.findExportByName('CoreMedia', 'CMVideoFormatDescriptionGetDimensions');
    if (!fn) return '?';
    var r = new NativeFunction(fn, 'uint64', ['pointer'])(fmt.handle);
    // CMVideoDimensions { int32 width, int32 height } 以 int64 返回
    var w = r & 0xffffffff;
    var h = (r >> 32) & 0xffffffff;
    return w + 'x' + h;
}

function PTS(sbuf) {
    var fn = Module.findExportByName('CoreMedia', 'CMSampleBufferGetPresentationTimeStamp');
    if (!fn) return 0;
    // CMTime { int64 value, int32 timescale, uint32 flags, int64 epoch } 用内存接收
    var out = Memory.alloc(24);
    new NativeFunction(fn, 'void', ['pointer', 'pointer'])(sbuf, out);
    var value = out.readS64();
    var timescale = out.add(8).readS32();
    return timescale ? value / timescale : 0;
}
