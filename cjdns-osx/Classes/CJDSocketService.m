//
//  CJDApiService.m
//  cjdns-osx
//
//  Created by maz on 2015-01-17.
//  Copyright (c) 2015 maz. All rights reserved.
//

#import "CJDSocketService.h"
#import "GCDAsyncUdpSocket.h"
#import "VOKBenkode.h"
#import <CommonCrypto/CommonDigest.h>
#import "NSData+Digest.h"
#import "DKQueue.h"

long const kCJDSocketServiceConnectPingTimeout = 5;
long const kCJDSocketServiceKeepAliveTimeout = 30;

typedef NS_ENUM(NSInteger, CJDSocketServiceSendTag) {
    CJDSocketServiceSendTagConnectPing = -9900,
    CJDSocketServiceSendTagKeepAlive = -9800
};

typedef void (^CJDCookieCompletionBlock)(NSString *);
typedef void(^CJDSocketServiceCompletionBlock)(NSDictionary *completion);

@interface CJDSocketService()
@property (strong, nonatomic) GCDAsyncUdpSocket *udpSocket;
@property (strong, nonatomic) dispatch_queue_t udpQueue;
@property (nonatomic, strong) NSString *password;
@property (nonatomic, strong) NSString *host;
@property (nonatomic) NSUInteger port;
@property (nonatomic, strong) NSOperationQueue *sendQueue;
@property (nonatomic, strong) DKQueue *cookieBlockQueue;
@property (nonatomic, strong) NSMutableArray *pagedResponseCache;
@property (nonatomic, strong) NSDictionary *messages;
@property (nonatomic, strong) NSNumber *keepAliveTimestamp;
@property (nonatomic, strong) NSTimer *connectPingTimer;
@end

@implementation CJDSocketService
{
    CJDSocketServiceCompletionBlock _adminFunctionsCompletionBlock;
    long _page;
}
- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port password:(NSString *)password delegate:(id<CJDSocketServiceDelegate>)delegate
{
    if ((self = [super init]))
    {
        self.host = host;
        self.port = port;
        self.password = password;
        self.delegate = delegate;
        self.connectPingTimer = nil;
        _udpQueue = dispatch_queue_create("me.maz.cjdns-osx.dispatch_queue", DISPATCH_QUEUE_SERIAL);
        _udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:_udpQueue socketQueue:_udpQueue];
        [_udpSocket setIPv6Enabled:YES];

        NSError *err = nil;
        if (![_udpSocket bindToPort:0 error:&err])
        {
            NSLog(@"Error binding: %@", err);
            return nil;
        }

        [_udpSocket beginReceiving:&err];
        NSLog(@"error: %@", err);
//        *error = err;
        
        self.sendQueue = [NSOperationQueue new];
        self.sendQueue.maxConcurrentOperationCount = 1;
        
        self.cookieBlockQueue = [DKQueue new];
        
        _page = 0;
        self.pagedResponseCache = [NSMutableArray array];
        self.messages = [NSDictionary dictionary];
        
        self.keepAliveTimestamp = [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]];
    }
    return self;
}

- (void)fetchCookie:(void(^)(NSString *cookie))completion
{
    [self.cookieBlockQueue enqueue:completion];
    [self send:@{@"q":@"cookie"} tag:-1];
}

