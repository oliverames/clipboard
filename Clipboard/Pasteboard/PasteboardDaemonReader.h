//
//  PasteboardDaemonReader.h
//  Clipboard
//
//  Reads the general pasteboard directly from the private pasteboard daemon
//  (Pasteboard.framework) instead of going through UIPasteboard. This keeps
//  working while the app is in the background, where UIPasteboard refuses to
//  return pasteboard contents.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called with one dictionary per pasteboard item, mapping a UTI to its data.
typedef void (^PasteboardDaemonReaderCompletion)(NSArray<NSDictionary<NSString *, NSData *> *> * _Nullable items, NSError * _Nullable error);

@interface PasteboardDaemonReader : NSObject

/// YES when the private pasteboard server connection is present on this system.
+ (BOOL)isAvailable;

/// Reads the general pasteboard. The completion handler is always called on the main queue.
///
/// This only works while the app is in the foreground. The pasteboard server withholds the
/// general pasteboard from apps in the background unless they carry Apple's private
/// `com.apple.Pasteboard.background-access` entitlement, which can't be issued to a
/// third-party app. Background copies are read by the `ClipboardReader` widget
/// extension instead, because the system launches that itself.
- (void)readGeneralPasteboardWithCompletionHandler:(PasteboardDaemonReaderCompletion)completionHandler;

@end

NS_ASSUME_NONNULL_END
