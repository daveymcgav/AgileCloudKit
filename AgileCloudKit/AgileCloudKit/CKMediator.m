//
//  CKMediator.m
//  AgileCloudKit
//
//  Copyright (c) 2015 AgileBits Inc. All rights reserved.
//

#import "CKMediator.h"
#import "CKMediator_Private.h"
#import <WebKit/WebKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import "CKContainer_Private.h"
#import "Defines.h"
#import "CKDatabaseOperation.h"
#import "CKDatabaseOperation_Private.h"

#define CloudKitJSURL [NSURL URLWithString:@"https://cdn.apple-cloudkit.com/ck/1/cloudkit.js"]

#define MediatorDebugLog(level,__FORMAT__,...) if ([delegate respondsToSelector:@selector(mediator:logLevel:object:at:format:)]) [delegate mediator:[CKMediator sharedMediator] logLevel:level object:self at:_cmd format:__FORMAT__, ##__VA_ARGS__]

NSString *const kAgileCloudKitInitializedNotification = @"kAgileCloudKitInitializedNotification";
NSString *const CloudKitJSContainerNameKey = @"CloudKitJSContainerName";
NSString *const CloudKitJSAPITokenKey = @"CloudKitJSAPIToken";
NSString *const CloudKitJSEnvironmentKey = @"CloudKitJSEnvironment";

NSString *const CKAccountStatusNotificationUserInfoKey = @"accountStatus";

@interface CKMediator () <WebResourceLoadDelegate, WebFrameLoadDelegate, WebPolicyDelegate, WebUIDelegate>

@end

@implementation CKMediator {
	JSContext *_context;
	NSOperationQueue *_urlQueue;
	NSTimeInterval _targetInterval;
}

@synthesize delegate;
@synthesize cloudKitWebView;
@synthesize isInitialized;

static CKMediator *_mediator;

+ (CKMediator *)sharedMediator {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_mediator = [[[CKMediator class] alloc] init];
	});
	return _mediator;
}

- (instancetype)init {
	if (self = [super init]) {
		_containerProperties = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CloudKitJSContainers"];
		// each container contains keys for: CloudKitJSContainerName, CloudKitJSAPIToken, Environment
		
		// shared operation queue for all cloudkit operations
		_queue = [[NSOperationQueue alloc] init];
		_queue.maxConcurrentOperationCount = 1;
		_queue.suspended = YES;
		
		// since _queue is serial, we often have nested operations, use an "inner queue" for that
		_innerQueue = [[NSOperationQueue alloc] init];
		_innerQueue.maxConcurrentOperationCount = 1;
		_innerQueue.suspended = YES;
		
		_urlQueue = [[NSOperationQueue alloc] init];
		
		// user's token, if any
		_sessionToken = [self loadSessionToken];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			// setup the WebView that we'll use to host the CloudKitJS
			cloudKitWebView = [[WebView alloc] initWithFrame:NSMakeRect(0, 40, 300, 100)];
			cloudKitWebView.resourceLoadDelegate = self;
			cloudKitWebView.frameLoadDelegate = self;
			cloudKitWebView.policyDelegate = self;
			cloudKitWebView.UIDelegate = self;
			
			// load in our bootstrap HTML to get CloudKitJS loaded
			[self bootstrapCloudKitJS];
		});
		
	}
	return self;
}

