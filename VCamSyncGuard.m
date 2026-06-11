//
//  VCamSyncGuard.m
//  VCamSyncGuard — 运行时修复 dylib（方案 A）
//
//  编译后与 pg.ymsu.cn.dylib 一同注入，无需修改原始 dylib
//  修复：音画不同步 + VTDecompressionSession 异步回调崩溃
//
//  编译命令（macOS / 有 Xcode 的环境）：
//  xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
//      -framework Foundation -framework CoreMedia \
//      -framework AVFoundation -framework VideoToolbox \
//      -o VCamSyncGuard.dylib VCamSyncGuard.m
//
//  注入方式：将 VCamSyncGuard.dylib 放在与 pg.ymsu.cn.dylib
//  相同的目录下，并在注入配置中同时指定两个 dylib
//  （确保 VCamSyncGuard.dylib 在 pg.ymsu.cn.dylib 之前加载）
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <pthread.h>

/// ============================================================
///  调试日志开关 — 正式发布时改为 0
/// ============================================================
#define VCAM_SYNC_DEBUG  1

#if VCAM_SYNC_DEBUG
#define SyncLog(fmt, ...)  NSLog(@"[VCamSync] " fmt, ##__VA_ARGS__)
#else
#define SyncLog(fmt, ...)
#endif


/// ============================================================
///  PART 1：音画同步引擎（以音频时钟为主时钟）
/// ============================================================

typedef struct {
    double    audioClockSecs;        // 音频主时钟（秒）
    uint64_t  audioClockMach;       // 上次更新音频时钟时的 mach_absolute_time
    double    videoLastPts;         // 上一帧视频 PTS（用于检测跳变）
    double    machToSec;            // mach time → 秒 转换因子
    BOOL      audioClockValid;       // 音频时钟是否已初始化
    BOOL      paused;
    int64_t   droppedFrames;        // 累计丢帧计数
} VCSyncClock;

static VCSyncClock  g_clock = {0};
static pthread_mutex_t g_clockMutex = PTHREAD_MUTEX_INITIALIZER;

/// 初始化同步引擎
static void VCSync_Init(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    // mach_absolute_time() 单位转换：numer / denom * 1e-9 → 秒
    g_clock.machToSec = (double)tb.numer / (double)tb.denom * 1e-9;
    g_clock.audioClockSecs  = 0.0;
    g_clock.audioClockMach   = mach_absolute_time();
    g_clock.videoLastPts     = -1.0;
    g_clock.audioClockValid  = NO;
    g_clock.paused           = NO;
    g_clock.droppedFrames   = 0;
    SyncLog(@"Sync engine initialized (machToSec=%.6f)", g_clock.machToSec);
}

/// 获取当前音频主时钟（秒）
static double VCSync_AudioNow(void) {
    if (!g_clock.audioClockValid) return 0.0;
    uint64_t now = mach_absolute_time();
    return g_clock.audioClockSecs + (double)(now - g_clock.audioClockMach) * g_clock.machToSec;
}

/// 更新音频主时钟（在音频输出回调中调用）
static void VCSync_UpdateAudio(CMTime pts) {
    if (!CMTIME_IS_VALID(pts)) return;
    double secs = CMTimeGetSeconds(pts);
    if (secs < 0) return;
    pthread_mutex_lock(&g_clockMutex);
    g_clock.audioClockSecs = secs;
    g_clock.audioClockMach = mach_absolute_time();
    if (!g_clock.audioClockValid) {
        SyncLog(@"Audio clock ACTIVATED (first PTS=%.3fs)", secs);
        g_clock.audioClockValid = YES;
    }
    pthread_mutex_unlock(&g_clockMutex);
}

