//
//  PasteboardDaemonReader.m
//  Clipboard
//

#import "PasteboardDaemonReader.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSString * const PasteboardDaemonReaderErrorDomain = @"com.oliverames.clipboard.PasteboardDaemonReader";

typedef NS_ENUM(NSInteger, PasteboardDaemonReaderErrorCode) {
    PasteboardDaemonReaderErrorConnectionUnavailable = 1,
    PasteboardDaemonReaderErrorMethodUnavailable,
    PasteboardDaemonReaderErrorTimedOut,
};

#pragma mark - Private API protocols

// These mirror Pasteboard.framework. Declaring them as protocols lets us talk
// to the private objects through objc_msgSend without creating a link-time
// dependency on the private classes.

@protocol PBServerConnectionInterface <NSObject>
- (void)localGeneralPasteboardWithAuthenticationBlock:(id _Nullable)authenticationBlock
                                       dataOwnerBlock:(id _Nullable)dataOwnerBlock
                                      completionBlock:(void (^)(id _Nullable itemCollection, NSError * _Nullable error))completionBlock;
@end

@protocol PBItemRepresentationInterface <NSObject>
@property (nonatomic, copy, readonly) NSString *typeIdentifier;
- (NSProgress *)loadDataWithCompletion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;
@end

@protocol PBItemInterface <NSObject>
- (id<PBItemRepresentationInterface> _Nullable)representationConformingToType:(NSString *)typeIdentifier;
@end

@protocol PBItemCollectionInterface <NSObject>
@property (nonatomic, copy, readonly) NSArray<id<PBItemInterface>> *items;
@end

#pragma mark - Helpers

static NSError *PasteboardDaemonReaderMakeError(PasteboardDaemonReaderErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:PasteboardDaemonReaderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSArray<NSArray<NSString *> *> *PasteboardDaemonReaderTypeGroups(void)
{
    static NSArray<NSArray<NSString *> *> *groups;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Mirrors the representations PasteboardItemRepresentation understands.
        // The actual representation's type identifier is stored in the snapshot,
        // so a broad type such as public.text is classified correctly in Swift.
        groups = @[
            @[@"public.utf8-plain-text", @"public.plain-text", @"public.text"],
            @[@"public.rtf", @"public.html", @"com.apple.flat-rtfd", @"com.apple.rtfd"],
            @[@"public.png", @"public.jpeg", @"public.heic", @"public.image"],
            @[@"public.file-url", @"public.url"],
        ];
    });
    return groups;
}

@implementation PasteboardDaemonReader

+ (BOOL)isAvailable
{
    Class connectionClass = NSClassFromString(@"PBServerConnection");
    return connectionClass != Nil && [(id)connectionClass respondsToSelector:@selector(defaultConnection)];
}