- (void)bootstrapCloudKitJS {
	NSBundle *myBundle = [NSBundle bundleForClass:[self class]];
	NSURL *url = [myBundle URLForResource:@"test" withExtension:@"html"];
	if (url) {
		[[cloudKitWebView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];
	}
}

- (JSContext *)context {
	return _context;
}

- (NSDictionary *)infoForContainerID:(NSString *)containerID {
	for (NSDictionary *container in _containerProperties) {
		if ([container[CloudKitJSContainerNameKey] isEqualToString:containerID]) {
			return container;
		}
	}
	return nil;
}

- (void)setDelegate:(NSObject<CKMediatorDelegate> *)_delegate {
	if (delegate != _delegate) {
		delegate = _delegate;
		_sessionToken = [delegate respondsToSelector:@selector(loadSessionTokenForMediator:)] ? [delegate loadSessionTokenForMediator:self] : nil;
		MediatorDebugLog(CKLOG_LEVEL_NOTICE, @"Setting delegate and reloading %@ session token.", (_sessionToken == nil) ? @"nil" : @"non-nil");
	}
}

- (void)addOperation:(NSOperation *)operation {
	[self.queue addOperation:operation];
}

- (void)addInnerOperation:(NSOperation *)operation {
	[self.innerQueue addOperation:operation];
}

#pragma mark - Save and Load the token

- (NSString *)loadSessionToken {
	NSString *token = nil;
	if ([delegate respondsToSelector:@selector(loadSessionTokenForMediator:)]) {
		token = [delegate loadSessionTokenForMediator:self];
	}
	else {
		token = _sessionToken;
	}
	MediatorDebugLog(CKLOG_LEVEL_INFO, @"Loading %@ Session Token.", (token == nil) ? @"nil" : @"non-nil" );
	return token;
}

- (void)saveSessionToken:(NSString *)token {
	_sessionToken = token;
	if ([delegate respondsToSelector:@selector(mediator:saveSessionToken:)]) {
		MediatorDebugLog(CKLOG_LEVEL_INFO, @"Saving %@ Session Token", (token == nil) ? @"nil" : @"non-nil");
		[delegate mediator:self saveSessionToken:token];
	}
}

#pragma mark - Auth with URL

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	MediatorDebugLog(CKLOG_LEVEL_INFO, @"Received Callback URL");
	NSURLComponents *urlComponents = [NSURLComponents componentsWithString:[[event paramDescriptorForKeyword:keyDirectObject] stringValue]];
	NSArray *queryItems = urlComponents.queryItems;
	for (NSURLQueryItem *queryItem in queryItems) {
		if ([queryItem.name isEqualToString:@"ckSession"]) {
			[self saveSessionToken:queryItem.value];
			[self setupAuth];
		}
	}
}

#pragma mark - WebFrameLoadDelegate

- (void)webView:(WebView *)webView didCreateJavaScriptContext:(JSContext *)context forFrame:(WebFrame *)frame {
	// we've got the context from the webview:
	_context = context;
	
	// re-experiment with JSContext instead of webview
	MediatorDebugLog(CKLOG_LEVEL_INFO, @"CloudKit JS context created. Setting up…");
	[self setupContext:_context];
}

- (void)webView:(WebView *)sender resource:(id)identifier didFailLoadingWithError:(NSError *)error fromDataSource:(WebDataSource *)dataSource {
	MediatorDebugLog(CKLOG_LEVEL_ERR, @"failed: %@ with: %@", identifier, error);
	if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == kCFURLErrorNotConnectedToInternet && self.queue.isSuspended) {
		for (CKDatabaseOperation *operation in self.queue.operations) {
			MediatorDebugLog(CKLOG_LEVEL_ERR, @"cancelling queue operation: %@", NSStringFromClass([operation class]));
			[operation cancel];
			if ([operation respondsToSelector:@selector(completeWithError:)]) {
				[operation completeWithError:error];
			}
		}
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		_targetInterval = MAX(1, MIN(60, _targetInterval * 2));
		MediatorDebugLog(CKLOG_LEVEL_INFO, @"Trying again in %f seconds…", _targetInterval);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_targetInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self bootstrapCloudKitJS];
		});
	});
}

#pragma mark - JSContext

//
// Loads the CloudKitJS asynchronously from Apple's URL
// TODO: cache the last successful fetch locally,
// and then periodically update that local cache. that way
// for app launch 2+ we can just load the local cache immediatley
// with no delay.
- (void)loadCloudKitJSAsync {
	__block NSString *cloudjs;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		cloudjs = [NSString stringWithContentsOfURL:CloudKitJSURL encoding:NSUTF8StringEncoding error:nil];
		dispatch_async(dispatch_get_main_queue(), ^{
			[_context evaluateScript:cloudjs withSourceURL:CloudKitJSURL];
		});
	});
}