/// 视频帧同步判定
/// 返回：
///   >= 0  → 延迟秒数（0 = 立即显示）
///   -1    → 该帧落后太多，应丢弃
static double VCSync_ShouldDisplay(CMTime videoPts) {
    if (!CMTIME_IS_VALID(videoPts)) return 0.0;
    if (!g_clock.audioClockValid)    return 0.0;  // 音频时钟未就绪，直接显示

    double vpts = CMTimeGetSeconds(videoPts);
    if (vpts < 0) return 0.0;

    double aclk = VCSync_AudioNow();
    double diff = vpts - aclk;   // 正数=视频超前，负数=视频落后

    // 落后超过 200ms → 丢弃（追不上）
    if (diff < -0.2) {
        pthread_mutex_lock(&g_clockMutex);
        g_clock.droppedFrames++;
        int64_t d = g_clock.droppedFrames;
        pthread_mutex_unlock(&g_clockMutex);
        if (d % 30 == 1) {
            SyncLog(@"DROP frame  diff=%.3fs  (totalDrops=%lld)", diff, d);
        }
        return -1.0;
    }

    // 超前超过 500ms → 可能音频出了问题，直接显示（不无限等待）
    if (diff > 0.5) {
        SyncLog(@"WARN video +%.3fs ahead, displaying anyway (audio may be stuck)", diff);
        return 0.0;
    }

    // 正常情况：返回需要等待的秒数（0 = 立即显示）
    if (diff < -0.001) return 0.0;   // 稍微落后，不等了（已经在丢帧边界内）
    return diff;
}


/// ============================================================
///  PART 2：Delegate 代理 — 拦截 VCamFFPlayer 的音视频回调
/// ============================================================

@interface VCSyncProxy : NSObject
@property (nonatomic, weak) id   originalDelegate;
@property (nonatomic, weak) id   player;
@end

@implementation VCSyncProxy

- (instancetype)init {
    self = [super init];
    if (self) {
        VCSync_Init();
        SyncLog(@"VCSyncProxy init — delegate proxy active");
    }
    return self;
}

/// 拦截视频帧回调 — 核心同步逻辑在这里
- (void)ffplayer:(id)player didOutputVideoBuffer:(CVPixelBufferRef)buffer pts:(CMTime)pts {

    if (!buffer || !CMTIME_IS_VALID(pts)) {
        // 无效数据，直接转发
        [self _forwardVideo:player buffer:buffer pts:pts];
        return;
    }

    double wait = VCSync_ShouldDisplay(pts);

    if (wait < 0) {
        // 丢帧 — 不显示，不转发
        CVPixelBufferRelease(buffer);
        return;
    }

    if (wait > 0.001) {
        // 需要等待 — 用 dispatch_after 延迟显示
        // 最多等 300ms，避免无限堆积
        double w = (wait > 0.3) ? 0.0 : wait;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(w * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self _forwardVideo:player buffer:buffer pts:pts];
            CVPixelBufferRelease(buffer);
        });
        // 保留引用，dispatch_after 块中会 release
        CVPixelBufferRetain(buffer);
        return;
    }

    // 同步良好 — 立即显示
    [self _forwardVideo:player buffer:buffer pts:pts];
}

- (void)_forwardVideo:(id)player buffer:(CVPixelBufferRef)buffer pts:(CMTime)pts {
    id del = self.originalDelegate;
    if (del && [del respondsToSelector:@selector(ffplayer:didOutputVideoBuffer:pts:)]) {
        [del ffplayer:player didOutputVideoBuffer:buffer pts:pts];
    }
}

/// 拦截音频帧回调 — 更新音频主时钟
- (void)ffplayer:(id)player didOutputAudioData:(const float *)data
                                            frames:(int)frames
                                               pts:(CMTime)pts {
    // 更新音频主时钟
    VCSync_UpdateAudio(pts);

    // 转发给原始 delegate
    id del = self.originalDelegate;
    if (del && [del respondsToSelector:@selector(ffplayer:didOutputAudioData:frames:pts:)]) {
        [del ffplayer:player didOutputAudioData:data frames:frames pts:pts];
    }
}

/// 播放状态变化 — 重置同步时钟
- (void)ffplayer:(id)player didChangeState:(NSInteger)state {
    if (state == 0) {  // 0 = 停止/空闲
        VCSync_Init();
        SyncLog(@"Player stopped — sync clock RESET");
    }
    id del = self.originalDelegate;
    if (del && [del respondsToSelector:@selector(ffplayer:didChangeState:)]) {
        [del ffplayer:player didChangeState:state];
    }
}

/// 播放错误
- (void)ffplayer:(id)player didEncounterError:(NSError *)error {
    SyncLog(@"Player error: %@", error);
    id del = self.originalDelegate;
    if (del && [del respondsToSelector:@selector(ffplayer:didEncounterError:)]) {
        [del ffplayer:player didEncounterError:error];
    }
}

