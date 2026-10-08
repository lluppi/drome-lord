// macos stand-in for pw-record: taps one process's audio with a core audio process tap
// (macos 14.2+) and writes it to stdout as raw s16le 44.1k stereo, which is what ncmpcpp's
// visualizer expects. `drome-lord tap <pid>` runs this; visualizer.zig spawns it per mpv session.
// the first run asks for "system audio recording" permission (NSAudioCaptureUsageDescription is
// embedded in the binary); until it's granted the tap delivers silence.
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

#define OUT_RATE 44100.0

// an embedded Info.plist: tcc reads NSAudioCaptureUsageDescription from it before granting the tap
// (system settings > privacy & security > screen & system audio recording > system audio)
#define INFO_PLIST \
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" \
    "<plist version=\"1.0\"><dict>\n" \
    "<key>CFBundleIdentifier</key><string>al.imre.drome-lord</string>\n" \
    "<key>CFBundleName</key><string>drome-lord</string>\n" \
    "<key>NSAudioCaptureUsageDescription</key><string>drome-lord taps mpv's audio to feed ncmpcpp's visualizer.</string>\n" \
    "</dict></plist>\n"
// sized without the nul so the section is exactly the plist
__attribute__((used, section("__TEXT,__info_plist"))) static const char info_plist[sizeof(INFO_PLIST) - 1] = INFO_PLIST;

static AudioObjectID g_tap = kAudioObjectUnknown;
static AudioObjectID g_agg = kAudioObjectUnknown;
static AudioDeviceIOProcID g_proc = NULL;

static void cleanup(void) {
    if (g_proc) {
        AudioDeviceStop(g_agg, g_proc);
        AudioDeviceDestroyIOProcID(g_agg, g_proc);
        g_proc = NULL;
    }
    if (g_agg != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(g_agg);
    if (g_tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(g_tap);
    g_agg = g_tap = kAudioObjectUnknown;
}

static void on_signal(int sig) {
    (void)sig;
    cleanup();
    _exit(0);
}

static int fail(const char *what, OSStatus st) {
    fprintf(stderr, "tap: %s failed (%d)\n", what, (int)st);
    cleanup();
    return 1;
}

static AudioObjectID process_object(pid_t pid) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslatePIDToProcessObject,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID obj = kAudioObjectUnknown;
    UInt32 size = sizeof obj;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof pid, &pid, &size, &obj) != noErr)
        return kAudioObjectUnknown;
    return obj;
}

static NSString *default_output_uid(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultSystemOutputDevice,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != noErr) return nil;
    a.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof uid;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &uid) != noErr || !uid) return nil;
    return (__bridge_transfer NSString *)uid;
}

// write everything or die: drome-lord closing the pipe is how this process learns to stop
static void write_all(const void *p, size_t n) {
    const char *c = p;
    while (n > 0) {
        ssize_t w = write(STDOUT_FILENO, c, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) on_signal(0);
        c += w;
        n -= (size_t)w;
    }
}