// When an auth token changes,
// this block will re-fetch the
// active user from cloudkitjs
// and signal out to ObjC using URLs
- (void)setupAuth {
	if ([NSThread isMainThread] == NO) {
		dispatch_sync(dispatch_get_main_queue(), ^{
			[self setupAuth];
		});
		return;
	}
	
	for (NSDictionary *container in _containerProperties) {
		NSString *containerID = container[CloudKitJSContainerNameKey];
		[[[_context evaluateScript:[NSString stringWithFormat:@"CloudKit.getContainer('%@').setUpAuth()", containerID]] invokeMethod:@"then" withArguments:@[^(id response) {
			if (response && ![[NSNull null] isEqual:response]) {
				MediatorDebugLog(CKLOG_LEVEL_INFO, @"logged in %@", containerID);
				[[NSNotificationCenter defaultCenter] postNotificationName:NSUbiquityIdentityDidChangeNotification object:self userInfo:@{ CKAccountStatusNotificationUserInfoKey : @(CKAccountStatusAvailable) }];
			}
			else {
				MediatorDebugLog(CKLOG_LEVEL_INFO, @"logged out %@", containerID);
				[[NSNotificationCenter defaultCenter] postNotificationName:NSUbiquityIdentityDidChangeNotification object:self userInfo:@{ CKAccountStatusNotificationUserInfoKey : @(CKAccountStatusNoAccount) }];
			}
			self.queue.suspended = NO;
			self.innerQueue.suspended = NO;
		}]] invokeMethod:@"catch"
		 withArguments:@[^(NSDictionary *errorDictionary) {
			MediatorDebugLog(CKLOG_LEVEL_ERR, @"Error: %@", errorDictionary);
		}]];
	}
}

//
// Setup the JSContext to interact with CloudKitJS.
// Important places to tie-in:
// 1. fetch/save auth token
// 2. load cloudKitJS config
// 3. URL listeners for events
- (void)setupContext:(JSContext *)context {
	// track exceptions and logs from the JSContext
	context[@"window"][@"doLog"] = ^(id string) {
		MediatorDebugLog(CKLOG_LEVEL_INFO, @"CloudKit Log: %@", [string description]);
	};
	[context setExceptionHandler:^(JSContext *c, JSValue *ex) {
		MediatorDebugLog(CKLOG_LEVEL_CRIT, @"JS Exception in context %@: %@", c, ex);
	}];
	
	// These blocks will save or load the user's
	// session token from our permanent store
	context[@"window"][@"getTokenBlock"] = ^NSString *(id containerId)
	{
		return _sessionToken;
	};
	context[@"window"][@"putTokenBlock"] = ^(id containerId, id token) {
		if ([token isKindOfClass:[NSNull class]]) {
			[self saveSessionToken:nil];
			[self setupAuth];
		}
		else {
			[self saveSessionToken:token];
		}
	};
	
	//
	// configure CloudKitJS with our container ID
	// and authentication steps, etc
	void (^loadConfig)() = ^{
		NSError* configFormatError;
		NSError* containerConfigFormatError;
		NSURL* configURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"config-format" withExtension:@"js"];
		NSString* configFormat = [NSString stringWithContentsOfURL:configURL encoding:NSUTF8StringEncoding error:&configFormatError];
		
		NSURL* containerConfigURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"container-config-format" withExtension:@"json"];
		NSString* containerConfigFormat = [NSString stringWithContentsOfURL:containerConfigURL encoding:NSUTF8StringEncoding error:&containerConfigFormatError];
		
		if (configFormatError || containerConfigFormatError) {
			@throw [NSException exceptionWithName:@"AgileCloudKitConfigException" reason:@"Could not load config for AgileCloudKit" userInfo:@{ @"error1" : configFormatError, @"error2" : containerConfigFormatError  }];
		}
		
		
		if (![_containerProperties count]) {
			MediatorDebugLog(CKLOG_LEVEL_EMERG, @"AgileCloudKit configuration error. Please check your Info.plist");
		}
		else {
			
			NSString* containerConfigString = @"";
			for (NSDictionary* containerConfig in _containerProperties) {
				// each container contains keys for: CloudKitJSContainerName, CloudKitJSAPIToken, CloudKitJSEnvironment
				NSString* configuration = [NSString stringWithFormat:containerConfigFormat, containerConfig[CloudKitJSContainerNameKey], containerConfig[CloudKitJSAPITokenKey], containerConfig[CloudKitJSEnvironmentKey], _sessionToken];
				if ([containerConfigString length]) {
					containerConfigString = [NSString stringWithFormat:@"%@,%@", containerConfigString, configuration];
				}
				else {
					containerConfigString = configuration;
				}
			}
			
			NSString* configuration = [NSString stringWithFormat:configFormat, containerConfigString];
			[context evaluateScript:configuration];
		}
	};
	
	// add blocks to the context and listen for events:
	// when cloudkit loads:
	// load the config, setupAuth to determine if we're
	// logged in or out, and notify everyone
	// that we're ready to roll
	[[context evaluateScript:@"window"] invokeMethod:@"addEventListener" withArguments:@[@"cloudkitloaded", ^() {
		loadConfig();
		MediatorDebugLog(CKLOG_LEVEL_INFO, @"AgileCloudKit Loaded. Setting up Auth…");
		[self setupAuth];
		isInitialized = YES;
		[[NSNotificationCenter defaultCenter] postNotificationName:kAgileCloudKitInitializedNotification object:self];
	}]];
	
	// If CloudKitJS tries to trigger a window.open()
	// to login the user, we should pass that on to Safari
	context[@"window"][@"open"] = ^(id url) {
		MediatorDebugLog(CKLOG_LEVEL_DEBUG, @"CloudKitJS Context requested to open URL: %@", url);
	};
}

