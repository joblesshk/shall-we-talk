#import "HostReturnRuntime.h"
#import <objc/runtime.h>
#import <math.h>
#define HRLLog(message) NSLog(@"SWT host runtime %@", message)
id SWTReadHostValue(id object, NSString *name) {
    if (!object) return nil;
    @try {
        SEL sel = NSSelectorFromString(name);
        if (![object respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [object methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2) return nil;
        const char *t = sig.methodReturnType;
        if (!strchr("@iIqQBcv", *t)) return nil;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = object; call.selector = sel;
        [call invoke];
        if (*t == '@') { __unsafe_unretained id result = nil; [call getReturnValue:&result]; return result; }
        if (*t == 'v') return @YES;
        if (sig.methodReturnLength > sizeof(uint64_t)) return nil;
        uint64_t result = 0; [call getReturnValue:&result]; return @(result);
    } @catch (NSException *e) { HRLLog([@"exception selector=" stringByAppendingString:name]); return nil; }
}


void SWTEnableHostIdentity(void) {
    static BOOL tried = NO;
    if (tried) return;
    tried = YES;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.org.example.voicepen"];
    NSString *key = @"hostReturn.initializationUnfinished.v1";
    if ([d boolForKey:key]) return;
    [d setBool:YES forKey:key]; [d synchronize];
    @try {
        Class cls = NSClassFromString(@"_UIKeyboardArbiterClient");
        Method method = class_getClassMethod(cls, NSSelectorFromString(@"enabled"));
        char *type = method ? method_copyReturnType(method) : NULL;
        if (method && method_getNumberOfArguments(method) == 2 && type && (type[0] == 'B' || type[0] == 'c')) {
            method_setImplementation(method, imp_implementationWithBlock(^BOOL(id receiver) { return YES; }));
        }
        free(type);
    } @catch (NSException *e) { NSLog(@"SWT host identity unavailable: %@", e.name); }
    [d setBool:NO forKey:key]; [d synchronize];
}
NSDictionary *SWTHostSample(void) {
    id client = SWTReadHostValue(NSClassFromString(@"_UIKeyboardArbiterClient"), @"automaticSharedArbiterClient");
    SWTReadHostValue(client, @"checkConnection");
    id state = SWTReadHostValue(client, @"currentClientState");
    id pid = SWTReadHostValue(state, @"processIdentifier");
    id bundle = SWTReadHostValue(state, @"sourceBundleIdentifier");
    return @{@"pid": [pid isKindOfClass:NSNumber.class] ? pid : @0,
             @"bundle": [bundle isKindOfClass:NSString.class] ? bundle : @"",
             @"at": @(NSDate.date.timeIntervalSince1970)};
}
BOOL SWTOpenHostApplication(NSString *bundleID) {
    @try {
        id workspace = SWTReadHostValue(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
        NSMethodSignature *sig = [workspace methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 3 || strcmp([sig getArgumentTypeAtIndex:2], "@") ||
            (strcmp(sig.methodReturnType, "B") && strcmp(sig.methodReturnType, "c"))) return NO;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = workspace; call.selector = sel;
        [call setArgument:&bundleID atIndex:2]; [call invoke];
        BOOL result = NO; [call getReturnValue:&result]; return result;
    } @catch (NSException *e) { return NO; }
}

void SWTOpenHostURL(NSURL *url, void (^completion)(BOOL)) {
    // Experimental keyboard URL opener. The public extension context is attempted
    // by the caller first. This fallback invokes the modern UIApplication selector,
    // with explicit ABI validation, avoiding the disabled legacy openURL: method.
    @try {
        id application = SWTReadHostValue(NSClassFromString(@"UIApplication"), @"sharedApplication");
        SEL selector = NSSelectorFromString(@"openURL:options:completionHandler:");
        NSMethodSignature *sig = [application methodSignatureForSelector:selector];
        if (!sig || sig.numberOfArguments != 5 || strcmp(sig.methodReturnType, "v") ||
            strcmp([sig getArgumentTypeAtIndex:2], "@") || strcmp([sig getArgumentTypeAtIndex:3], "@") ||
            strcmp([sig getArgumentTypeAtIndex:4], "@?")) { completion(NO); return; }
        NSDictionary *options = @{};
        void (^callback)(BOOL) = [completion copy];
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        call.target = application; call.selector = selector;
        [call setArgument:&url atIndex:2]; [call setArgument:&options atIndex:3]; [call setArgument:&callback atIndex:4];
        [call retainArguments]; [call invoke];
    } @catch (NSException *e) { completion(NO); }
}