/// 视频尺寸变化
- (void)ffplayer:(id)player videoSizeChanged:(CGSize)size {
    id del = self.originalDelegate;
    if (del && [del respondsToSelector:@selector(ffplayer:videoSizeChanged:)]) {
        [del ffplayer:player videoSizeChanged:size];
    }
}

/// 消息转发 — 确保未知方法转发给原始 delegate
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.originalDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

@end


/// ============================================================
///  PART 3：Hook VCamFFPlayer 的 setDelegate 方法
///          将原始 delegate 替换为 VCSyncProxy
/// ============================================================

static VCSyncProxy *g_proxy   = nil;
static IMP            g_origSetDelegate = NULL;

/// 替换后的 setDelegate: 实现
static void VCHooked_SetDelegate(id self, SEL _cmd, id delegate) {
    if (!g_proxy) {
        g_proxy = [[VCSyncProxy alloc] init];
        SyncLog(@"VCSyncProxy created");
    }
    g_proxy.originalDelegate = delegate;
    g_proxy.player          = self;

    SyncLog(@"VCamFFPlayer.setDelegate: HOOKED  (originalDelegate=%@)", delegate);

    // 调用原始 IMP，但传入的是 proxy（不是原始 delegate）
    // 注意：这里需要找到 VCamFFPlayer 真正的 setDelegate: IMP
    // 由于我们 swizzle 了，g_origSetDelegate 保存的是原始实现
    if (g_origSetDelegate) {
        ((void (*)(id, SEL, id))g_origSetDelegate)(self, _cmd, g_proxy);
    }
}

/// 安装 VCamFFPlayer delegate Hook
static void VCInstall_DelegateHook(void) {
    Class cls = objc_getClass("VCamFFPlayer");
    if (!cls) {
        SyncLog(@"VCamFFPlayer class NOT found — will retry later");
        return;
    }

    // 尝试两种可能的 delegate setter 方法名
    SEL selectors[] = {
        NSSelectorFromString(@"setFfPlayerDelegate:"),
        NSSelectorFromString(@"setDelegate:"),
        NSSelectorFromString(@"setFfDelegate:"),
        @selector(setDelegate:),
    };

    for (int i = 0; i < 4; i++) {
        Method m = class_getInstanceMethod(cls, selectors[i]);
        if (m) {
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, (IMP)VCHooked_SetDelegate);
            g_origSetDelegate = orig;
            SyncLog(@"HOOKED VCamFFPlayer.%@  (original IMP saved)",
                     NSStringFromSelector(selectors[i]));
            return;
        }
    }

    SyncLog(@"WARNING: VCamFFPlayer delegate setter NOT found! Tried setFfPlayerDelegate:/setDelegate:/setFfDelegate:");
}


/// ============================================================
///  PART 4：Hook VTDecompressionSession 安全销毁
///          先等待异步帧完成，再销毁 session
/// ============================================================
///
///  使用 __attribute__((section("__DATA,__interpose"))) 让 dyld
///  在加载时自动将所有对 VTDecompressionSessionInvalidate 的调用
///  重定向到 VCSafe_VTInvalidate。
///
///  注意：这需要在 pg.ymsu.cn.dylib 加载之前加载本 dylib
///  才能生效（DYLD_INSERT_LIBRARIES 顺序很重要）。
///

static pthread_mutex_t g_vtMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet   *g_vtSessions = nil;

/// 安全版 VTDecompressionSessionInvalidate
/// 关键修复：销毁前先调用 VTDecompressionSessionWaitForAsynchronousFrames
static OSStatus VCSafe_VTInvalidate(VTDecompressionSessionRef session) {
    if (!session) return noErr;

    pthread_mutex_lock(&g_vtMutex);
    if (g_vtSessions) {
        NSValue *key = [NSValue valueWithPointer:(void *)session];
        if ([g_vtSessions containsObject:key]) {
            SyncLog(@"VT: flushing async frames before invalidate %p", session);
            // 等待所有异步解码帧完成（最多等 3 秒）
            VTDecompressionSessionWaitForAsynchronousFrames(session);
            [g_vtSessions removeObject:key];
            SyncLog(@"VT: session %p safe to invalidate now", session);
        }
    }
    pthread_mutex_unlock(&g_vtMutex);

    // 调用原始实现 — 通过 dlopen/dlsym 获取绕过 interpose 的指针
    static OSStatus (*orig)(VTDecompressionSessionRef) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
                           RTLD_LAZY | RTLD_LOCAL);
        if (vt) {
            orig = dlsym(vt, "VTDecompressionSessionInvalidate");
            SyncLog(@"VT: original VTDecompressionSessionInvalidate = %p", orig);
        }
    });

    if (orig) return orig(session);
    // 理论上不会到这里，但做 fallback
    return VTDecompressionSessionInvalidate(session);
}

