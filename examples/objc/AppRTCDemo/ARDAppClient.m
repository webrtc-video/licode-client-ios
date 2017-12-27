/*
 *  Copyright 2014 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "ARDAppClient+Internal.h"

#import "WebRTC/RTCAVFoundationVideoSource.h"
#import "WebRTC/RTCAudioTrack.h"
#import "WebRTC/RTCConfiguration.h"
#import "WebRTC/RTCFileLogger.h"
#import "WebRTC/RTCIceServer.h"
#import "WebRTC/RTCLogging.h"
#import "WebRTC/RTCMediaConstraints.h"
#import "WebRTC/RTCMediaStream.h"
#import "WebRTC/RTCPeerConnectionFactory.h"
#import "WebRTC/RTCRtpSender.h"
#import "WebRTC/RTCTracing.h"

#import "ARDAppEngineClient.h"
#import "ARDCEODTURNClient.h"
#import "ARDJoinResponse.h"
#import "ARDMessageResponse.h"
#import "ARDSDPUtils.h"
#import "ARDSignalingMessage.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCIceCandidate+JSON.h"
#import "RTCSessionDescription+JSON.h"

#import "socketio/SocketIOPacket.h"

static NSString * const kARDDefaultSTUNServerUrl = @"stun:stun.l.google.com:19302";
// TODO(tkchin): figure out a better username for CEOD statistics.
static NSString * const kARDTurnRequestUrl =
    @"https://computeengineondemand.appspot.com"
    @"/turn?username=iapprtc&key=4080218913";

static NSString * const kARDAppClientErrorDomain = @"ARDAppClient";
static NSInteger const kARDAppClientErrorUnknown = -1;
static NSInteger const kARDAppClientErrorRoomFull = -2;
static NSInteger const kARDAppClientErrorCreateSDP = -3;
static NSInteger const kARDAppClientErrorSetSDP = -4;
static NSInteger const kARDAppClientErrorInvalidClient = -5;
static NSInteger const kARDAppClientErrorInvalidRoom = -6;

static NSString * const kARDMediaStreamId = @"ARDAMS";
static NSString * const kARDAudioTrackId = @"ARDAMSa0";
static NSString * const kARDVideoTrackId = @"ARDAMSv0";
static NSString * const kARDVideoTrackKind = @"video";

// TODO(tkchin): Remove guard once rtc_base_objc compiles on Mac.
#if defined(WEBRTC_IOS)
// TODO(tkchin): Add this as a UI option.
static BOOL const kARDAppClientEnableTracing = NO;
#endif
static BOOL const kARDAppClientEnableRtcEventLog = YES;
static int64_t const kARDAppClientAecDumpMaxSizeInBytes = 5e6;  // 5 MB.
static int64_t const kARDAppClientRtcEventLogMaxSizeInBytes = 5e6;  // 5 MB.
static int const kKbpsMultiplier = 1000;

// We need a proxy to NSTimer because it causes a strong retain cycle. When
// using the proxy, |invalidate| must be called before it properly deallocs.
@interface ARDTimerProxy : NSObject

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler;
- (void)invalidate;

@end

@implementation ARDTimerProxy {
  NSTimer *_timer;
  void (^_timerHandler)(void);
}

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler {
  NSParameterAssert(timerHandler);
  if (self = [super init]) {
    _timerHandler = timerHandler;
    _timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                              target:self
                                            selector:@selector(timerDidFire:)
                                            userInfo:nil
                                             repeats:repeats];
  }
  return self;
}

- (void)invalidate {
  [_timer invalidate];
}

- (void)timerDidFire:(NSTimer *)timer {
  _timerHandler();
}

@end

@implementation ARDAppClient {
  RTCFileLogger *_fileLogger;
  ARDTimerProxy *_statsTimer;
}

@synthesize shouldGetStats = _shouldGetStats;
@synthesize state = _state;
@synthesize delegate = _delegate;
@synthesize roomServerClient = _roomServerClient;
@synthesize channel = _channel;
@synthesize loopbackChannel = _loopbackChannel;
@synthesize turnClient = _turnClient;
@synthesize peerConnection = _peerConnection;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize isTurnComplete = _isTurnComplete;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize iceServers = _iceServers;
@synthesize webSocketURL = _websocketURL;
@synthesize webSocketRestURL = _websocketRestURL;
@synthesize defaultPeerConnectionConstraints =
    _defaultPeerConnectionConstraints;
@synthesize isLoopback = _isLoopback;
@synthesize isAudioOnly = _isAudioOnly;


@synthesize socketIO = _socketIO;
@synthesize isSecure = _isSecure;
@synthesize tokenId = _tokenId;
@synthesize host = _host;
@synthesize tokenDict = _tokenDict;
@synthesize peerConnectionSubDict = _peerConnectionSubDict;

- (instancetype)init {
  if (self = [super init]) {
    _roomServerClient = [[ARDAppEngineClient alloc] init];
    NSURL *turnRequestURL = [NSURL URLWithString:kARDTurnRequestUrl];
    _turnClient = [[ARDCEODTURNClient alloc] initWithURL:turnRequestURL];
    [self configure];
  }
  return self;
}

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
  if (self = [super init]) {
    _roomServerClient = [[ARDAppEngineClient alloc] init];
    _delegate = delegate;
    NSURL *turnRequestURL = [NSURL URLWithString:kARDTurnRequestUrl];
    _turnClient = [[ARDCEODTURNClient alloc] initWithURL:turnRequestURL];
    [self configure];
      
  }
  return self;
}

/*
// TODO(tkchin): Provide signaling channel factory interface so we can recreate
// channel if we need to on network failure. Also, make this the default public
// constructor.
- (instancetype)initWithRoomServerClient:(id<ARDRoomServerClient>)rsClient
                        signalingChannel:(id<ARDSignalingChannel>)channel
                              turnClient:(id<ARDTURNClient>)turnClient
                                delegate:(id<ARDAppClientDelegate>)delegate {
  NSParameterAssert(rsClient);
  NSParameterAssert(channel);
  NSParameterAssert(turnClient);
  if (self = [super init]) {
    _roomServerClient = rsClient;
    _channel = channel;
    _turnClient = turnClient;
    _delegate = delegate;
    [self configure];
  }
  return self;
}*/