#pragma mark - Actions

- (IBAction)login {
	[self getLoginURLWithCompletionBlock:^(NSURL *loginURL, NSError *error) {
		MediatorDebugLog(CKLOG_LEVEL_INFO, @"Sending user to CloudKit login page.");
		[[NSWorkspace sharedWorkspace] openURL:loginURL];
	}];
}

- (IBAction)logout {
	MediatorDebugLog(CKLOG_LEVEL_DEBUG, @"Logging out of CloudKitJS");
	_sessionToken = nil;
	[self.delegate mediator:self saveSessionToken:nil];
	[self setupAuth];
}

#pragma mark - Web Service Request

- (void)getLoginURLWithCompletionBlock:(void (^)(NSURL *loginURL, NSError *error))onComplete {
	CKContainer *defContainer = [CKContainer defaultContainer];
	
	NSString *fetchCurrentUserURL = [NSString stringWithFormat:@"https://api.apple-cloudkit.com/database/1/%@/%@/private/users/current?ckAPIToken=%@",
									 defContainer.cloudKitContainerName,
									 defContainer.cloudKitEnvironment,
									 defContainer.cloudKitAPIToken];
	NSURLRequest *pendingRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:fetchCurrentUserURL]];
	[NSURLConnection sendAsynchronousRequest:pendingRequest queue:_urlQueue completionHandler:^(NSURLResponse *_Nullable response, NSData *_Nullable data, NSError *_Nullable connectionError) {
		
		if (connectionError) {
			onComplete(nil, connectionError);
		}
		
		NSError *error = nil;
		NSDictionary *parsedData = nil;
		if (data != nil) {
			parsedData = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
		}
		else {
			MediatorDebugLog(CKLOG_LEVEL_ERR, @"nil data returned trying to get login URL. Possible network timeout?");
		}
		
		if (error) {
			onComplete(nil, error);
		}
		else {
			NSString* redirectURL = parsedData[@"redirectURL"];
			NSURL* loginURL = nil;
			if (redirectURL) {
				loginURL = [NSURL URLWithString:parsedData[@"redirectURL"]];
			}
			
			if (loginURL) {
				onComplete(loginURL, nil);
			}
			else {
				onComplete(nil, [NSError errorWithDomain:CKErrorDomain code:NSIntegerMax userInfo:nil]);
			}
		}
	}];
}

#pragma mark - Remote Notifications

- (void)registerForRemoteNotifications {
	for (NSDictionary *containerProps in _containerProperties) {
		[[CKContainer containerWithIdentifier:containerProps[CloudKitJSContainerNameKey]] registerForRemoteNotifications];
	}
}

@end
