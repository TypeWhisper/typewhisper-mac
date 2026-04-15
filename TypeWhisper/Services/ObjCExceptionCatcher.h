#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

+ (BOOL)catching:(void (NS_NOESCAPE ^)(void))tryBlock error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
