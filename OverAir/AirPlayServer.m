#import "Constants.h"
#import "AirPlayServer.h"
#import "OAUtil.h"

@implementation AirPlayServer

- (id)init {
    connClass = [HTTPConnection self];
    return self;
}

- (Class)connectionClass {
    return connClass;
}

- (void)setConnectionClass:(Class)value {
    connClass = value;
}


// Converts the TCPServer delegate notification into the HTTPServer delegate method.
- (void)handleNewConnectionFromAddress:(NSData *)addr inputStream:(NSInputStream *)istr outputStream:(NSOutputStream *)ostr {
    HTTPConnection *connection = [[connClass alloc] initWithPeerAddress:addr inputStream:istr outputStream:ostr forServer:self];
    [connection setDelegate:[self delegate]];
    if ([self delegate] && [[self delegate] respondsToSelector:@selector(HTTPServer:didMakeNewConnection:)]) {
        [[self delegate] HTTPServer:self didMakeNewConnection:connection];
    }
}

@end


@implementation HTTPConnection

- (id)init {
    return nil;
}

- (id)initWithPeerAddress:(NSData *)addr inputStream:(NSInputStream *)istr outputStream:(NSOutputStream *)ostr forServer:(AirPlayServer *)serv {
    peerAddress = [addr copy];
    server = serv;
    istream = istr;
    ostream = ostr;
    [istream setDelegate:self];
    [ostream setDelegate:self];
    [istream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:(id)kCFRunLoopCommonModes];
    [ostream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:(id)kCFRunLoopCommonModes];
    [istream open];
    [ostream open];
    isValid = YES;
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (id)delegate {
    return delegate;
}

- (void)setDelegate:(id)value {
    delegate = value;
}



- (NSData *)peerAddress {
    return peerAddress;
}

- (AirPlayServer *)server {
    return server;
}

- (HTTPServerRequest *)nextRequest {
    unsigned long idx, cnt = requests ? [requests count] : 0;
    for (idx = 0; idx < cnt; idx++) {
        id obj = [requests objectAtIndex:idx];
        if ([obj response] == nil) {
            return obj;
        }
    }
    return nil;
}

- (BOOL)isValid {
    return isValid;
}

- (void)invalidate {
    if (isValid) {
        isValid = NO;
        [istream close];
        [ostream close];
        istream = nil;
        ostream = nil;
        ibuffer = nil;
        obuffer = nil;
        requests = nil;
    }
}

// YES return means that a complete request was parsed, and the caller
// should call again as the buffered bytes may have another complete
// request available.
- (BOOL)processIncomingBytes {
    CFHTTPMessageRef working = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);
    CFHTTPMessageAppendBytes(working, [ibuffer bytes], [ibuffer length]);
    
    // This "try and possibly succeed" approach is potentially expensive
    // (lots of bytes being copied around), but the only API available for
    // the server to use, short of doing the parsing itself.
    
    // HTTPConnection does not handle the chunked transfer encoding
    // described in the HTTP spec.  And if there is no Content-Length
    // header, then the request is the remainder of the stream bytes.
    
    if (CFHTTPMessageIsHeaderComplete(working)) {
        NSString *contentLengthValue = (__bridge NSString *)CFHTTPMessageCopyHeaderFieldValue(working, (CFStringRef)@"Content-Length");
        
        unsigned contentLength = contentLengthValue ? [contentLengthValue intValue] : 0;
        NSData *body = (__bridge NSData *)CFHTTPMessageCopyBody(working);
        unsigned long bodyLength = [body length];
        if (contentLength <= bodyLength) {
            NSData *newBody = [NSData dataWithBytes:[body bytes] length:contentLength];
            [ibuffer setLength:0];
            [ibuffer appendBytes:([body bytes] + contentLength) length:(bodyLength - contentLength)];
            CFHTTPMessageSetBody(working, (__bridge CFDataRef)newBody);
        } else {
            CFRelease(working);
            return NO;
        }
    } else {
        return NO;
    }
    
    HTTPServerRequest *request = [[HTTPServerRequest alloc] initWithRequest:working connection:self];
    if (!requests) {
        requests = [[NSMutableArray alloc] init];
    }
    [requests addObject:request];
    if (delegate && [delegate respondsToSelector:@selector(HTTPConnection:didReceiveRequest:)]) {
        [delegate HTTPConnection:self didReceiveRequest:request];
    } else {
        [self performDefaultRequestHandling:request];
    }
    
    CFRelease(working);
    return YES;
}