- (void)configure {
  _factory = [[RTCPeerConnectionFactory alloc] init];
  _messageQueue = [NSMutableArray array];
  //_iceServers = [NSMutableArray arrayWithObject:[self defaultSTUNServer]];
  _fileLogger = [[RTCFileLogger alloc] init];
  [_fileLogger start];
    
    _peerConnectionSubDict = [[NSMutableDictionary alloc] init];
}

- (void)dealloc {
  self.shouldGetStats = NO;
  [self disconnect];
}

- (void)setShouldGetStats:(BOOL)shouldGetStats {
  if (_shouldGetStats == shouldGetStats) {
    return;
  }
  if (shouldGetStats) {
    __weak ARDAppClient *weakSelf = self;
    _statsTimer = [[ARDTimerProxy alloc] initWithInterval:1
                                                  repeats:YES
                                             timerHandler:^{
      ARDAppClient *strongSelf = weakSelf;
      [strongSelf.peerConnection statsForTrack:nil
                              statsOutputLevel:RTCStatsOutputLevelDebug
                             completionHandler:^(NSArray *stats) {
        dispatch_async(dispatch_get_main_queue(), ^{
          ARDAppClient *strongSelf = weakSelf;
          [strongSelf.delegate appClient:strongSelf didGetStats:stats];
        });
      }];
    }];
  } else {
    [_statsTimer invalidate];
    _statsTimer = nil;
  }
  _shouldGetStats = shouldGetStats;
}

- (void)setState:(ARDAppClientState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate appClient:self didChangeState:_state];
}

- (void)connectToRoomWithId:(NSString *)roomId
                 isLoopback:(BOOL)isLoopback
                isAudioOnly:(BOOL)isAudioOnly {
  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDAppClientStateDisconnected);
  _isLoopback = isLoopback;
  _isAudioOnly = isAudioOnly;
  self.state = kARDAppClientStateConnecting;

#if defined(WEBRTC_IOS)
  if (kARDAppClientEnableTracing) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-trace.txt"];
    RTCStartInternalCapture(filePath);
  }
#endif

  // Request TURN.
  __weak ARDAppClient *weakSelf = self;
  /*[_turnClient requestServersWithCompletionHandler:^(NSArray *turnServers,
                                                     NSError *error) {
    if (error) {
      RTCLogError("Error retrieving TURN servers: %@",
                  error.localizedDescription);
    }
    ARDAppClient *strongSelf = weakSelf;
    [strongSelf.iceServers addObjectsFromArray:turnServers];
    strongSelf.isTurnComplete = YES;
    [strongSelf startSignalingIfReady];
  }];*/

  // Join room on room server.
  [_roomServerClient createToken:roomId
                             role:@"presenter"
      completionHandler:^(ARDJoinResponse *response, NSError *error) {
    ARDAppClient *strongSelf = weakSelf;
    if (error) {
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    /*NSError *joinError =
        [[strongSelf class] errorForJoinResultType:response.result];
    if (joinError) {
      RTCLogError(@"Failed to join room:%@ on room server.", roomId);
      [strongSelf disconnect];
      [strongSelf.delegate appClient:strongSelf didError:joinError];
      return;
    }*/
    RTCLog(@"Joined room:%@ on room server.", roomId);
    /*strongSelf.roomId = response.roomId;
    strongSelf.clientId = response.clientId;
    strongSelf.isInitiator = response.isInitiator;
    for (ARDSignalingMessage *message in response.messages) {
      if (message.type == kARDSignalingMessageTypeOffer ||
          message.type == kARDSignalingMessageTypeAnswer) {
        strongSelf.hasReceivedSdp = YES;
        [strongSelf.messageQueue insertObject:message atIndex:0];
      } else {
        [strongSelf.messageQueue addObject:message];
      }
    }
    strongSelf.webSocketURL = @"ws://192.168.1.105:8089/ws"; //response.webSocketURL; lihengz
    strongSelf.webSocketRestURL = @"http://192.168.1.105:8089";//response.webSocketRestURL;*/
          
          strongSelf.isSecure = response.isSecure;
          strongSelf.tokenId = response.tokenId;
          strongSelf.host = response.host;
          strongSelf.tokenDict = response.tokenDict;
          strongSelf.isInitiator = true;
          
    [strongSelf registerWithColliderIfReady];
    //[strongSelf startSignalingIfReady];
  }];
}