- (void)readGeneralPasteboardWithCompletionHandler:(PasteboardDaemonReaderCompletion)completionHandler
{
    NSParameterAssert(completionHandler);

    Class connectionClass = NSClassFromString(@"PBServerConnection");
    if (connectionClass == Nil || ![(id)connectionClass respondsToSelector:@selector(defaultConnection)])
    {
        completionHandler(nil, PasteboardDaemonReaderMakeError(PasteboardDaemonReaderErrorConnectionUnavailable, @"The pasteboard server connection is unavailable."));
        return;
    }

    id (*sendDefaultConnection)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id<PBServerConnectionInterface> connection = sendDefaultConnection((id)connectionClass, @selector(defaultConnection));
    if (connection == nil || ![connection respondsToSelector:@selector(localGeneralPasteboardWithAuthenticationBlock:dataOwnerBlock:completionBlock:)])
    {
        completionHandler(nil, PasteboardDaemonReaderMakeError(PasteboardDaemonReaderErrorMethodUnavailable, @"The pasteboard server connection does not support reading the general pasteboard."));
        return;
    }

    NSMutableArray<NSDictionary<NSString *, NSData *> *> *snapshots = [NSMutableArray array];
    NSObject *finishLock = [[NSObject alloc] init];
    __block BOOL finished = NO;

    void (^finish)(NSArray<NSDictionary<NSString *, NSData *> *> * _Nullable, NSError * _Nullable) = ^(NSArray<NSDictionary<NSString *, NSData *> *> *items, NSError *error) {
        @synchronized(finishLock)
        {
            if (finished) { return; }
            finished = YES;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(items, error);
        });
    };

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    // The daemon normally replies immediately, but never let a stuck XPC reply
    // block every subsequent pasteboard change.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), queue, ^{
        NSArray<NSDictionary<NSString *, NSData *> *> *partialSnapshots;
        @synchronized(snapshots)
        {
            partialSnapshots = [snapshots copy];
        }

        if (partialSnapshots.count > 0)
        {
            finish(partialSnapshots, nil);
        }
        else
        {
            finish(nil, PasteboardDaemonReaderMakeError(PasteboardDaemonReaderErrorTimedOut, @"Timed out reading the pasteboard daemon."));
        }
    });

    [connection localGeneralPasteboardWithAuthenticationBlock:nil dataOwnerBlock:nil completionBlock:^(id _Nullable itemCollection, NSError * _Nullable error) {
        if (error != nil)
        {
            NSLog(@"Pasteboard daemon returned an error: %@", error);
            finish(nil, error);
            return;
        }

        NSArray<id<PBItemInterface>> *items = [(id<PBItemCollectionInterface>)itemCollection items];
        if (items.count == 0)
        {
            finish(@[], nil);
            return;
        }

        dispatch_group_t allItemsGroup = dispatch_group_create();

        for (id<PBItemInterface> item in items)
        {
            NSMutableDictionary<NSString *, NSData *> *snapshot = [NSMutableDictionary dictionary];
            NSMutableSet<NSString *> *selectedTypes = [NSMutableSet set];
            dispatch_group_t itemGroup = dispatch_group_create();

            for (NSArray<NSString *> *typeGroup in PasteboardDaemonReaderTypeGroups())
            {
                id<PBItemRepresentationInterface> representation = nil;
                NSString *requestedType = nil;

                for (NSString *typeIdentifier in typeGroup)
                {
                    representation = [item representationConformingToType:typeIdentifier];
                    if (representation != nil)
                    {
                        requestedType = typeIdentifier;
                        break;
                    }
                }

                if (representation == nil) { continue; }

                NSString *typeIdentifier = representation.typeIdentifier ?: requestedType;
                if (typeIdentifier.length == 0) { continue; }
                if ([selectedTypes containsObject:typeIdentifier]) { continue; }

                [selectedTypes addObject:typeIdentifier];

                dispatch_group_enter(itemGroup);

                [representation loadDataWithCompletion:^(NSData * _Nullable data, NSError * _Nullable loadError) {
                    if (loadError != nil)
                    {
                        NSLog(@"Failed to load pasteboard representation %@: %@", typeIdentifier, loadError);
                    }
                    else if (data.length > 0)
                    {
                        @synchronized(snapshot)
                        {
                            snapshot[typeIdentifier] = data;
                        }
                    }

                    dispatch_group_leave(itemGroup);
                }];
            }

            dispatch_group_enter(allItemsGroup);
            dispatch_group_notify(itemGroup, queue, ^{
                NSDictionary<NSString *, NSData *> *itemSnapshot;
                @synchronized(snapshot)
                {
                    itemSnapshot = [snapshot copy];
                }

                if (itemSnapshot.count > 0)
                {
                    @synchronized(snapshots)
                    {
                        [snapshots addObject:itemSnapshot];
                    }
                }

                dispatch_group_leave(allItemsGroup);
            });
        }

        dispatch_group_notify(allItemsGroup, queue, ^{
            NSArray<NSDictionary<NSString *, NSData *> *> *itemSnapshots;
            @synchronized(snapshots)
            {
                itemSnapshots = [snapshots copy];
            }

            NSLog(@"Pasteboard daemon read %lu item(s): %@", (unsigned long)itemSnapshots.count, itemSnapshots);
            finish(itemSnapshots, nil);
        });
    }];
}

@end
