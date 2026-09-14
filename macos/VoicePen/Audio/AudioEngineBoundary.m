#import "AudioEngineBoundary.h"

void SWTStopAudioEngine(AVAudioEngine *engine) {
    // A partially installed tap may also throw during teardown. The caller
    // discards this engine rather than trying to reuse a damaged audio graph.
    @try { [engine stop]; }
    @catch (NSException *exception) { NSLog(@"Shall We Talk [audio] stop exception: %@", exception.name); }
    @try { [engine.inputNode removeTapOnBus:0]; }
    @catch (NSException *exception) { NSLog(@"Shall We Talk [audio] remove tap exception: %@", exception.name); }
}

NSError *SWTStartAudioEngine(AVAudioEngine *engine, AVAudioNodeTapBlock tap) {
    NSError *error = nil;
    @try {
        AVAudioInputNode *input = engine.inputNode;
        AVAudioFormat *format = [input outputFormatForBus:0];
        if (format.sampleRate <= 0 || format.channelCount == 0) {
            error = [NSError errorWithDomain:@"Recorder" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"没有可用的输入设备，请检查麦克风后重试。"}];
        } else {
            // Do not force a cached client format onto a changed hardware route.
            // The Swift converter uses the format of the actual delivered buffer.
            [input installTapOnBus:0 bufferSize:4096 format:nil block:tap];
            [engine prepare];
            if ([engine startAndReturnError:&error]) { return nil; }
            if (!error) {
                error = [NSError errorWithDomain:@"Recorder" code:3 userInfo:@{
                    NSLocalizedDescriptionKey: @"麦克风启动失败，请重试。"}];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"Shall We Talk [audio] start exception: %@", exception.name);
        error = [NSError errorWithDomain:@"Recorder" code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"麦克风设备或格式发生变化，请重新开始录音。"}];
    }
    SWTStopAudioEngine(engine);
    return error;
}