- (void)function:(NSString *)function arguments:(NSDictionary *)arguments tag:(long)tag
{
    [self fetchCookie:^(NSString *cookie)
     {
         if (self.password)
         {
             NSData *cookieIn = [cookie dataUsingEncoding:NSUTF8StringEncoding];
             NSData *passwordIn = [self.password dataUsingEncoding:NSUTF8StringEncoding];
             NSMutableData *passwordCookieIn = [NSMutableData data];
             [passwordCookieIn appendData:passwordIn];
             [passwordCookieIn appendData:cookieIn];

             NSMutableData *passwordCookieOut = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
             CC_SHA256(passwordCookieIn.bytes, (uint32_t)passwordCookieIn.length,  passwordCookieOut.mutableBytes);
             
             NSDictionary *request = @{@"q": function,
                                       @"hash": [passwordCookieOut hexDigest],
                                       @"cookie": cookie,
                                       @"args": arguments};
             NSMutableDictionary *mutRequest = [NSMutableDictionary dictionary];

             // since `password` is not nil, we fix the request to be an auth-based request by adding an `aq` key
             [mutRequest addEntriesFromDictionary:request];
             [mutRequest setObject:[mutRequest objectForKey:@"q"] forKey:@"aq"];
             [mutRequest setObject:@"auth" forKey:@"q"];

             [mutRequest setObject:([function isEqualToString:@"cookie"] ? @"cookie" : [function isEqualToString:@"Admin_asyncEnabled"] ? @"keepalive" :  CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, CFUUIDCreate(NULL)))) forKey:@"txid"];
             
             // now sha256 the entire request
             NSData *bencodedRequestIn = [VOKBenkode encode:mutRequest];
             NSMutableData *bencodedRequestOut = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
             CC_SHA256(bencodedRequestIn.bytes, (uint32_t)bencodedRequestIn.length,  bencodedRequestOut.mutableBytes);
             [mutRequest setObject:[bencodedRequestOut hexDigest] forKey:@"hash"];
             
             [self send:mutRequest tag:tag];
         }
     }];
}

- (void)fetchAdminFunctions:(void(^)(NSDictionary *response))completion
{
    _adminFunctionsCompletionBlock = completion;
    [self function:@"Admin_availableFunctions" arguments:@{@"page": @1} tag:-1];
}

- (void)sendConnectPing
{
    [self.connectPingTimer invalidate];
    self.connectPingTimer = nil;
    self.connectPingTimer = [NSTimer scheduledTimerWithTimeInterval:kCJDSocketServiceConnectPingTimeout target:self selector:@selector(connectPingStatusCheck) userInfo:nil repeats:NO];
    [self.udpSocket sendData:[VOKBenkode encode:@{@"q":@"ping"}] toHost:self.host port:self.port withTimeout:kCJDSocketServiceConnectPingTimeout tag:CJDSocketServiceSendTagConnectPing];
}

- (void)connectPingStatusCheck
{
    if (self.connectPingTimer != nil)
    {
        if (self.delegate && [self.delegate respondsToSelector:@selector(connectionPingDidFailWithError:)])
        {
            [self.delegate connectionPingDidFailWithError:[NSError errorWithDomain:@"Initial Ping Failed" code:-1 userInfo:nil]];
        }
    }
}

- (void)keepAlive
{
    [self function:@"Admin_asyncEnabled" arguments:@{} tag:CJDSocketServiceSendTagKeepAlive];
}

- (void)send:(NSDictionary *)dictionary tag:(long)tag
{
    // on every send: we will check keepalive first
    if ([[NSDate date] timeIntervalSince1970] - [self.keepAliveTimestamp doubleValue] > (double)kCJDSocketServiceKeepAliveTimeout) {
        if (self.delegate && [self.delegate respondsToSelector:@selector(keepAliveDidFailWithError:)])
        {
            [self.delegate keepAliveDidFailWithError:[NSError errorWithDomain:@"Server keepalive timeout" code:-1 userInfo:nil]];
        }
    } else {
        [self.sendQueue addOperation:[NSBlockOperation blockOperationWithBlock:^{
            NSMutableDictionary *sendDict = [NSMutableDictionary dictionary];
            
            //        [sendDict addEntriesFromDictionary:[self defaultParameters]];
            [sendDict addEntriesFromDictionary:dictionary];
            
            // if we're about to get a cookie, send `cookie` as the txid so we
            // can identify it when its received over UDP
            if ([[sendDict allValues] containsObject:@"cookie"])
            {
                [sendDict setObject:@"cookie" forKey:@"txid"];
            }
            
            //        NSLog(@"sendDict: %@", sendDict);
            NSMutableDictionary *messages = [self.messages mutableCopy];
            NSMutableDictionary *messageDict = [sendDict mutableCopy];
            
            [messageDict setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] forKey:@"timestamp"];
            [messages setObject:messageDict forKey:[sendDict objectForKey:@"txid"]];
            self.messages = [messages copy];
            [self.udpSocket sendData:[VOKBenkode encode:sendDict] toHost:self.host port:self.port withTimeout:30 tag:tag];
        }]];
    }
}

