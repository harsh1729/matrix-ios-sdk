/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "RoomMessage.h"

#import "MatrixHandler.h"
#import "AppSettings.h"

static NSAttributedString *messageSeparator = nil;

@interface RoomMessage() {
    // Array of RoomMessageComponent
    NSMutableArray *messageComponents;
    // Current text message reset at each component change (see attributedTextMessage property)
    NSMutableAttributedString *currentAttributedTextMsg;
}

+ (NSAttributedString *)messageSeparator;

@end

@implementation RoomMessage

- (id)initWithEvent:(MXEvent*)event andRoomState:(MXRoomState*)roomState {
    if (self = [super init]) {
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        
        _senderId = event.userId;
        _senderName = [mxHandler senderDisplayNameForEvent:event withRoomState:roomState];
        _senderAvatarUrl = [mxHandler senderAvatarUrlForEvent:event withRoomState:roomState];
        _maxTextViewWidth = ROOM_MESSAGE_DEFAULT_MAX_TEXTVIEW_WIDTH;
        _contentSize = CGSizeZero;
        currentAttributedTextMsg = nil;
        
        // Set message type (consider text by default), and check attachment if any
        _messageType = RoomMessageTypeText;
        if ([mxHandler isSupportedAttachment:event]) {
            // Note: event.eventType is equal here to MXEventTypeRoomMessage
            NSString *msgtype =  event.content[@"msgtype"];
            if ([msgtype isEqualToString:kMXMessageTypeImage]) {
                _messageType = RoomMessageTypeImage;
                
                _attachmentURL = event.content[@"url"];
                _attachmentInfo = event.content[@"info"];
                _thumbnailURL = event.content[@"thumbnail_url"];
                _thumbnailInfo = event.content[@"thumbnail_info"];
            } else if ([msgtype isEqualToString:kMXMessageTypeAudio]) {
                // Not supported yet
                //_messageType = RoomMessageTypeAudio;
            } else if ([msgtype isEqualToString:kMXMessageTypeVideo]) {
                _messageType = RoomMessageTypeVideo;
                _attachmentURL = event.content[@"url"];
                _attachmentInfo = event.content[@"info"];
                if (_attachmentInfo) {
                    _thumbnailURL = _attachmentInfo[@"thumbnail_url"];
                    _thumbnailInfo = _attachmentInfo[@"thumbnail_info"];
                }
            } else if ([msgtype isEqualToString:kMXMessageTypeLocation]) {
                // Not supported yet
                // _messageType = RoomMessageTypeLocation;
            }
        }
        
        // Set first component of the current message
        RoomMessageComponent *msgComponent = [[RoomMessageComponent alloc] initWithEvent:event andRoomState:roomState];
        if (msgComponent) {
            messageComponents = [NSMutableArray array];
            [messageComponents addObject:msgComponent];
            // Store the actual height of the text by removing textview margin from content height
            msgComponent.height = self.contentSize.height - (2 * ROOM_MESSAGE_TEXTVIEW_MARGIN);
        } else {
            // Ignore this event
            self = nil;
        }
    }
    return self;
}

- (void)dealloc {
    messageComponents = nil;
}

- (BOOL)addEvent:(MXEvent *)event withRoomState:(MXRoomState*)roomState {
    // We group together text messages from the same user
    if ([event.userId isEqualToString:_senderId] && (_messageType == RoomMessageTypeText)) {
        // Attachments (image, video ...) cannot be added here
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        if ([mxHandler isSupportedAttachment:event]) {
            return NO;
        }
        
        // Check sender information
        NSString *eventSenderName = [mxHandler senderDisplayNameForEvent:event withRoomState:roomState];
        NSString *eventSenderAvatar = [mxHandler senderAvatarUrlForEvent:event withRoomState:roomState];
        if ((_senderName || eventSenderName) &&
            ([_senderName isEqualToString:eventSenderName] == NO)) {
            return NO;
        }
        if ((_senderAvatarUrl || eventSenderAvatar) &&
            ([_senderAvatarUrl isEqualToString:eventSenderAvatar] == NO)) {
            return NO;
        }
        
        // Create new message component
        RoomMessageComponent *addedComponent = [[RoomMessageComponent alloc] initWithEvent:event andRoomState:roomState];
        if (addedComponent) {
            [messageComponents addObject:addedComponent];
            
            // Sort components according to their date
            [messageComponents sortUsingComparator:^NSComparisonResult(RoomMessageComponent *obj1, RoomMessageComponent *obj2) {
                if (obj1.date) {
                    if (obj2.date) {
                        return [obj1.date compare:obj2.date];
                    } else {
                        return NSOrderedAscending;
                    }
                } else if (obj2.date) {
                    return NSOrderedDescending;
                }
                return NSOrderedSame;
            }];
            
            // Force text message refresh after sorting
            [self refreshMessageComponentsHeight];
        }
        // else the event is ignored, we consider it as handled
        return YES;
    }
    return NO;
}