/// 追踪 VTDecompressionSessionDecodeFrame 调用
static OSStatus VCSafe_VTDecode(VTDecompressionSessionRef session,
                                 CMSampleBufferRef sampleBuffer,
                                 VTDecodeFrameFlags flags,
                                 void *sourceFrameRefCon,
                                 VTDecodeInfoFlags *infoFlagsOut) {
    if (!session) return -1;

    pthread_mutex_lock(&g_vtMutex);
    if (!g_vtSessions) g_vtSessions = [NSMutableSet set];
    [g_vtSessions addObject:[NSValue valueWithPointer:(void *)session]];
    pthread_mutex_unlock(&g_vtMutex);

    static OSStatus (*orig)(VTDecompressionSessionRef, CMSampleBufferRef,
                            VTDecodeFrameFlags, void *, VTDecodeInfoFlags *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
                           RTLD_LAZY | RTLD_LOCAL);
        if (vt) {
            orig = dlsym(vt, "VTDecompressionSessionDecodeFrame");
        }
    });

    if (orig) return orig(session, sampleBuffer, flags, sourceFrameRefCon, infoFlagsOut);
    return VTDecompressionSessionDecodeFrame(session, sampleBuffer, flags,
                                            sourceFrameRefCon, infoFlagsOut);
}

/// dyld interpose 声明
/// 这会让 dyld 在绑定符号时将所有对这两个 VT 函数的调用重定向到我们的版本
typedef struct { const void *replacement; const void *replacee; } VCInterpose;

__attribute__((used, section("__DATA,__interpose")))
static const VCInterpose VCInterposeVT[] = {
    { (const void *)VCSafe_VTInvalidate, (const void *)VTDecompressionSessionInvalidate },
    { (const void *)VCSafe_VTDecode,      (const void *)VTDecompressionSessionDecodeFrame },
};


/// ============================================================
///  PART 5：注入入口（__attribute__((constructor))）
/// ============================================================

__attribute__((constructor))
static void VCamSyncGuard_Load(void) {
    SyncLog(@"======== VCamSyncGuard LOADED ========");
    SyncLog(@"Built: %s %s", __DATE__, __TIME__);

    // 初始化
    VCSync_Init();
    g_vtSessions = [NSMutableSet set];

    /// 延迟 0.5 秒安装 Hook，确保 pg.ymsu.cn.dylib 先完成加载
    /// （如果 VCamFFPlayer 类是在 dylib 的 +load 中注册的）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCInstall_DelegateHook();

        // 如果第一次没找到类，1 秒后再试一次
        if (!g_proxy) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                VCInstall_DelegateHook();
                if (!g_proxy) {
                    SyncLog(@"WARNING: VCamFFPlayer still not found after retry!");
                    SyncLog(@"Classes containing 'VCam':");
                    // 打印所有含 VCam 的类名，帮助调试
                    unsigned int count = 0;
                    Class *classes = objc_copyClassList(&count);
                    for (unsigned int i = 0; i < count; i++) {
                        const char *name = class_getName(classes[i]);
                        if (strstr(name, "VCam") || strstr(name, "VCAM") ||
                            strstr(name, "Player") || strstr(name, "FFP")) {
                            SyncLog(@"  Found class: %s", name);
                        }
                    }
                    free(classes);
                }
            });
        }
    });

    SyncLog(@"======== VCamSyncGuard init complete ========");
}

__attribute__((destructor))
static void VCamSyncGuard_Unload(void) {
    SyncLog(@"======== VCamSyncGuard UNLOADED ========");
    pthread_mutex_destroy(&g_clockMutex);
    pthread_mutex_destroy(&g_vtMutex);
}