- (void)disconnect {
  if (_state == kARDAppClientStateDisconnected) {
    return;
  }
  /*
  if (self.hasJoinedRoomServerRoom) {
    [_roomServerClient leaveRoomWithRoomId:_roomId
                                  clientId:_clientId
                         completionHandler:nil];
  }
  if (_channel) {
    if (_channel.state == kARDSignalingChannelStateRegistered) {
      // Tell the other client we're hanging up.
      ARDByeMessage *byeMessage = [[ARDByeMessage alloc] init];
      [_channel sendMessage:byeMessage];
    }
    // Disconnect from collider.
    _channel = nil;
  }*/

    if(_socketIO)
    {
        NSDictionary *recjson = @{
                                  @"id" : self.recordId
                                  };
        [_socketIO sendEvent:@"stopRecorder" withData:recjson andAcknowledge:^(id argsData) {
            
        }];
        
        [_socketIO disconnect];
        _socketIO = nil;
    }
  
    _tokenId = nil;
  _clientId = nil;
  _roomId = nil;
  _isInitiator = NO;
  _hasReceivedSdp = NO;
  _messageQueue = [NSMutableArray array];
  _peerConnection = nil;
    for(id key in _peerConnectionSubDict) {
        _peerConnectionSubDict[key] = nil;
    }
    [_peerConnectionSubDict removeAllObjects];
    
  self.state = kARDAppClientStateDisconnected;
#if defined(WEBRTC_IOS)
    if (kARDAppClientEnableTracing) {
        RTCStopInternalCapture();
    }
#endif
}

#pragma mark - ARDSignalingChannelDelegate

- (void)channel:(id<ARDSignalingChannel>)channel
    didReceiveMessage:(ARDSignalingMessage *)message {
  /*switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer:
      // Offers and answers must be processed before any other message, so we
      // place them at the front of the queue.
      _hasReceivedSdp = YES;
      [_messageQueue insertObject:message atIndex:0];
      break;
    case kARDSignalingMessageTypeCandidate:
      [_messageQueue addObject:message];
      break;
    case kARDSignalingMessageTypeBye:
      // Disconnects can be processed immediately.
      [self processSignalingMessage:message];
      return;
  }
  [self drainMessageQueueIfReady];*/
}

- (void)channel:(id<ARDSignalingChannel>)channel
    didChangeState:(ARDSignalingChannelState)state {
  /*switch (state) {
    case kARDSignalingChannelStateOpen:
      break;
    case kARDSignalingChannelStateRegistered:
      break;
    case kARDSignalingChannelStateClosed:
    case kARDSignalingChannelStateError:
      // TODO(tkchin): reconnection scenarios. Right now we just disconnect
      // completely if the websocket connection fails.
      [self disconnect];
      break;
  }*/
}

