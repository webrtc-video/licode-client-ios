/*
 *  Copyright 2014 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "ARDAppEngineClient.h"

#import "WebRTC/RTCLogging.h"

#import "ARDJoinResponse.h"
#import "ARDMessageResponse.h"
#import "ARDSignalingMessage.h"
#import "ARDUtilities.h"

// TODO(tkchin): move these to a configuration object.
static NSString * const kARDRoomServerHostUrl =
    @"https://webrtc.serverip.com:3004";
static NSString * const kARDRoomServerJoinFormat =
    @"https://webrtc.serverip.com:3004/%@";

static NSString * const kARDRoomServerJoinFormatLoopback =
    @"http://192.168.1.105:8080/join/%@?debug=loopback";
static NSString * const kARDRoomServerMessageFormat =
    @"http://192.168.1.105:8080/message/%@/%@";
static NSString * const kARDRoomServerLeaveFormat =
    @"http://192.168.1.105:8080/leave/%@/%@";

static NSString * const kARDAppEngineClientErrorDomain = @"ARDAppEngineClient";
static NSInteger const kARDAppEngineClientErrorBadResponse = -1;

@implementation ARDAppEngineClient

#pragma mark - ARDRoomServerClient

- (void)createToken:(NSString *)userName
                role:(NSString *)role
         completionHandler:(void (^)(ARDJoinResponse *response,
                                     NSError *error))completionHandler {
  NSParameterAssert(userName.length);

  NSString *urlString = [NSString stringWithFormat:kARDRoomServerJoinFormat, @"createToken/"];

  NSURL *roomURL = [NSURL URLWithString:urlString];
  RTCLog(@"createToken:%@ on room server.", userName);
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:roomURL];
  request.HTTPMethod = @"POST";
    NSDictionary *json = @{
                           @"username" : userName,
                           @"role" : role,
                           @"room" : userName
                           };
    request.HTTPBody =  [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
  __weak ARDAppEngineClient *weakSelf = self;
  [NSURLConnection sendAsyncRequest:request
                  completionHandler:^(NSURLResponse *response,
                                      NSData *data,
                                      NSError *error) {
    ARDAppEngineClient *strongSelf = weakSelf;
    if (error) {
      if (completionHandler) {
        completionHandler(nil, error);
      }
      return;
    }
    ARDJoinResponse *joinResponse =
        [ARDJoinResponse responseFromJSONData:data];
    if (!joinResponse) {
      if (completionHandler) {
        NSError *error = [[self class] badResponseError];
        completionHandler(nil, error);
      }
      return;
    }
    if (completionHandler) {
      completionHandler(joinResponse, nil);
    }
  }];
}

- (void)sendMessage:(ARDSignalingMessage *)message
            forRoomId:(NSString *)roomId
             clientId:(NSString *)clientId
    completionHandler:(void (^)(ARDMessageResponse *response,
                                NSError *error))completionHandler {
  NSParameterAssert(message);
  NSParameterAssert(roomId.length);
  NSParameterAssert(clientId.length);

  NSData *data = [message JSONData];
  NSString *urlString =
      [NSString stringWithFormat:
          kARDRoomServerMessageFormat, roomId, clientId];
  NSURL *url = [NSURL URLWithString:urlString];
  RTCLog(@"C->RS POST: %@", message);
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = data;
  __weak ARDAppEngineClient *weakSelf = self;
  [NSURLConnection sendAsyncRequest:request
                  completionHandler:^(NSURLResponse *response,
                                      NSData *data,
                                      NSError *error) {
    ARDAppEngineClient *strongSelf = weakSelf;
    if (error) {
      if (completionHandler) {
        completionHandler(nil, error);
      }
      return;
    }
    ARDMessageResponse *messageResponse =
        [ARDMessageResponse responseFromJSONData:data];
    if (!messageResponse) {
      if (completionHandler) {
        NSError *error = [[self class] badResponseError];
        completionHandler(nil, error);
      }
      return;
    }
    if (completionHandler) {
      completionHandler(messageResponse, nil);
    }
  }];
}

- (void)leaveRoomWithRoomId:(NSString *)roomId
                   clientId:(NSString *)clientId
          completionHandler:(void (^)(NSError *error))completionHandler {
  NSParameterAssert(roomId.length);
  NSParameterAssert(clientId.length);

  NSString *urlString =
      [NSString stringWithFormat:kARDRoomServerLeaveFormat, roomId, clientId];
  NSURL *url = [NSURL URLWithString:urlString];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  NSURLResponse *response = nil;
  NSError *error = nil;
  // We want a synchronous request so that we know that we've left the room on
  // room server before we do any further work.
  RTCLog(@"C->RS: BYE");
  [NSURLConnection sendSynchronousRequest:request
                        returningResponse:&response
                                    error:&error];
  if (error) {
    RTCLogError(@"Error leaving room %@ on room server: %@",
          roomId, error.localizedDescription);
    if (completionHandler) {
      completionHandler(error);
    }
    return;
  }
  RTCLog(@"Left room:%@ on room server.", roomId);
  if (completionHandler) {
    completionHandler(nil);
  }
}

#pragma mark - Private

+ (NSError *)badResponseError {
  NSError *error =
      [[NSError alloc] initWithDomain:kARDAppEngineClientErrorDomain
                                 code:kARDAppEngineClientErrorBadResponse
                             userInfo:@{
    NSLocalizedDescriptionKey: @"Error parsing response.",
  }];
  return error;
}

@end
