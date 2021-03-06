//
//  CKMediator_Private.h
//  AgileCloudKit
//
//  Copyright (c) 2015 AgileBits. All rights reserved.
//

#import <AgileCloudKit/AgileCloudKit.h>

extern NSString *const CloudKitJSContainerNameKey;
extern NSString *const CloudKitJSAPITokenKey;
extern NSString *const CloudKitJSEnvironmentKey;

extern NSString *const CKAccountStatusNotificationUserInfoKey;

@interface CKMediator ()

@property(nonatomic, readonly) NSOperationQueue *queue;
@property(nonatomic, readonly) NSOperationQueue *innerQueue;
@property(nonatomic, readonly) WebView *cloudKitWebView;
@property(nonatomic, readonly) NSString *sessionToken;
@property(nonatomic, readonly) NSArray *containerProperties;

- (JSContext *)context;

- (NSDictionary *)infoForContainerID:(NSString *)containerID;

- (void)registerForRemoteNotifications;

- (void)addOperation:(NSOperation *)operation;
- (void)addInnerOperation:(NSOperation *)operation;

@end
