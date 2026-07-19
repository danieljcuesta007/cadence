#import "include/CadenceExceptionCatch.h"

NSString *_Nullable CadenceCatchNSException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
    }
}
