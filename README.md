# VCamRepro —— 虚拟摄像头最小复现

复现 `VCAM 3.0.0` 的核心能力：**把任意 App 的摄像头画面/麦克风声音换成你自己的素材**。

[![build](https://github.com/CN-TaylorChen/vcam-repro/actions/workflows/build.yml/badge.svg)](https://github.com/CN-TaylorChen/vcam-repro/actions/workflows/build.yml)

> **成品已构建**：GitHub Actions 上编译通过（arm64 + arm64e 通用），
> 直接下载 → [com.vcam.repro_0.1.0_iphoneos-arm64.deb](https://github.com/CN-TaylorChen/vcam-repro/releases/download/v0.1.0/com.vcam.repro_0.1.0_iphoneos-arm64.deb)
> （也可以从 [Releases](https://github.com/CN-TaylorChen/vcam-repro/releases) 页面或 Actions 的 Artifacts 取）

---

## 一、先说结论：能做到，但有三个前提

| 前提 | 说明 | 你满足吗 |
|---|---|---|
| **① 注入能力** | 必须能把 dylib 塞进目标 App 进程。越狱（MobileSubstrate）或 TrollStore + 注入工具，二选一。**没有第三条路** | 需要自备 |
| **② 私有方法没改名** | 依赖 `-_processSampleBuffer:`。iOS 14~16 确认存在，iOS 17+ 需先跑 `tools/dump_methods` 验证 | 可验证 |
| **③ 素材管线** | 解码 + 造 CMSampleBuffer，纯代码问题 | 本仓库已给 |

如果只是想在**自己的 App** 里用虚拟画面，根本不用 Hook —— 直接 `AVAssetReader` 读出帧渲染就行，那不算"复现"，跳过本文。

---

## 二、复现分级（建议按顺序做，别一上来就做完整版）

| 级别 | 内容 | 工作量 | 风险 |
|---|---|---|---|
| **L1 验证** | 写个测试 App，用 `AVCaptureVideoDataOutput`，先确认「用 AVAssetReader 造的假帧能骗过 App」 | 半天 | 无 |
| **L2 注入** | 本仓库代码编译成 tweak，注入系统相机，看到假画面 | 1~2 天 | 中 |
| **L3 产品级** | 浮窗 UI、任意格式（FFmpeg）、网络流、音画精确同步、多 App 兼容、预览层 | 原版是几个月 | 高 |

**L1 一定要做。** 90% 的失败不是 Hook 失败，是假帧的格式/PTS 不对导致 App 黑屏或编码器报错，而 L1 能让你 10 分钟定位。

---

## 三、项目结构

```
vcam_repro/
├── Tweak.m                  # Hook 安装 + 替换逻辑（核心，200 行）
├── VCamSource.h/.m          # 帧源：AVAssetReader 循环解码 + 造 CMSampleBuffer
├── Makefile                 # theos 编译
├── control                  # deb 元信息
├── VCamRepro.plist          # 注入范围（默认 com.apple.UIKit = 所有 App）
├── .github/workflows/build.yml  # push 即自动构建 deb 并上传 Artifacts
└── tools/
    ├── frida_probe.js       # 不用编译，先确认 Hook 点存在（第 0 步）
    └── dump_methods.m       # 私有方法探测器（换 iOS 版本先跑它）
```

---

## 四、核心原理（就三句话）

1. AVFoundation 把采集到的 `CMSampleBuffer` 交给 App 的 delegate 之前，会走 `AVCaptureOutput` 的私有方法 `-_processSampleBuffer:`。
2. 在这个方法上装 Hook，把真 buffer 换成假的，App 永远拿不到真实画面。
3. **假帧的时间戳直接用真帧的 PTS** —— 时间轴由设备时钟驱动，帧率和音画同步自动正确，不用自己算。

代码里对应：

```objc
timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sbuf);  // ← 关键
fake = [[VCamSource shared] copyVideoSampleBufferForFormat:fmt timing:timing pixelFormat:pf];
```

---

## 五、编译

### 方式一：GitHub Actions（什么都不用装）

仓库已配好 `.github/workflows/build.yml`，push 到 `main` 或在 Actions 页面点 **Run workflow** 即可。
CI 会：clone Theos → 把 Xcode 自带 iPhoneOS SDK 软链进 `$THEOS/sdks` → `make package FINALPACKAGE=1`
→ 校验 deb 里 dylib 和 filter plist 都在 → 上传 `vcam-repro-deb` 产物。

最近一次构建：`✓ build in 30s`，产物 14.7 KB（deb）。

### 方式二：本地 theos

```bash
# 1. 装 theos（macOS / Linux / WSL 都行）
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS

# 2. 编译
cd vcam_repro
make package FINALPACKAGE=1
# 产物：packages/com.vcam.repro_0.1.0_iphoneos-arm64.deb
```

> 本仓库代码已在 CI 上真实编译通过（macos-14 + Xcode 16 SDK，arm64 与 arm64e 双切片，ldid 签名）。
> 运行时行为（Hook 是否命中、假帧是否被接受）仍需真机验证 —— 见第七节。


---

## 六、部署

### 路线 A：越狱设备（推荐，最省事）

```bash
# 直接把 Release 里的 deb 传上去装
scp com.vcam.repro_0.1.0_iphoneos-arm64.deb root@<设备IP>:/var/root/
ssh root@<设备IP> 'dpkg -i /var/root/com.vcam.repro_0.1.0_iphoneos-arm64.deb && killall -9 SpringBoard'

# 或者源码目录下：
make package install          # 需要 ssh 到设备，或 USB 转发
```

装完注入 `/Library/MobileSubstrate/DynamicLibraries/VCamRepro.dylib`，
因为 filter 是 `com.apple.UIKit`，**所有 App 启动时都会加载**。

### 路线 B：TrollStore（无根环境）

TrollStore **没有 MobileSubstrate**，装 deb 不会自动加载。必须：

1. 用 [TrollFools](https://github.com/Lessica/TrollFools) 把 `VCamRepro.dylib` 注入到目标 App 的 `.app` 里（改 Load Command）
2. 或用 `insert_dylib` + `ldid -S` 手动注入后重签名
3. 目标 App 需要重新安装

这条路每个 App 都要单独注入一次，但不需要越狱。

### 路线 C：自签 IPA（ESign / Sideloadly / AltStore / 轻松签）

只拿 `VCamRepro.dylib` 就够了，**不需要 deb、不需要 plist**。

```bash
# 1. 解压目标 App 的 IPA
unzip -q Target.ipa -d work/

# 2. 把 dylib 和素材一起放进 .app
cp VCamRepro.dylib            work/Payload/Target.app/
cp your-video.mp4             work/Payload/Target.app/source.mp4   # ← 关键，见下

# 3. 注入 Load Command（二选一）
#    a) insert_dylib
insert_dylib --inplace --strip-codesig \
    --add-load-cmd @executable_path/VCamRepro.dylib \
    work/Payload/Target.app/Target
#    b) 或 optool / Azule，效果相同

# 4. 重新打包
cd work && zip -qry ../Target-injected.ipa Payload && cd ..
```

然后把这个 ipa 丢给 ESign / Sideloadly 用你自己的证书重签安装即可
（重签工具会把 dylib 一起签，不用手动 `ldid`）。

**素材必须放在 App 能读到的地方。** 自签的 App 依然在沙箱里，读不到
`/var/mobile/Media`。本版本按以下顺序查找，第一个命中即用：

| 顺序 | 路径 | 适用 |
|---|---|---|
| 0 | `/var/mobile/Library/Preferences/com.vcam.repro.plist` 的 `MediaPath` | 越狱机手动指定 |
| 1 | `<.app>/source.mp4`、`<.app>/VCam/source.mp4` | **自签首选**，打进 IPA 最稳 |
| 2 | `Documents/source.mp4`、`Documents/VCam/source.mp4`、`Library/VCam/source.mp4`、`tmp/source.mp4` | App 开了文件共享时可直接拷 |
| 3 | `/var/mobile/Media/VCam/source.mp4`、`/var/mobile/Documents/VCam/source.mp4` | 越狱 |

> 如果 dylib 放进 `.app/Frameworks/`，Load Command 要写
> `@rpath/VCamRepro.dylib` 并确保有 `LC_RPATH = @executable_path/Frameworks`；
> 图省事就直接放 `.app/` 根目录 + `@executable_path/`。

### 关于 rootful / rootless

当前 deb 是 **rootful（arm64）**：装到 `/Library/MobileSubstrate/DynamicLibraries/`，适用于
palera1n rootful、checkra1n、unc0ver 这类"根文件系统可写"的越狱。

无根越狱（Dopamine / palera1n rootless）需要 `/var/jb` 前缀的包，自己编一个即可：

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# 产物装到 /var/jb/Library/MobileSubstrate/DynamicLibraries/
```

---

## 七、验证

### 第 0 步：先探测，别急着编译（最省时间的顺序）

```bash
# 越狱机装好 frida-server，电脑上：
frida -U -f com.apple.camera -l tools/frida_probe.js --no-pause
```

输出会告诉你三件事：

```
[+] AVCaptureOutput - _processSampleBuffer:
[+] AVCaptureVideoDataOutput - _processSampleBuffer:     ← 有的版本会重写
[>] 已监听 ...
    [video] 1920x1080  pts=12.345
    [audio] pts=12.360
```

- 有 `[+]` 行 → Hook 点存在，可以往下做
- 有 `[video]` / `[audio]` 行 → 说明**同一个方法同时收视频和音频**，一个 Hook 就能全接管
- 只有 `[video]` 没有 `[audio]` → 音频走别的路，需要额外找 `AVCaptureAudioDataOutput`

这一步只监听不改行为，零风险。

### 第 1 步：装插件看日志

```bash
# 1. 放素材
mkdir -p /var/mobile/Media/VCam
cp test.mp4 /var/mobile/Media/VCam/source.mp4

# 2. 看日志（新开一个 ssh 窗口）
log stream --predicate 'eventMessage CONTAINS "[VCam]"' --style compact

# 3. 打开系统相机，应该看到：
#    [VCam] hook -[AVCaptureOutput _processSampleBuffer:]  types=v24@0:8^{opaqueCMSampleBuffer=}16
#    [VCam] 共 hook 1 个方法
#    [VCam] 素材 已加载 -> /var/mobile/Media/VCam/source.mp4
#    [VCam] 管线就绪 875704422:1920x1080 (video=Y audio=Y)

# 4. 换素材热重载（不用重启 App）
killall -HUP Camera    # 或发 Darwin 通知 com.vcam.repro.reload
```

改控制项不用重装：

```bash
# /var/mobile/Library/Preferences/com.vcam.repro.plist
# { MediaPath = "/var/mobile/Media/VCam/xxx.mp4"; }
```

---

## 八、踩坑清单（按踩到概率排序）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | **预览层不受影响** | 自己看还是真脸，对方看到的是假脸 | `AVCaptureVideoPreviewLayer` 走 GPU 直通，不经过 `_processSampleBuffer:`。要连预览一起假，得另外 hook 预览层或用 `videoDataOutput` 的 `previewLayer` |
| 2 | **像素格式不匹配** | App 黑屏 / `VTCompressionSession` 返回 `-12902` | 假帧的 pixelFormat 必须和原 buffer 一致（`420v`/`420f`/`BGRA`）。本仓库做法是让解码器直接产出目标格式 |
| 3 | **PTS 自己造** | 画面卡顿、丢帧、音画不同步 | 必须用真帧的 PTS（见第四节） |
| 4 | **自己定帧率** | 高帧率相机下画面抽搐 | 不要定时推帧，真帧来一次就返回一个假帧 |
| 5 | 素材分辨率 ≠ 相机分辨率 | 花屏 / 拉伸 | `CMSampleBufferCreateReadyWithImageBuffer` 要求 format description 与 buffer 尺寸一致，本仓库用 CoreImage 兜底缩放 |
| 6 | 音频是压缩格式 | 声音变成噪音 | 只替换 `kAudioFormatLinearPCM`，AAC 直接放行 |
| 7 | iOS 17+ 方法改名 | Hook 装不上，日志提示"没找到" | 跑 `tools/dump_methods`，改成动态查找（本仓库已经是动态查找） |
| 8 | 注入 UIKit 拖慢启动 | 所有 App 冷启动变慢 | 真产品应该收窄 filter，或延迟到首次用到再初始化 |
| 9 | 内存泄漏 | 用一会儿 App 被杀 | `CVPixelBufferRetain/Release` 配对；本仓库每帧都 release |
| 10 | TrollStore 装 deb 没反应 | 什么都不发生 | 见路线 B，必须注入 app bundle |
| 11 | 自签后日志只有"没找到素材" | 画面没变，其他一切正常 | 沙箱读不到 `/var/mobile/Media`，把 `source.mp4` 打进 `.app` 里（见路线 C 路径表） |
| 12 | 自签工具重签失败 / 崩溃 | 装不上或闪退 | 试 `VCamRepro-arm64.dylib`（arm64 单切片），部分老工具处理 arm64e 切片有问题 |

---

## 九、和原版 VCAM 3.0.0 的差距

| 能力 | 本仓库 | 原版 |
|---|---|---|
| 视频替换 | ✅ | ✅ |
| 音频替换 | ✅（LPCM，单声道上混） | ✅（完整 ASBD 适配 + 环形缓冲 + 时间轴） |
| 格式支持 | 系统能解的（mp4/mov/m4v/HLS） | **FFmpeg 4.0.3 全格式**（mkv/avi/flv/rtmp…） |
| 网络流 | HLS 可（AVURLAsset 原生支持） | RTMP/RTSP 等全支持 |
| 浮窗 UI | ❌ 改 plist | ✅ 悬浮球 + 完整菜单 |
| 静态图片替换 | ❌ | ✅ |
| 外接 UVC 摄像头 | ❌ | ✅ |
| 卡密授权 | ❌（也不建议加） | ✅ |

**想加 FFmpeg**：自己编 arm64 静态库（`--enable-cross-compile --disable-programs`），
然后 `AVFrame → CVPixelBuffer`（`vImage` 或 `CVPixelBufferCreate + memcpy`），其余逻辑不变。
体积会从 200KB 涨到 13MB，除非必要别加。

---

## 十、合规提醒

- 用于**测试、直播、隐私保护（不想露脸）**没问题
- 用于**伪造视频通话、绕过人脸核验、冒充他人**，在国内可能触犯《反电信网络诈骗法》《个人信息保护法》，也可能构成诈骗共犯
- 注入 `com.apple.UIKit` 意味着插件崩溃会连带宿主 App 崩溃，**别装在自己日常用的主力机上**
- 本仓库不含任何联网/授权/回传逻辑，纯本地
