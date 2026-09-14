#import "AudioEngineBoundary.h"

// Objective-C doubles raise real NSExceptions without touching the microphone.
@interface FakeAudioNode : NSObject
@property AVAudioFormat *format;
@property BOOL failInstall;
@property BOOL installed;
@property BOOL removed;
@end
@implementation FakeAudioNode
- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus { return self.format; }
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    NSCAssert(format == nil, @"must not force stale hardware format");
    if (self.failInstall) [NSException raise:@"com.apple.coreaudio.avfaudio" format:@"Format mismatch"];
    self.installed = YES;
}
- (void)removeTapOnBus:(AVAudioNodeBus)bus { self.removed = YES; self.installed = NO; }
@end

@interface FakeAudioEngine : NSObject
@property FakeAudioNode *inputNode;
@property NSInteger failureStage;
@property BOOL stopped;
@end
@implementation FakeAudioEngine
- (void)prepare {
    if (self.failureStage == 1) [NSException raise:@"PrepareFailure" format:@"test"];
}
- (BOOL)startAndReturnError:(NSError **)error {
    if (self.failureStage == 2) [NSException raise:@"StartFailure" format:@"test"];
    if (self.failureStage == 3) {
        *error = [NSError errorWithDomain:@"InjectedStart" code:17 userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)stop { self.stopped = YES; }
@end

int main(void) {
    @autoreleasepool {
        for (NSInteger scenario = 0; scenario < 6; scenario++) {
            FakeAudioEngine *engine = [FakeAudioEngine new];
            engine.inputNode = [FakeAudioNode new];
            engine.inputNode.format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000 channels:1];
            engine.inputNode.failInstall = scenario == 1;
            engine.failureStage = scenario >= 2 && scenario <= 4 ? scenario - 1 : 0;
            if (scenario == 5) engine.inputNode.format = nil;
            NSError *error = SWTStartAudioEngine((AVAudioEngine *)engine,
                ^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {});
            if (scenario == 0) {
                NSCAssert(error == nil && engine.inputNode.installed, @"valid start");
                SWTStopAudioEngine((AVAudioEngine *)engine);
                SWTStopAudioEngine((AVAudioEngine *)engine);
            } else {
                NSCAssert(error != nil, @"failure must return to caller");
                if (scenario == 4) NSCAssert(error.code == 17, @"preserve ordinary start error");
            }
            NSCAssert(engine.stopped && engine.inputNode.removed, @"always tear down graph");
        }
        puts("PASS: native-format tap, install/prepare/start exceptions, ordinary start failure, missing device, teardown");
    }
    return 0;
}
