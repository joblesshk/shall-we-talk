#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
// AVFAudio raises NSException for device/format failures. Keep the throwing
// Objective-C calls inside this boundary; never unwind through a Swift closure.
FOUNDATION_EXPORT NSError * _Nullable SWTStartAudioEngine(AVAudioEngine *engine,
                                                          AVAudioNodeTapBlock tap);
FOUNDATION_EXPORT void SWTStopAudioEngine(AVAudioEngine *engine);
NS_ASSUME_NONNULL_END
