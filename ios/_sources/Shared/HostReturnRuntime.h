#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
id _Nullable SWTReadHostValue(id _Nullable object, NSString *name);
void SWTEnableHostIdentity(void);
NSDictionary *SWTHostSample(void);
BOOL SWTOpenHostApplication(NSString *bundleID);
void SWTOpenHostURL(NSURL *url, void (^completion)(BOOL));
NS_ASSUME_NONNULL_END
