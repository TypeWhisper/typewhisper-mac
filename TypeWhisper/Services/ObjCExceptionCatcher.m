#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catching:(void (NS_NOESCAPE ^)(void))tryBlock error:(NSError * _Nullable * _Nullable)error {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"com.typewhisper.AVFException"
                                         code:0
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: exception.reason ?: exception.name ?: @"NSException",
                                         @"NSExceptionName": exception.name ?: @"",
                                         @"NSExceptionUserInfo": exception.userInfo ?: @{},
                                     }];
        }
        return NO;
    }
}

@end