#pragma mark - GCDAsyncUdpSocketDelegate

/**
 * By design, UDP is a connectionless protocol, and connecting is not needed.
 * However, you may optionally choose to connect to a particular host for reasons
 * outlined in the documentation for the various connect methods listed above.
 *
 * This method is called if one of the connect methods are invoked, and the connection is successful.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didConnectToAddress:(NSData *)address
{
    NSLog(@"didConnectToAddress: %@", [[NSString alloc] initWithData:address encoding:NSUTF8StringEncoding]);
}

/**
 * By design, UDP is a connectionless protocol, and connecting is not needed.
 * However, you may optionally choose to connect to a particular host for reasons
 * outlined in the documentation for the various connect methods listed above.
 *
 * This method is called if one of the connect methods are invoked, and the connection fails.
 * This may happen, for example, if a domain name is given for the host and the domain name is unable to be resolved.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotConnect:(NSError *)error
{
    NSLog(@"didNotConnect: %@", [error description]);
}

/**
 * Called when the datagram with the given tag has been sent.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didSendDataWithTag:(long)tag
{
    NSLog(@"didSendDataWithTag: %ld", tag);
}

/**
 * Called if an error occurs while trying to send a datagram.
 * This could be due to a timeout, or something more serious such as the data being too large to fit in a sigle packet.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error
{
    NSLog(@"didNotSendDataWithTag: %ld %@", tag, [error description]);
}

/**
 * Called when the socket has received the requested datagram.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext
{
    NSDictionary *dataDict = [VOKBenkode decode:data options:0 error:nil];
    NSLog(@"dataDict: %@", dataDict);
//    NSLog(@"self.messages: %@", self.messages);
    if ([[dataDict objectForKey:@"q"] isEqualToString:@"pong"])
    {
        [self.connectPingTimer invalidate];
        self.connectPingTimer = nil;
        if (self.delegate && [self.delegate respondsToSelector:@selector(connectionPingDidSucceed)])
        {
            [self.delegate connectionPingDidSucceed];
        }
    }
    if ([[dataDict objectForKey:@"txid"] isEqualToString:@"cookie"])
    {
        if (!self.cookieBlockQueue.isEmpty)
        {
            void(^CJDCookieCompletionBlock)(NSString *) = [self.cookieBlockQueue dequeue];
            CJDCookieCompletionBlock([dataDict objectForKey:@"cookie"]);
        }
    }
    if ([[dataDict objectForKey:@"txid"] isEqualToString:@"keepalive"])
    {
        if (self.delegate && [self.delegate respondsToSelector:@selector(keepAliveDidSucceed)])
        {
            [self.delegate keepAliveDidSucceed];
            self.keepAliveTimestamp = [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]];
        }
    }
    if ([dataDict objectForKey:@"availableFunctions"] && [dataDict objectForKey:@"more"])
    {
        [self.pagedResponseCache addObject:[dataDict objectForKey:@"availableFunctions"]];
        _page++;
        [self function:@"Admin_availableFunctions" arguments:@{@"page": [NSNumber numberWithLong:_page]} tag:-1];
    }
    else if ([dataDict objectForKey:@"availableFunctions"] && ![dataDict objectForKey:@"more"])
    {
        // no more admin functions
        NSMutableDictionary *adminFunctions = [NSMutableDictionary dictionary];
        for (NSDictionary *page in self.pagedResponseCache)
        {
            [adminFunctions addEntriesFromDictionary:page];
        }
        _adminFunctionsCompletionBlock(adminFunctions);
        _page = 0;
        self.pagedResponseCache = [NSMutableArray array];
    }
}

/**
 * Called when the socket is closed.
 **/
- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error
{
    NSLog(@"udpSocketDidClose: %@", [error description]);
}

@end