- (BOOL)removeEvent:(NSString *)eventId {
    if (_messageType == RoomMessageTypeText) {
        NSUInteger index = messageComponents.count;
        while (index--) {
            RoomMessageComponent* msgComponent = [messageComponents objectAtIndex:index];
            if ([msgComponent.eventId isEqualToString:eventId]) {
                [messageComponents removeObjectAtIndex:index];
                // Force text message refresh
                [self refreshMessageComponentsHeight];
                return YES;
            }
        }
        // here the provided eventId has not been found
    }
    return NO;
}

- (BOOL)containsEventId:(NSString *)eventId {
    for (RoomMessageComponent* msgComponent in messageComponents) {
        if ([msgComponent.eventId isEqualToString:eventId]) {
            return YES;
        }
    }
    return NO;
}

- (void)refreshMessageComponentsHeight {
    NSMutableArray *components = messageComponents;
    messageComponents = [NSMutableArray arrayWithCapacity:components.count];
    self.attributedTextMessage = nil;
    for (RoomMessageComponent *msgComponent in components) {
        CGFloat previousTextViewHeight = self.contentSize.height ? self.contentSize.height : (2 * ROOM_MESSAGE_TEXTVIEW_MARGIN);
        [messageComponents addObject:msgComponent];
        // Force text message refresh
        self.attributedTextMessage = nil;
        msgComponent.height = self.contentSize.height - previousTextViewHeight;
    }
}

#pragma mark -

- (void)setMaxTextViewWidth:(CGFloat)maxTextViewWidth {
    if (_messageType == RoomMessageTypeText) {
        // Check change
        if (_maxTextViewWidth != maxTextViewWidth) {
            _maxTextViewWidth = maxTextViewWidth;
            // Refresh height for all message components
            [self refreshMessageComponentsHeight];
        }
    }
}

- (CGSize)contentSize {
    if (CGSizeEqualToSize(_contentSize, CGSizeZero)) {
        if (_messageType == RoomMessageTypeText) {
            if (self.attributedTextMessage.length) {
                // Use a TextView template to compute cell height
                UITextView *dummyTextView = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, _maxTextViewWidth, MAXFLOAT)];
                dummyTextView.attributedText = self.attributedTextMessage;
                _contentSize = [dummyTextView sizeThatFits:dummyTextView.frame.size];
            }
        } else if (_messageType == RoomMessageTypeImage || _messageType == RoomMessageTypeVideo) {
            CGFloat width, height;
            width = height = 40;
            if (_thumbnailInfo) {
                width = [_thumbnailInfo[@"w"] integerValue];
                height = [_thumbnailInfo[@"h"] integerValue];
                if (width > ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH || height > ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH) {
                    if (width > height) {
                        height = (height * ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH) / width;
                        height = floorf(height / 2) * 2;
                        width = ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH;
                    } else {
                        width = (width * ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH) / height;
                        width = floorf(width / 2) * 2;
                        height = ROOM_MESSAGE_MAX_ATTACHMENTVIEW_WIDTH;
                    }
                }
            }
            _contentSize = CGSizeMake(width, height);
        } else {
            _contentSize = CGSizeMake(40, 40);
        }
    }
    return _contentSize;
}

- (NSArray*)components {
    return [messageComponents copy];
}

- (void)setAttributedTextMessage:(NSAttributedString *)inAttributedTextMessage {
    if (!inAttributedTextMessage.length) {
        currentAttributedTextMsg = nil;
    } else {
        currentAttributedTextMsg = [[NSMutableAttributedString alloc] initWithAttributedString:inAttributedTextMessage];
    }
    // Reset content size
    _contentSize = CGSizeZero;
}

- (NSAttributedString*)attributedTextMessage {
    if (!currentAttributedTextMsg && messageComponents.count) {
        // Create attributed string
        for (RoomMessageComponent* msgComponent in messageComponents) {
            NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:msgComponent.textMessage attributes:[msgComponent stringAttributes]];
            if (!currentAttributedTextMsg) {
                currentAttributedTextMsg = [[NSMutableAttributedString alloc] initWithAttributedString:attributedString];
            } else {
                // Append attributed text
                [currentAttributedTextMsg appendAttributedString:[RoomMessage messageSeparator]];
                [currentAttributedTextMsg appendAttributedString:attributedString];
            }
        }
    }
    return currentAttributedTextMsg;
}

- (BOOL)startsWithSenderName {
    if (_messageType == RoomMessageTypeText) {
        if (messageComponents.count) {
            RoomMessageComponent *msgComponent = [messageComponents firstObject];
            return msgComponent.startsWithSenderName;
        }
    }
    return NO;
}

- (BOOL)isUploadInProgress {
    if (_messageType != RoomMessageTypeText) {
        if (messageComponents.count) {
            RoomMessageComponent *msgComponent = [messageComponents firstObject];
            return (msgComponent.style == RoomMessageComponentStyleInProgress);
        }
    }
    return NO;
}

#pragma mark -

+ (NSAttributedString *)messageSeparator {
    @synchronized(self) {
        if(messageSeparator == nil) {
            messageSeparator = [[NSAttributedString alloc] initWithString:@"\r\n\r\n" attributes:@{NSForegroundColorAttributeName : [UIColor blackColor],
                                                                                                    NSFontAttributeName: [UIFont systemFontOfSize:4]}];
        }
    }
    return messageSeparator;
}

@end