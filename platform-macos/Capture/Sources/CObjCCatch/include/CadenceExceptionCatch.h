// ObjC exception fence for AVFAudio calls that raise NSException (Swift cannot catch these;
// an uncaught raise aborts the process — seen live 2026-07-18: installTapOnNode threw during
// an audio route change and took the resident app down).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any NSException. Returns nil on success, else "name: reason".
NSString *_Nullable CadenceCatchNSException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