#pragma mark - RTCPeerConnectionDelegate
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeSignalingState:(RTCSignalingState)stateChanged {
  RTCLog(@"Signaling state changed: %ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
          didAddStream:(RTCMediaStream *)stream {
  dispatch_async(dispatch_get_main_queue(), ^{
    RTCLog(@"Received %lu video tracks and %lu audio tracks",
        (unsigned long)stream.videoTracks.count,
        (unsigned long)stream.audioTracks.count);
    if (stream.videoTracks.count) {
      RTCVideoTrack *videoTrack = stream.videoTracks[0];
      [_delegate appClient:self didReceiveRemoteVideoTrack:videoTrack];
    }
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
       didRemoveStream:(RTCMediaStream *)stream {
  RTCLog(@"Stream was removed.");
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
  RTCLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeIceConnectionState:(RTCIceConnectionState)newState {
  RTCLog(@"ICE state changed: %ld", (long)newState);
  dispatch_async(dispatch_get_main_queue(), ^{
    [_delegate appClient:self didChangeConnectionState:newState];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeIceGatheringState:(RTCIceGatheringState)newState {
  RTCLog(@"ICE gathering state changed: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didGenerateIceCandidate:(RTCIceCandidate *)candidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    /*ARDICECandidateMessage *message =
        [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
    [self sendSignalingMessage:message];*/
      if(peerConnection == self.peerConnection) {
          NSDictionary *json = @{
                             @"streamId" : self.clientId,
                             @"msg":@{
                                     @"type" : @"candidate",
                                     @"candidate" : @{
                                             @"sdpMLineIndex" : @(candidate.sdpMLineIndex),
                                             @"sdpMid" : candidate.sdpMid,
                                             @"candidate" : [@"a=" stringByAppendingString:candidate.sdp] //@"a="+candidate.sdp
                                             }
                                     }
                             };
      
          [_socketIO sendEvent:@"signaling_message" withData:json withOption:@{} andAcknowledge:nil];
      }
      
      else {
           for(id key in self.peerConnectionSubDict) {
               if(self.peerConnectionSubDict[key] == peerConnection) {
                   NSDictionary *json = @{
                                          @"streamId" : key,
                                          @"msg":@{
                                                  @"type" : @"candidate",
                                                  @"candidate" : @{
                                                          @"sdpMLineIndex" : @(candidate.sdpMLineIndex),
                                                          @"sdpMid" : candidate.sdpMid,
                                                          @"candidate" : [@"a=" stringByAppendingString:candidate.sdp] //@"a="+candidate.sdp
                                                          }
                                                  }
                                          };
                   
                   [_socketIO sendEvent:@"signaling_message" withData:json withOption:@{} andAcknowledge:nil];
                   break;
               }
           }
      }
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    /*dispatch_async(dispatch_get_main_queue(), ^{
        ARDICECandidateRemovalMessage *message =
        [[ARDICECandidateRemovalMessage alloc]
         initWithRemovedCandidates:candidates];
        [self sendSignalingMessage:message];
    });*/
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didOpenDataChannel:(RTCDataChannel *)dataChannel {
}

#pragma mark - RTCSessionDescriptionDelegate
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didCreateSessionDescription:(RTCSessionDescription *)sdp
                          error:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      RTCLogError(@"Failed to create session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to create session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorCreateSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    // Prefer H264 if available.
    RTCSessionDescription *sdpPreferringH264 =
        [ARDSDPUtils descriptionForDescription:sdp
                           preferredVideoCodec:@"H264"];
    __weak ARDAppClient *weakSelf = self;
    [_peerConnection setLocalDescription:sdpPreferringH264
                       completionHandler:^(NSError *error) {
      ARDAppClient *strongSelf = weakSelf;
      [strongSelf peerConnection:strongSelf.peerConnection
          didSetSessionDescriptionWithError:error];
    }];
    
    /*ARDSessionDescriptionMessage *message =
        [[ARDSessionDescriptionMessage alloc]
            initWithDescription:sdpPreferringH264];
    [self sendSignalingMessage:message];*/
      NSDictionary *json = @{
                             @"streamId" : self.clientId,
                             @"msg":@{
                                      @"type" : @"offer",
                                      @"sdp" : sdpPreferringH264.sdp
                                    }
                            };
      
      [_socketIO sendEvent:@"signaling_message" withData:json withOption:@{} andAcknowledge:nil];
      
      [self setMaxBitrateForPeerConnectionVideoSender];
      
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didSetSessionDescriptionWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      RTCLogError(@"Failed to set session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to set session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorSetSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    // If we're answering and we've just set the remote offer we need to create
    // an answer and set the local description.
    if (!_isInitiator && !_peerConnection.localDescription) {
      RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
      __weak ARDAppClient *weakSelf = self;
      [_peerConnection answerForConstraints:constraints
                          completionHandler:^(RTCSessionDescription *sdp,
                                              NSError *error) {
        ARDAppClient *strongSelf = weakSelf;
        [strongSelf peerConnection:strongSelf.peerConnection
            didCreateSessionDescription:sdp
                                  error:error];
      }];
    }
  });
}

#pragma mark - Private

#if defined(WEBRTC_IOS)

- (NSString *)documentsFilePathForFileName:(NSString *)fileName {
    NSParameterAssert(fileName.length);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
                                                         NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirPath = paths.firstObject;
    NSString *filePath =
    [documentsDirPath stringByAppendingPathComponent:fileName];
    return filePath;
}

#endif

- (BOOL)hasJoinedRoomServerRoom {
  return _tokenId.length;
}

// Begins the peer connection connection process if we have both joined a room
// on the room server and tried to obtain a TURN server. Otherwise does nothing.
// A peer connection object will be created with a stream that contains local
// audio and video capture. If this client is the caller, an offer is created as
// well, otherwise the client will wait for an offer to arrive.
- (void)startSignalingIfReady {
  if (/*!_isTurnComplete ||*/ !self.hasJoinedRoomServerRoom) { //lihengz
    return;
  }
  self.state = kARDAppClientStateConnected;

  // Create peer connection.
  RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
  RTCConfiguration *config = [[RTCConfiguration alloc] init];
  config.iceServers = _iceServers;
    //config.iceTransportPolicy = RTCIceTransportPolicyRelay; //todo
    //config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
    config.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;
    config.iceConnectionReceivingTimeout = 6000;
    //config.bundlePolicy = RTCBundlePolicyMaxBundle;
    //config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    //config.shouldPresumeWritableWhenFullyRelayed = TRUE;
  _peerConnection = [_factory peerConnectionWithConfiguration:config
                                                   constraints:constraints
                                                      delegate:self];
  // Create AV media stream and add it to the peer connection.
  //RTCMediaStream *localStream = [self createLocalMediaStream];
  //[_peerConnection addStream:localStream];
    // Create AV senders.
    [self createAudioSender];
    [self createVideoSender];
  if (_isInitiator) { //lihengz
    // Send offer.
    __weak ARDAppClient *weakSelf = self;
    [_peerConnection offerForConstraints:[self defaultOfferConstraints]
                       completionHandler:^(RTCSessionDescription *sdp,
                                           NSError *error) {
      ARDAppClient *strongSelf = weakSelf;
      [strongSelf peerConnection:strongSelf.peerConnection
          didCreateSessionDescription:sdp
                                error:error];
    }];
  } else {
    // Check if we've received an offer.
    [self drainMessageQueueIfReady];
  }
    
#if defined(WEBRTC_IOS)
    // Start event log.
    if (kARDAppClientEnableRtcEventLog) {
        NSString *filePath = [self documentsFilePathForFileName:@"webrtc-rtceventlog"];
        if (![_peerConnection startRtcEventLogWithFilePath:filePath
                                            maxSizeInBytes:kARDAppClientRtcEventLogMaxSizeInBytes]) {
            RTCLogError(@"Failed to start event logging.");
        }
    }
    
    // Start aecdump diagnostic recording.
    /*if (_shouldMakeAecDump) {
        NSString *filePath = [self documentsFilePathForFileName:@"webrtc-audio.aecdump"];
        if (![_factory startAecDumpWithFilePath:filePath
                                 maxSizeInBytes:kARDAppClientAecDumpMaxSizeInBytes]) {
            RTCLogError(@"Failed to start aec dump.");
        }
    }*/
#endif
}



- (void)startSubscribe:(NSString *)streamId {
    
    // Create peer connection.
    RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = _iceServers;
    //config.iceTransportPolicy = RTCIceTransportPolicyRelay;
    //config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
    config.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;
    config.iceConnectionReceivingTimeout = 6000;
    //config.bundlePolicy = RTCBundlePolicyMaxBundle;
    //config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    //config.shouldPresumeWritableWhenFullyRelayed = TRUE;
    RTCPeerConnection *peerConnection = [_factory peerConnectionWithConfiguration:config
                                                     constraints:constraints
                                                        delegate:self];
    
    [_peerConnectionSubDict setValue:peerConnection forKey:streamId];

        // Send offer.
        __weak ARDAppClient *weakSelf = self;
        [peerConnection offerForConstraints:[self defaultOfferConstraints]
                           completionHandler:^(RTCSessionDescription *sdp,
                                               NSError *error) {
            ARDAppClient *strongSelf = weakSelf;
                               dispatch_async(dispatch_get_main_queue(), ^{
                                   if (error) {
                                       RTCLogError(@"Failed to create session description. Error: %@", error);
                                       return;
                                   }
                                   // Prefer H264 if available.
                                   RTCSessionDescription *sdpPreferringH264 =
                                   [ARDSDPUtils descriptionForDescription:sdp
                                                      preferredVideoCodec:@"H264"];
                                   __weak ARDAppClient *weakSelf = self;
                                   [peerConnection setLocalDescription:sdpPreferringH264
                                                      completionHandler:^(NSError *error) {
                                                          if (error) {
                                                              RTCLogError(@"Failed to set local description. Error: %@", error);
                                                          }
                                                      }];
                                   

                                   NSDictionary *json = @{
                                                          @"streamId" : streamId,
                                                          @"msg":@{
                                                                  @"type" : @"offer",
                                                                  @"sdp" : sdpPreferringH264.sdp
                                                                  }
                                                          };
                                   
                                   [_socketIO sendEvent:@"signaling_message" withData:json withOption:@{} andAcknowledge:nil];
                                   
                               });
                               
        }];
}


// Processes the messages that we've received from the room server and the
// signaling channel. The offer or answer message must be processed before other
// signaling messages, however they can arrive out of order. Hence, this method
// only processes pending messages if there is a peer connection object and
// if we have received either an offer or answer.
- (void)drainMessageQueueIfReady {
  if (!_peerConnection || !_hasReceivedSdp) {
    return;
  }
  for (ARDSignalingMessage *message in _messageQueue) {
    [self processSignalingMessage:message];
  }
  [_messageQueue removeAllObjects];
}

// Processes the given signaling message based on its type.
- (void)processSignalingMessage:(ARDSignalingMessage *)message {
  NSParameterAssert(_peerConnection ||
      message.type == kARDSignalingMessageTypeBye);
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer: {
      ARDSessionDescriptionMessage *sdpMessage =
          (ARDSessionDescriptionMessage *)message;
      RTCSessionDescription *description = sdpMessage.sessionDescription;
      // Prefer H264 if available.
      RTCSessionDescription *sdpPreferringH264 =
          [ARDSDPUtils descriptionForDescription:description
                             preferredVideoCodec:@"H264"];
      __weak ARDAppClient *weakSelf = self;
      [_peerConnection setRemoteDescription:sdpPreferringH264
                          completionHandler:^(NSError *error) {
        ARDAppClient *strongSelf = weakSelf;
        [strongSelf peerConnection:strongSelf.peerConnection
            didSetSessionDescriptionWithError:error];
      }];
      break;
    }
    case kARDSignalingMessageTypeCandidate: {
      ARDICECandidateMessage *candidateMessage =
          (ARDICECandidateMessage *)message;
      [_peerConnection addIceCandidate:candidateMessage.candidate];
      break;
    }
    case kARDSignalingMessageTypeBye:
      // Other client disconnected.
      // TODO(tkchin): support waiting in room for next client. For now just
      // disconnect.
      [self disconnect];
      break;
  }
}

// Sends a signaling message to the other client. The caller will send messages
// through the room server, whereas the callee will send messages over the
// signaling channel.
/*
- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
  if (_isInitiator) {
    __weak ARDAppClient *weakSelf = self;
    [_roomServerClient sendMessage:message
                         forRoomId:_roomId
                          clientId:_clientId
                 completionHandler:^(ARDMessageResponse *response,
                                     NSError *error) {
      ARDAppClient *strongSelf = weakSelf;
      if (error) {
        [strongSelf.delegate appClient:strongSelf didError:error];
        return;
      }
      NSError *messageError =
          [[strongSelf class] errorForMessageResultType:response.result];
      if (messageError) {
        [strongSelf.delegate appClient:strongSelf didError:messageError];
        return;
      }
    }];
  } else {
    [_channel sendMessage:message];
  }
}*/

- (RTCRtpSender *)createVideoSender {
    RTCRtpSender *sender =
    [_peerConnection senderWithKind:kRTCMediaStreamTrackKindVideo
                           streamId:kARDMediaStreamId];
    RTCVideoTrack *track = [self createLocalVideoTrack];
    if (track) {
        sender.track = track;
        [_delegate appClient:self didReceiveLocalVideoTrack:track];
    }
    
    return sender;
}

- (void)setMaxBitrateForPeerConnectionVideoSender {
    for (RTCRtpSender *sender in _peerConnection.senders) {
        if (sender.track != nil) {
            if ([sender.track.kind isEqualToString:kARDVideoTrackKind]) {
                [self setMaxBitrate:@800 forVideoSender:sender];
            }
        }
    }
}

- (void)setMaxBitrate:(NSNumber *)maxBitrate forVideoSender:(RTCRtpSender *)sender {
    if (maxBitrate.intValue <= 0) {
        return;
    }
    
    RTCRtpParameters *parametersToModify = sender.parameters;
    for (RTCRtpEncodingParameters *encoding in parametersToModify.encodings) {
        encoding.maxBitrateBps = @(maxBitrate.intValue * kKbpsMultiplier);
    }
    [sender setParameters:parametersToModify];
}

- (RTCRtpSender *)createAudioSender {
    RTCMediaConstraints *constraints = [self defaultMediaAudioConstraints];
    RTCAudioSource *source = [_factory audioSourceWithConstraints:constraints];
    RTCAudioTrack *track = [_factory audioTrackWithSource:source
                                                  trackId:kARDAudioTrackId];
    RTCRtpSender *sender =
    [_peerConnection senderWithKind:kRTCMediaStreamTrackKindAudio
                           streamId:kARDMediaStreamId];
    sender.track = track;
    return sender;
}

- (RTCVideoTrack *)createLocalVideoTrack {
    RTCVideoTrack* localVideoTrack = nil;
    // The iOS simulator doesn't provide any sort of camera capture
    // support or emulation (http://goo.gl/rHAnC1) so don't bother
    // trying to open a local stream.
#if !TARGET_IPHONE_SIMULATOR
    if (!_isAudioOnly) {
        RTCMediaConstraints *cameraConstraints =
        [self cameraConstraints];
        RTCAVFoundationVideoSource *source =
        [_factory avFoundationVideoSourceWithConstraints:cameraConstraints];
        localVideoTrack =
        [_factory videoTrackWithSource:source
                               trackId:kARDVideoTrackId];
    }
#endif
    return localVideoTrack;
}

/*
- (RTCMediaStream *)createLocalMediaStream {
  RTCMediaStream *localStream =
      [[RTCMediaStream alloc] initWithFactory:_factory streamId:@"ARDAMS"];
  RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
  if (localVideoTrack) {
    [localStream addVideoTrack:localVideoTrack];
    [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
  }
  RTCAudioTrack *localAudioTrack =
        [[RTCAudioTrack alloc] initWithFactory:_factory
                                       trackId:@"ARDAMSa0"];
  [localStream addAudioTrack:localAudioTrack];
  return localStream;
}

- (RTCVideoTrack *)createLocalVideoTrack {
  RTCVideoTrack* localVideoTrack = nil;
  // The iOS simulator doesn't provide any sort of camera capture
  // support or emulation (http://goo.gl/rHAnC1) so don't bother
  // trying to open a local stream.
  // TODO(tkchin): local video capture for OSX. See
  // https://code.google.com/p/webrtc/issues/detail?id=3417.
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE
  if (!_isAudioOnly) {
    RTCMediaConstraints *mediaConstraints =
        [self defaultMediaStreamConstraints];
    RTCAVFoundationVideoSource *source =
        [[RTCAVFoundationVideoSource alloc] initWithFactory:_factory
                                                constraints:mediaConstraints];
    localVideoTrack =
        [[RTCVideoTrack alloc] initWithFactory:_factory
                                        source:source
                                       trackId:@"ARDAMSv0"];
  }
#endif
  return localVideoTrack;
}*/

#pragma mark - Collider methods

- (void)registerWithColliderIfReady {
  if (!self.hasJoinedRoomServerRoom) {
    return;
  }
  // Open WebSocket connection.
  /*if (!_channel) {
    _channel =
        [[ARDWebSocketChannel alloc] initWithURL:_websocketURL
                                         restURL:_websocketRestURL
                                        delegate:self];
    if (_isLoopback) {
      _loopbackChannel =
          [[ARDLoopbackWebSocketChannel alloc] initWithURL:_websocketURL
                                                   restURL:_websocketRestURL];
    }
  }
  [_channel registerForRoomId:_roomId clientId:_clientId];
  if (_isLoopback) {
    [_loopbackChannel registerForRoomId:_roomId clientId:@"LOOPBACK_CLIENT_ID"];
  }*/
    
    // create socket.io client instance
    _socketIO = [[SocketIO alloc] initWithDelegate:self];
    _socketIO.useSecure = _isSecure;
    _socketIO.returnAllDataFromAck = true;
    // connect to the socket.io server that is running locally at port 3000
    NSArray *aArray = [_host componentsSeparatedByString:@":"];
    [_socketIO connectToHost:aArray[0] onPort:[aArray[1] intValue]];
    
    SocketIOCallback cb = ^(id argsData) {
        //NSDictionary *response = argsData;
        // do something with response
        if([[argsData objectAtIndex:0] isEqualToString:@"success"]) {
            NSDictionary *responseJSON = [argsData objectAtIndex:1];
            if (!responseJSON) {
                return;
            }
            
            self.roomId = responseJSON[@"id"];
            
            //获取iceservers地址
            _iceServers = [[NSMutableArray alloc] init];
            
            for (NSDictionary *servers in responseJSON[@"iceServers"]) {
                if (!servers[@"username"]) { // stun
                    [_iceServers addObject:[self defaultServerUrl:servers[@"url"] andUsername:@"" andCredential:@""]];
                }
                /*else{ // turn
                    [_iceServers addObject:[self defaultServerUrl:servers[@"url"] andUsername:servers[@"username"] andCredential:servers[@"credential"]]];
                }*/
                
            }
            
            NSDictionary *json = @{
                                   @"audio" : [NSNumber numberWithBool:YES],
                                   @"video" : [NSNumber numberWithBool:YES],
                                   @"data" : [NSNumber numberWithBool:YES],
                                   @"state" : @"erizo",
                                   @"minVideoBW" : @0
                                   };
            
            [_socketIO sendEvent:@"publish" withData:json withOption:@{} andAcknowledge:^(id argsData) {
                self.clientId = [argsData objectAtIndex:0];
                
                [self startSignalingIfReady];
            }];
            
            NSArray *streamsArray = responseJSON[@"streams"];
            if (!streamsArray) {
                return;
            }
            for (NSDictionary *streamJSON in streamsArray) {
                NSString *streamId = streamJSON[@"id"];
                NSDictionary *json = @{
                                       @"streamId" : streamId
                                       };
                
                [_socketIO sendEvent:@"subscribe" withData:json withOption:@{} andAcknowledge:^(id argsData) {
                    if([argsData objectAtIndex:0]) {
                        [self startSubscribe:streamId];
                    }
                    
                }];
            }
        }
        
    };
    [_socketIO sendEvent:@"token" withData:_tokenDict andAcknowledge:cb];
}


# pragma mark -
# pragma mark socket.IO-objc delegate methods

- (void) socketIODidConnect:(SocketIO *)socket
{
    NSLog(@"socket.io connected.");
}

- (void) socketIO:(SocketIO *)socket didReceiveEvent:(SocketIOPacket *)packet
{
    NSLog(@"didReceiveEvent()");
    
    if([packet.name isEqualToString:@"signaling_message_erizo"])
    {
        NSDictionary *responseJSON = [packet.args objectAtIndex:0];
        if (!responseJSON) {
            return;
        }
        NSDictionary *messJSON = responseJSON[@"mess"];
        if (!messJSON) {
            return;
        }
        if([messJSON[@"type"] isEqualToString:@"answer"]) {
            RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:messJSON[@"sdp"]];
            // Prefer H264 if available.
            RTCSessionDescription *sdpPreferringH264 =
            [ARDSDPUtils descriptionForDescription:description
                               preferredVideoCodec:@"H264"];
            
            sdpPreferringH264=[ARDSDPUtils descriptionForDescription:sdpPreferringH264
                               startBitrate:500
                               maxBitrate:800
                               minBitrate:100
                               isVideoCodec:TRUE
                               codec:@"H264"];
            
            __weak ARDAppClient *weakSelf = self;
            
            if(responseJSON[@"streamId"]) {
                [_peerConnection setRemoteDescription:sdpPreferringH264
                                completionHandler:^(NSError *error) {
                    ARDAppClient *strongSelf = weakSelf;
                    [strongSelf peerConnection:strongSelf.peerConnection
                             didSetSessionDescriptionWithError:error];
                }];
            }
            else if(responseJSON[@"peerId"]) {
                [_peerConnectionSubDict[responseJSON[@"peerId"]] setRemoteDescription:sdpPreferringH264
                                    completionHandler:^(NSError *error) {
                            ARDAppClient *strongSelf = weakSelf;
                            [strongSelf peerConnection:strongSelf.peerConnectionSubDict[responseJSON[@"peerId"]]
                                 didSetSessionDescriptionWithError:error];
                }];
            }
        }
        else if ([messJSON[@"type"] isEqualToString:@"ready"] && responseJSON[@"streamId"]){
            
            
            NSDictionary *recjson = @{
                                      @"to" : self.clientId
                                      };
            [_socketIO sendEvent:@"startRecorder" withData:recjson andAcknowledge:^(id argsData) {
                self.recordId = [argsData objectAtIndex:0];
                
            }];
        }
        
    }
    else if([packet.name isEqualToString:@"onAddStream"])
    {
        NSDictionary *responseJSON = [packet.args objectAtIndex:0];
        if (!responseJSON) {
            return;
        }
        NSString *streamId = responseJSON[@"id"];
        
        /**********************************
        if([streamId isEqual:self.clientId]) {
            return ;
        }
        *********************************/
        
        NSDictionary *json = @{
                               @"streamId" : streamId
                               //@"slideShowMode":@false
                               };
        
        [_socketIO sendEvent:@"subscribe" withData:json withOption:@{} andAcknowledge:^(id argsData) {
            if([argsData objectAtIndex:0]) {
                [self startSubscribe:streamId];
            }
            
        }];
    }
    
    else if([packet.name isEqualToString:@"onRemoveStream"])
    {
        NSDictionary *responseJSON = [packet.args objectAtIndex:0];
        if (!responseJSON) {
            return;
        }
        NSString *streamId = responseJSON[@"id"];
        
        [_peerConnectionSubDict[streamId] close];
        [_peerConnectionSubDict removeObjectForKey:streamId];
    }
    
    // test acknowledge
    /*SocketIOCallback cb = ^(id argsData) {
        NSDictionary *response = argsData;
        // do something with response
        NSLog(@"ack arrived: %@", response);
        
        // test forced disconnect
        [socketIO disconnectForced];
    };
    [socketIO sendMessage:@"hello back!" withAcknowledge:cb];
    
    // test different event data types
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:@"test1" forKey:@"key1"];
    [dict setObject:@"test2" forKey:@"key2"];
    [socketIO sendEvent:@"welcome" withData:dict];
    
    [socketIO sendEvent:@"welcome" withData:@"testWithString"];
    
    NSArray *arr = [NSArray arrayWithObjects:@"test1", @"test2", nil];
    [socketIO sendEvent:@"welcome" withData:arr];*/
}

- (void) socketIO:(SocketIO *)socket onError:(NSError *)error
{
    if ([error code] == SocketIOUnauthorized) {
        NSLog(@"not authorized");
    } else {
        NSLog(@"onError() %@", error);
    }
}


- (void) socketIODidDisconnect:(SocketIO *)socket disconnectedWithError:(NSError *)error
{
    NSLog(@"socket.io disconnected. did error occur? %@", error);
}

#pragma mark - Defaults

- (RTCMediaConstraints *)defaultMediaAudioConstraints {
    bool shouldUseLevelControl=true;
    NSString *valueLevelControl = shouldUseLevelControl ?
    kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse;
    NSDictionary *mandatoryConstraints = @{ kRTCMediaConstraintsLevelControl : valueLevelControl,
                                            @"googAutoGainControl":kRTCMediaConstraintsValueTrue};
    RTCMediaConstraints *constraints =
    [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatoryConstraints
                                          optionalConstraints:nil];
    return constraints;
}

- (RTCMediaConstraints *)cameraConstraints {
    NSDictionary *mandatoryConstraints = @{
                                           @"minWidth" : @"320",
                                           @"minHeight" : @"180",
                                           @"maxWidth" : @"640",
                                           @"maxHeight" : @"480",
                                           @"minFrameRate" : @"5",
                                           @"maxFrameRate" : @"15"
                                           };
    
    NSDictionary *optionalConstraints = @{
                                           @"maxWidth" : @"640",
                                           @"maxHeight" : @"480",
                                           @"minFrameRate" : @"5",
                                           @"maxFrameRate" : @"20"
                                           };
    
    RTCMediaConstraints *constraints =
    [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                          optionalConstraints:optionalConstraints];
    return constraints;
}

/*
- (RTCMediaConstraints *)defaultMediaStreamConstraints {
    NSDictionary *mandatoryConstraints = @{
                                           @"minWidth" : @"320",
                                           @"minHeight" : @"240",
                                           @"maxWidth" : @"320",
                                           @"maxHeight" : @"240",
                                           @"minFrameRate" : @"5",
                                           @"maxFrameRate" : @"20"
                                           };
    
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:mandatoryConstraints
                   optionalConstraints:nil];
  return constraints;
}*/

- (RTCMediaConstraints *)defaultAnswerConstraints {
  return [self defaultOfferConstraints];
}

- (RTCMediaConstraints *)defaultOfferConstraints {
  NSDictionary *mandatoryConstraints = @{
    @"OfferToReceiveAudio" : @"true",
    @"OfferToReceiveVideo" : @"true"
  };
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:mandatoryConstraints
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
  if (_defaultPeerConnectionConstraints) {
    return _defaultPeerConnectionConstraints;
  }
    
    /*NSDictionary *mandatoryConstraints = @{
                                           @"minWidth" : @"320",
                                           @"minHeight" : @"240",
                                           @"maxWidth" : @"320",
                                           @"maxHeight" : @"240",
                                           @"minFrameRate" : @"5",
                                           @"maxFrameRate" : @"20"
                                           };*/
    
  NSString *value = _isLoopback ? @"false" : @"true";
  NSDictionary *optionalConstraints = @{ @"DtlsSrtpKeyAgreement" : value
                                         /*@"googCpuOveruseDetection": @"false"*/};
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:optionalConstraints];
  return constraints;
}

/*
- (RTCIceServer *)defaultSTUNServer {
  return [[RTCIceServer alloc] initWithURLStrings:@[kARDDefaultSTUNServerUrl]
                                         username:@""
                                       credential:@""];
}*/

- (RTCIceServer *)defaultServerUrl:(NSString *)ServerUrl andUsername:(NSString *)username andCredential:(NSString *)credential{
    
    return [[RTCIceServer alloc] initWithURLStrings:@[ServerUrl]
                                           username:username
                                         credential:credential];
}

#pragma mark - Errors

+ (NSError *)errorForJoinResultType:(ARDJoinResultType)resultType {
  NSError *error = nil;
  switch (resultType) {
    case kARDJoinResultTypeSuccess:
      break;
    case kARDJoinResultTypeUnknown: {
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorUnknown
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Unknown error.",
      }];
      break;
    }
    case kARDJoinResultTypeFull: {
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorRoomFull
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Room is full.",
      }];
      break;
    }
  }
  return error;
}

+ (NSError *)errorForMessageResultType:(ARDMessageResultType)resultType {
  NSError *error = nil;
  switch (resultType) {
    case kARDMessageResultTypeSuccess:
      break;
    case kARDMessageResultTypeUnknown:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorUnknown
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Unknown error.",
      }];
      break;
    case kARDMessageResultTypeInvalidClient:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorInvalidClient
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Invalid client.",
      }];
      break;
    case kARDMessageResultTypeInvalidRoom:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorInvalidRoom
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Invalid room.",
      }];
      break;
  }
  return error;
}

@end