- (void)processOutgoingBytes {
    
    
    // The HTTP headers, then the body if any, then the response stream get
    // written out, in that order.  The Content-Length: header is assumed to
    // be properly set in the response.  Outgoing responses are processed in
    // the order the requests were received (required by HTTP).
    
    // Write as many bytes as possible, from buffered bytes, response
    // headers and body, and response stream.
    
    if (![ostream hasSpaceAvailable]) {
        return;
    }
    
    unsigned long olen = [obuffer length];
    if (0 < olen) {
        long writ = [ostream write:[obuffer bytes] maxLength:olen];
        // buffer any unwritten bytes for later writing
        if (writ < olen) {
            memmove([obuffer mutableBytes], [obuffer mutableBytes] + writ, olen - writ);
            [obuffer setLength:olen - writ];
            return;
        }
        [obuffer setLength:0];
    }
    
    unsigned long cnt = requests ? [requests count] : 0;
    HTTPServerRequest *req = (0 < cnt) ? [requests objectAtIndex:0] : nil;
    
    CFHTTPMessageRef cfresp = req ? [req response] : NULL;
    if (!cfresp) return;
    
    if (!obuffer) {
        obuffer = [[NSMutableData alloc] init];
    }
    
    if (!firstResponseDone) {
        firstResponseDone = YES;
        NSData *serialized = (__bridge NSData *)CFHTTPMessageCopySerializedMessage(cfresp);
        unsigned long olen = [serialized length];
        if (0 < olen) {
            long writ = [ostream write:[serialized bytes] maxLength:olen];
            if (writ < olen) {
                // buffer any unwritten bytes for later writing
                [obuffer setLength:(olen - writ)];
                memmove([obuffer mutableBytes], [serialized bytes] + writ, olen - writ);
                return;
            }
        }
    }
    
    NSInputStream *respStream = [req responseBodyStream];
    if (respStream) {
        if ([respStream streamStatus] == NSStreamStatusNotOpen) {
            [respStream open];
        }
        // read some bytes from the stream into our local buffer
        [obuffer setLength:16 * 1024];
        long read = [respStream read:[obuffer mutableBytes] maxLength:[obuffer length]];
        [obuffer setLength:read];
    }
    
    if (0 == [obuffer length]) {
        // When we get to this point with an empty buffer, then the
        // processing of the response is done. If the input stream
        // is closed or at EOF, then no more requests are coming in.
        if (delegate && [delegate respondsToSelector:@selector(HTTPConnection:didSendResponse:)]) {
            [delegate HTTPConnection:self didSendResponse:req];
        }
        [requests removeObjectAtIndex:0];
        firstResponseDone = NO;
        if ([istream streamStatus] == NSStreamStatusAtEnd && [requests count] == 0) {
            [self invalidate];
        }
        return;
    }
    
    olen = [obuffer length];
    if (0 < olen) {
        long writ = [ostream write:[obuffer bytes] maxLength:olen];
        // buffer any unwritten bytes for later writing
        if (writ < olen) {
            memmove([obuffer mutableBytes], [obuffer mutableBytes] + writ, olen - writ);
        }
        [obuffer setLength:olen - writ];
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent {
    switch(streamEvent) {
        case NSStreamEventHasBytesAvailable:;
            uint8_t buf[16 * 1024];
            uint8_t *buffer = NULL;
            NSUInteger len = 0;
            if (![istream getBuffer:&buffer length:&len]) {
                long amount = [istream read:buf maxLength:sizeof(buf)];
                buffer = buf;
                len = amount;
            }
            if (0 < len) {
                if (!ibuffer) {
                    ibuffer = [[NSMutableData alloc] init];
                }
                [ibuffer appendBytes:buffer length:len];
            }
            do {} while ([self processIncomingBytes]);
            break;
        case NSStreamEventHasSpaceAvailable:;
            [self processOutgoingBytes];
            break;
        case NSStreamEventEndEncountered:;
            [self processIncomingBytes];
            if (stream == ostream) {
                // When the output stream is closed, no more writing will succeed and
                // will abandon the processing of any pending requests and further
                // incoming bytes.
                [self invalidate];
            }
            break;
        case NSStreamEventErrorOccurred:;
            NSLog(@"HTTPServer stream error: %@", [stream streamError]);
            break;
        default:
            break;
    }
}


- (void)performDefaultRequestHandling:(HTTPServerRequest *)mess {
    
    CFHTTPMessageRef request = [mess request];
    NSString *method = (__bridge id)CFHTTPMessageCopyRequestMethod(request);
    NSDate *myDate = [NSDate date];
    NSString *date = [myDate descriptionWithCalendarFormat:@"%a %d %b %Y %H:%M:%S GMT" timeZone:nil locale:nil];
    NSURL *uri = (__bridge NSURL *)CFHTTPMessageCopyRequestURL(request);
    NSLog(@"uri : %@",[uri absoluteURL]);
    
    if ([method isEqual:@"GET"]) {
        NSURL *uri = (__bridge NSURL *)CFHTTPMessageCopyRequestURL(request);
        NSLog(@"uri : %@",[uri absoluteURL]);
        
        if ([[uri relativeString] hasPrefix:@"/server-info"])
        {
            
            NSData *data = [[NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
                             <plist version=\"1.0\">\n\
                             <dict>\n\
                             \t<key>deviceid</key>\n\
                             \t<string>%@</string>\n\
                             \t<key>features</key>\n\
                             \t<integer>119</integer>\n\
                             \t<key>model</key>\n\
                             \t<string>AppleTV2,1</string>\n\
                             \t<key>protovers</key>\n\
                             \t<string>1.0</string>\n\
                             \t<key>srcvers</key>\n\
                             \t<string>101.28</string>\n\
                             </dict>\n\
                             </plist>\n", [OAUtil getMacAddressForInterface:UseNetworkInterface]] dataUsingEncoding: NSASCIIStringEncoding];
            
            
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
            
            // Datum meesturen
            
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (__bridge CFStringRef)[NSString stringWithFormat:@"%@",date]);
            
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (__bridge CFStringRef)[NSString stringWithFormat:@"application/x-apple-plist+xml"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Length", (__bridge CFStringRef)[NSString stringWithFormat:@"%lu", (unsigned long)[data length]]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"X-Apple-Session-Id", (__bridge CFStringRef)[NSString stringWithFormat:@"00000000-0000-0000-0000-000000000000"]);
            
            
            CFHTTPMessageSetBody(response, (__bridge CFDataRef)data);
            [mess setResponse:response];
            CFRelease(response);
            
            return;
            
        }
        if ([[uri relativeString] hasPrefix:@"/slideshow-features"])
        {
            /*<?xml version="1.0" encoding="UTF-8"?>
             <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
             <plist version="1.0">
             <dict>
             <key>themes</key>
             <array>
             <dict>
             <key>key</key>
             <string>Dissolve</string>
             <key>name</key>
             <string>Dissolve</string>
             </dict>
             <dict>
             <key>key</key>
             <string>Cube</string>
             <key>name</key>
             <string>Cube</string>
             </dict>
             <dict>
             <key>key</key>
             <string>Ripple</string>
             <key>name</key>
             <string>Ripple</string>
             </dict>
             <dict>
             <key>key</key>
             <string>WipeAcross</string>
             <key>name</key>
             <string>Wipe Across</string>
             </dict>
             <dict>
             <key>key</key>
             <string>WipeDown</string>
             <key>name</key>
             <string>Wipe Down</string>
             </dict>
             </array>
             </dict>
             </plist>
             */
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // Method Not Allowed
            [mess setResponse:response];
            CFRelease(response);
            
            
        }
        
        else if ([[uri relativeString] hasPrefix:@"/playback-info"])
        {
            if (delegate && [delegate respondsToSelector:@selector(airPlayServerDidReceivePositionRequest:)]) {
                _playPosition =  [delegate airPlayServerDidReceivePositionRequest:self.server];
            }
            
            if (delegate && [delegate respondsToSelector:@selector(airPlayServerDidReceiveRateRequest:)]) {
                _playRate =  [delegate airPlayServerDidReceiveRateRequest:self.server];
            }
            
            NSString *resp = [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n \
                              <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n \
                              <plist version=\"1.0\">\n \
                              <dict>\n \
                              \t<key>duration</key>\n \
                              \t<real>0.0</real>\n \
                              \t<key>position</key>\n \
                              \t<real>0.0</real>\n \
                              </dict>\n \
                              </plist>"];
            
            NSData *data = [resp dataUsingEncoding: NSASCIIStringEncoding];
            
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (__bridge CFStringRef)[NSString stringWithFormat:@"%@",date]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (__bridge CFStringRef)[NSString stringWithFormat:@"text/x-apple-plist+xml"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Length", (__bridge CFStringRef)[NSString stringWithFormat:@"%lu", (unsigned long)[data length]]);
            CFHTTPMessageSetBody(response, (__bridge CFDataRef)data);
            
            [mess setResponse:response];
            CFRelease(response);
            
            return;
        }
        
    }
    else if ([method isEqual:@"POST"])
    {
        NSURL *uri = (__bridge NSURL *)CFHTTPMessageCopyRequestURL(request);
        NSLog(@"(POST) URI : %@",uri);
        
        if ([[uri relativeString] hasPrefix:@"/reverse"])
        {
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 101, NULL, kCFHTTPVersion1_1); // Switching Protocols
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (__bridge CFStringRef)[NSString stringWithFormat:@"%@",date]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Upgrade", (__bridge CFStringRef)[NSString stringWithFormat:@"PTTH/1.0"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Connection", (__bridge CFStringRef)[NSString stringWithFormat:@"Upgrade"]);
            //			CFHTTPMessageSetBody(response, (CFDataRef)data);
            [mess setResponse:response];
            CFRelease(response);
            
            return;
        }
        else if ([[uri relativeString] hasPrefix:@"/play"])
        {
            _playPosition = 0;
            NSData *Body = (__bridge NSData *)CFHTTPMessageCopyBody(request);
            NSString *bodyString = [[NSString alloc] initWithData:Body encoding:NSASCIIStringEncoding];
            
            NSLog(@"(POST-Play) Body : %@",bodyString);
            
            if ([bodyString hasPrefix:@"Content-Location: "])
            {
                NSString *url1 = [bodyString substringFromIndex:18];
                
                NSArray *components=[url1 componentsSeparatedByString:@"\nStart-Position: "];
                
                NSLog(@"URL : %@",[components objectAtIndex:0]);
                NSLog(@"Start : %@",[components objectAtIndex:1]);
                
                NSNumberFormatter * f = [[NSNumberFormatter alloc] init];
                [f setNumberStyle:NSNumberFormatterDecimalStyle];
                NSNumber * startposition = [f numberFromString:[components objectAtIndex:1]];
                
                
                if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceiveRequestForVideoURL:startPosition:)]) {
                    NSString* const videoUrl = [[components objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    
                    [delegate airPlayServer:self.server
               didReceiveRequestForVideoURL:videoUrl
                              startPosition:[startposition floatValue]];
                }
                
                if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceivePauseRequest:)]) {
                    [delegate airPlayServer:self.server didReceivePauseRequest:YES];
                }
                
            }
            else {
                NSString *error;
                NSPropertyListFormat format;
                NSDictionary* plist = [NSPropertyListSerialization propertyListFromData:Body mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&error];
                if (!plist) {
                    NSLog(@"Error: %@",error);
                }
                else {
                    if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceiveRequestForVideoURL:startPosition:)]) {
                        NSString* const videoUrl = [[plist objectForKey:@"Content-Location"] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                        
                        [delegate airPlayServer:self.server
                   didReceiveRequestForVideoURL:videoUrl
                                  startPosition:[[plist objectForKey:@"Start-Position"] floatValue]];
                    }
                    
                }
                
                
            }
            
            
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 101, NULL, kCFHTTPVersion1_1); // Switching Protocols
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (__bridge CFStringRef)[NSString stringWithFormat:@"text/x-apple-plist+xml"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (__bridge CFStringRef)date);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Upgrade", (__bridge CFStringRef)[NSString stringWithFormat:@"PTTH/1.0"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Connection", (__bridge CFStringRef)[NSString stringWithFormat:@"Upgrade"]);
            [mess setResponse:response];
            CFRelease(response);
            
            return;
            
        }
        else if ([[uri relativeString] hasPrefix:@"/stop"])
        {
            if (delegate && [delegate respondsToSelector:@selector(airPlayServerDidReceiveStopRequest:)]) {
                [delegate airPlayServerDidReceiveStopRequest:self.server];
            }   
            
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
            [mess setResponse:response];
            CFRelease(response);
            
            return;
            
        }
        else if ([[uri relativeString] hasPrefix:@"/rate?value="])
        {
            if ([[uri relativeString] hasPrefix:@"/rate?value=1"])
            {
                if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceivePauseRequest:)]) {
                    [delegate airPlayServer:self.server didReceivePauseRequest:NO];
                }
            }
            else {
                if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceivePauseRequest:)]) {
                    [delegate airPlayServer:self.server didReceivePauseRequest:YES];
                }
            }
            
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 101, NULL, kCFHTTPVersion1_1); // Switching Protocols
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (__bridge CFStringRef)[NSString stringWithFormat:@"text/x-apple-plist+xml"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (__bridge CFStringRef)date);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Upgrade", (__bridge CFStringRef)[NSString stringWithFormat:@"PTTH/1.0"]);
            CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Connection", (__bridge CFStringRef)[NSString stringWithFormat:@"Upgrade"]);
            [mess setResponse:response];
            CFRelease(response);
            return;
            
        }
        else if ([[uri relativeString] hasPrefix:@"/scrub?position="])
        {
            NSString *seconds = [[uri absoluteString] substringFromIndex:16];
            
            NSNumberFormatter * f = [[NSNumberFormatter alloc] init];
            [f setNumberStyle:NSNumberFormatterDecimalStyle];
            NSNumber * position = [f numberFromString:seconds];
            
            _playPosition = [position intValue]/1000000;
            
            if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceiveScrubRequest:)]) {
                [delegate airPlayServer:self.server didReceiveScrubRequest:[position floatValue]];
            }
            
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
            [mess setResponse:response];
            CFRelease(response);
            return;
        }
        
    } // Einde POST
    else if ([method isEqual:@"PUT"])
    {
        NSURL *uri = (__bridge NSURL *)CFHTTPMessageCopyRequestURL(request);
        NSLog(@"(PUT) URI : %@",uri);
        
        if ([[uri relativeString] hasPrefix:@"/photo"])
        {
            
            NSData *Body = (__bridge NSData *)CFHTTPMessageCopyBody(request);
            
            if (delegate && [delegate respondsToSelector:@selector(airPlayServer:didReceivePhotoRequest:)]) {
                [delegate airPlayServer:self.server didReceivePhotoRequest:Body];
            }
            
        }
        else if ([[uri relativeString] hasPrefix:@"/slideshows"])
        {
//            NSData *Body = (__bridge NSData *)CFHTTPMessageCopyBody(request);
//            NSString *bodyString = [[NSString alloc] initWithData:Body encoding:NSASCIIStringEncoding];
//            NSString *Response = (__bridge NSDictionary *)CFHTTPMessageCopyAllHeaderFields(request);
//            NSLog(@"Headers : %@",Response);
//            NSLog(@"Content : %@",bodyString);
            
            NSLog(@"Slideshows not yet supported, doing nothing...");
        }
    }
    
    CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1); // OK
    //    CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", (CFStringRef)@"Mon, 16 June 2014 21:32:00 GMT");
    //    CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Length", (CFStringRef)@"0");
    [mess setResponse:response];
    CFRelease(response);
}

@end


@implementation HTTPServerRequest

- (id)init {
    return nil;
}

- (id)initWithRequest:(CFHTTPMessageRef)req connection:(HTTPConnection *)conn {
    connection = conn;
    request = (CFHTTPMessageRef)CFRetain(req);
    return self;
}

- (void)dealloc {
    if (request) CFRelease(request);
    if (response) CFRelease(response);
}

- (HTTPConnection *)connection {
    return connection;
}

- (CFHTTPMessageRef)request {
    return request;
}

- (CFHTTPMessageRef)response {
    return response;
}

- (void)setResponse:(CFHTTPMessageRef)value {
    if (value != response) {
        if (response) CFRelease(response);
        response = (CFHTTPMessageRef)CFRetain(value);
        if (response) {
            // check to see if the response can now be sent out
            [connection processOutgoingBytes];
        }
    }
}

- (NSInputStream *)responseBodyStream {
    return responseStream;
}

- (void)setResponseBodyStream:(NSInputStream *)value {
    if (value != responseStream) {
        responseStream = value;
    }
}

@end