int drome_tap(int pid) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    @autoreleasepool {
        // mpv only shows up as an audio process once it has opened its output
        AudioObjectID proc = process_object((pid_t)pid);
        if (proc == kAudioObjectUnknown) {
            fprintf(stderr, "tap: pid %d has no core audio process object (not playing yet?)\n", pid);
            return 2;
        }

        CATapDescription *desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(proc) ]];
        desc.name = @"drome-lord visualizer";
        desc.privateTap = YES;
        desc.muteBehavior = CATapUnmuted;
        OSStatus st = AudioHardwareCreateProcessTap(desc, &g_tap);
        if (st != noErr) return fail("AudioHardwareCreateProcessTap", st);

        AudioStreamBasicDescription fmt = {0};
        UInt32 size = sizeof fmt;
        AudioObjectPropertyAddress fa = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        st = AudioObjectGetPropertyData(g_tap, &fa, 0, NULL, &size, &fmt);
        if (st != noErr) return fail("tap format", st);
        if (fmt.mFormatID != kAudioFormatLinearPCM || !(fmt.mFormatFlags & kAudioFormatFlagIsFloat) ||
            fmt.mBitsPerChannel != 32) {
            fprintf(stderr, "tap: unexpected tap format\n");
            cleanup();
            return 1;
        }
        const BOOL interleaved = !(fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        const UInt32 chans = fmt.mChannelsPerFrame ? fmt.mChannelsPerFrame : 2;

        // a private aggregate device clocked by the current output, with the tap as its input
        NSMutableDictionary *agg = [@{
            @kAudioAggregateDeviceNameKey : @"drome-lord visualizer",
            @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
            @kAudioAggregateDeviceIsPrivateKey : @YES,
            @kAudioAggregateDeviceIsStackedKey : @NO,
            @kAudioAggregateDeviceTapAutoStartKey : @YES,
            @kAudioAggregateDeviceTapListKey : @[ @{
                @kAudioSubTapUIDKey : desc.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey : @YES,
            } ],
        } mutableCopy];
        NSString *out = default_output_uid();
        if (out) {
            agg[@kAudioAggregateDeviceMainSubDeviceKey] = out;
            agg[@kAudioAggregateDeviceSubDeviceListKey] = @[ @{@kAudioSubDeviceUIDKey : out} ];
        }
        st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &g_agg);
        if (st != noErr) return fail("AudioHardwareCreateAggregateDevice", st);

        // linear resample from the tap's rate to 44.1k, carrying the fraction across callbacks
        const double step = fmt.mSampleRate / OUT_RATE;
        __block double pos = 0;
        __block float prev_l = 0, prev_r = 0;
        dispatch_queue_t q = dispatch_queue_create("drome-lord.tap", DISPATCH_QUEUE_SERIAL);
        st = AudioDeviceCreateIOProcIDWithBlock(&g_proc, g_agg, q,
            ^(const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *in_time,
              AudioBufferList *out_data, const AudioTimeStamp *out_time) {
                (void)now; (void)in_time; (void)out_data; (void)out_time;
                if (in->mNumberBuffers == 0) return;
                const float *l, *r;
                UInt32 stride, frames;
                if (interleaved) {
                    l = in->mBuffers[0].mData;
                    r = chans > 1 ? l + 1 : l;
                    stride = chans;
                    frames = in->mBuffers[0].mDataByteSize / (sizeof(float) * chans);
                } else {
                    l = in->mBuffers[0].mData;
                    r = in->mNumberBuffers > 1 ? in->mBuffers[1].mData : l;
                    stride = 1;
                    frames = in->mBuffers[0].mDataByteSize / sizeof(float);
                }
                if (!l || frames == 0) return;
                int16_t buf[4096];
                size_t n = 0;
                // pos is relative to this buffer; index -1 is last buffer's final frame
                while (pos < frames - 1 + 1e-9) {
                    long i = (long)floor(pos);
                    double t = pos - (double)i;
                    float l0 = i < 0 ? prev_l : l[i * stride], r0 = i < 0 ? prev_r : r[i * stride];
                    float l1 = l[(i + 1) * stride], r1 = r[(i + 1) * stride];
                    float sl = (float)(l0 + (l1 - l0) * t), sr = (float)(r0 + (r1 - r0) * t);
                    sl = sl > 1 ? 1 : sl < -1 ? -1 : sl;
                    sr = sr > 1 ? 1 : sr < -1 ? -1 : sr;
                    buf[n++] = (int16_t)lrintf(sl * 32767.0f);
                    buf[n++] = (int16_t)lrintf(sr * 32767.0f);
                    if (n == sizeof buf / sizeof buf[0]) {
                        write_all(buf, n * sizeof buf[0]);
                        n = 0;
                    }
                    pos += step;
                }
                if (n) write_all(buf, n * sizeof buf[0]);
                pos -= frames;
                prev_l = l[(frames - 1) * stride];
                prev_r = r[(frames - 1) * stride];
            });
        if (st != noErr) return fail("AudioDeviceCreateIOProcIDWithBlock", st);
        st = AudioDeviceStart(g_agg, g_proc);
        if (st != noErr) return fail("AudioDeviceStart", st);
        fprintf(stderr, "tap: pid %d at %.0f Hz -> s16le 44100 stereo\n", pid, fmt.mSampleRate);
    }
    // the io proc does the work; signals or a closed stdout end the process
    for (;;) pause();
}
