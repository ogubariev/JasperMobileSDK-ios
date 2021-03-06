/*
 * Copyright © 2014 - 2017. TIBCO Software Inc. All Rights Reserved. Confidential & Proprietary.
 */


#import "JSRESTBase.h"
#import "JSObjectMappingsProtocol.h"
#import "JSErrorDescriptor.h"
#import "JSRESTBase+JSRESTSession.h"
#import "JSErrorBuilder.h"
#import "AFNetworkActivityIndicatorManager.h"

#import "JSPAProfile.h"

#import "EKSerializer.h"
#import "EKMapper.h"

// Access key and value for content-type / charset
NSString * const kJSRequestContentType = @"Content-Type";
NSString * const kJSRequestResponceType = @"Accept";

NSString * const kJSSavedSessionServerProfileKey    = @"JSSavedSessionServerProfileKey";

// Helper template message indicates that request was finished successfully
NSString * const _requestFinishedTemplateMessage = @"Request finished: %@\nResponse: %@";


// Inner JSCallback class contains JSRequest and NSURLSessionTask instances.
// JSRequest class uses for setting additional parameters to JSOperationResult
// instance (i.e. downloadDestinationPath for files) which we want to associate
// with returned response (but it cannot be done in any other way).
@interface JSCallBack : NSObject

@property (nonatomic, retain) JSRequest *request;
@property (nonatomic, retain) NSURLSessionTask *dataTask;

- (id)initWithDataTask:(NSURLSessionTask *)restKitOpdataTaskeration request:(JSRequest *)request;

@end

@implementation JSCallBack
- (id)initWithDataTask:(NSURLSessionTask *)dataTask request:(JSRequest *)request {
    if (self = [super init]) {
        self.request = request;
        self.dataTask = dataTask;
    }
    return self;
}

@end


@interface JSRESTBase()

@property (nonatomic, strong, readwrite, nonnull) JSProfile *serverProfile;

// List of JSCallBack instances
@property (nonatomic, strong) NSMutableArray <JSCallBack *> *requestCallBacks;

@end

@implementation JSRESTBase
@synthesize serverProfile = _serverProfile;
@synthesize requestCallBacks = _requestCallBacks;

#pragma mark -
#pragma mark Initialization

+ (void)initialize {
    [AFNetworkActivityIndicatorManager sharedManager].enabled = YES;
    [AFNetworkActivityIndicatorManager sharedManager].activationDelay = 0;
}

- (nonnull instancetype) initWithServerProfile:(nonnull JSProfile *)serverProfile{
    self = [super initWithBaseURL:[NSURL URLWithString:serverProfile.serverUrl]];
    if (self) {
        // Delete cookies for current server profile. If don't do this old credentials will be used
        // instead new one
        [self deleteCookies];

        self.serverProfile = serverProfile;

        self.completionQueue = dispatch_get_global_queue(0, 0);
        
        self.requestSerializer = [AFJSONRequestSerializer serializer];
        [self.requestSerializer setValue:[JSUtils usedMimeType] forHTTPHeaderField:kJSRequestResponceType];

        self.responseSerializer = [AFHTTPResponseSerializer serializer];
        self.responseSerializer.acceptableStatusCodes = nil;

        [self configureRequestRedirectionHandling];
        [self configureHTTPSAuthenticationChallengeHandling];
    }
    return self;
}

- (void) configureRequestRedirectionHandling {
    __weak typeof(self) weakSelf = self;
    [self setTaskWillPerformHTTPRedirectionBlock:^NSURLRequest * _Nonnull(NSURLSession * _Nonnull session, NSURLSessionTask * _Nonnull task, NSURLResponse * _Nonnull response, NSURLRequest * _Nonnull request) {
        if (response) {
            __strong typeof(self) strongSelf = weakSelf;
            if (strongSelf) {
                JSRequest *jsRequest = [strongSelf callBackForDataTask:task].request;
                if (jsRequest.redirectAllowed) {
                    // we don't use the new request built for us, except for the URL
                    NSURL *newURL = [request URL];
                    // We rely on that here!
                    NSMutableURLRequest *newRequest = [request mutableCopy];
                    [newRequest setURL: newURL];
                    return newRequest;
                }
            }
            return nil;
        } else {
            return request;
        }
    }];
}

- (void) configureHTTPSAuthenticationChallengeHandling
{
    __weak typeof(self) weakSelf = self;
    [self setSessionDidReceiveAuthenticationChallengeBlock:^NSURLSessionAuthChallengeDisposition(NSURLSession * _Nonnull session, NSURLAuthenticationChallenge * _Nonnull challenge, NSURLCredential *__autoreleasing  _Nullable * _Nullable credential) {
        
        __strong typeof(self) strongSelf = weakSelf;
        NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([strongSelf.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                NSURLCredential *localCredential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                if (localCredential) {
                    disposition = NSURLSessionAuthChallengeUseCredential;
                }
            }
        }
        return (disposition);
    }];
}

- (NSMutableArray<JSCallBack *> *)requestCallBacks {
    if (!_requestCallBacks) {
        _requestCallBacks = [NSMutableArray new];
    }
    return _requestCallBacks;
}

#pragma mark -
#pragma mark Public methods

- (void)sendRequest:(nonnull JSRequest *)jsRequest {
    // Merge parameters with httpBody
    id parameters = [NSMutableDictionary dictionaryWithDictionary:jsRequest.params];
    if (jsRequest.body) {
        Class objectClass;
        EKObjectMapping *objectMapping;
        id serializedObject;

        if ([jsRequest.body isKindOfClass:[NSArray class]]) {
            objectClass = [[jsRequest.body lastObject] class];
            objectMapping = [objectClass objectMappingForServerProfile:self.serverProfile];
            serializedObject = [EKSerializer serializeCollection:jsRequest.body withMapping:objectMapping];
        } else {
            objectClass = [jsRequest.body class];
            objectMapping = [objectClass objectMappingForServerProfile:self.serverProfile];
            serializedObject = [EKSerializer serializeObject:jsRequest.body withMapping:objectMapping];
        }

        if (serializedObject) {
            if ([serializedObject isKindOfClass:[NSArray class]]) {
                parameters = serializedObject;
            } else {
                if ([objectClass respondsToSelector:@selector(requestObjectKeyPath)]) {
                    [parameters setObject:serializedObject forKey:[objectClass requestObjectKeyPath]];
                } else {
                    [parameters addEntriesFromDictionary:serializedObject];
                }
            }
        }
    }

    NSError *serializationError = nil;

    NSMutableURLRequest *request;
    switch(jsRequest.serializationType) {
        case JSRequestSerializationType_UrlEncoded: {
            request = [[AFHTTPRequestSerializer serializer] requestWithMethod:[JSRequest httpMethodStringRepresentation:jsRequest.method]
                                                                    URLString:[[NSURL URLWithString:jsRequest.fullURI relativeToURL:self.baseURL] absoluteString]
                                                                   parameters:parameters
                                                                        error:&serializationError];
            break;
        }
        case JSRequestSerializationType_JSON: {
            request = [self.requestSerializer requestWithMethod:[JSRequest httpMethodStringRepresentation:jsRequest.method]
                                                      URLString:[[NSURL URLWithString:jsRequest.fullURI relativeToURL:self.baseURL] absoluteString]
                                                     parameters:parameters
                                                          error:&serializationError];
            break;
        }
    }

    // Merge HTTP headers
    for (NSString *headerKey in [jsRequest.additionalHeaders allKeys]) {
        [request setValue:jsRequest.additionalHeaders[headerKey] forHTTPHeaderField:headerKey];
    }
    
#ifndef __RELEASE__
    if (request.HTTPBody) {
        NSLog(@"BODY: %@", [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding]);
    }
#endif

    if (serializationError) {
        [self sendCallBackForRequest:jsRequest withOperationResult:[self operationResultForSerializationError:serializationError]];
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *dataTask = [self dataTaskWithRequest:request
                                                uploadProgress:nil
                                              downloadProgress:nil
                                             completionHandler:^(NSURLResponse * __unused response, id responseObject, NSError *error) {
                                                 __strong typeof(self) strongSelf = weakSelf;
                                                 if (strongSelf) {
                                                     JSOperationResult *operationResult = [strongSelf operationResultForRequest:jsRequest
                                                                                                                   withResponce:(NSHTTPURLResponse *)response
                                                                                                                 responseObject:responseObject
                                                                                                                          error:error];
                                                     
                                                     [strongSelf sendCallBackForRequest:jsRequest withOperationResult:operationResult];
                                                 }
                                             }];
    [self.requestCallBacks addObject:[[JSCallBack alloc] initWithDataTask:dataTask
                                                                  request:jsRequest]];
    [dataTask resume];
}

- (nullable JSServerInfo *)serverInfo {
    return self.serverProfile.serverInfo;
}

- (void)cancelAllRequests {
    while (self.requestCallBacks.count) {
        JSCallBack *callback = [self.requestCallBacks firstObject];
        @synchronized (callback) {
            callback.request.completionBlock = nil;
            [callback.dataTask cancel];
            [self.requestCallBacks removeObject:callback];
        }
    }
}

- (void)deleteCookies {
    NSURL *serverURL = [NSURL URLWithString:self.serverProfile.serverUrl];
    if (serverURL) {
        NSArray *hostCookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:serverURL];
        for (NSHTTPCookie *cookie in hostCookies) {
            [[NSHTTPCookieStorage sharedHTTPCookieStorage] deleteCookie:cookie];
        }
    }
    [self updateCookiesWithCookies:nil];
}

- (void)updateCookiesWithCookies:(NSArray <NSHTTPCookie *>* __nullable)cookies
{
    BOOL isCookiesChanged = (_cookies != cookies) && cookies.count > 0;
    _cookies = cookies;
    if (isCookiesChanged) {
        [[NSNotificationCenter defaultCenter] postNotificationName:JSRestClientDidChangeCookies
                                                            object:self];
    }
}

#pragma mark - NSSecureCoding
+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
    [aCoder encodeObject:self.serverProfile forKey:kJSSavedSessionServerProfileKey];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    JSProfile *serverProfile = [aDecoder decodeObjectForKey:kJSSavedSessionServerProfileKey];
    if (serverProfile) {
        self = [super initWithCoder:aDecoder];
        if (self) {
            // FIX: Now we use AFHTTPResponseSerializer instead AFJSONResponseSerializer
            if ([self.responseSerializer isKindOfClass:[AFJSONResponseSerializer class]]) {
                AFHTTPResponseSerializer *responseSerializer = [AFHTTPResponseSerializer serializer];
                responseSerializer.acceptableStatusCodes = self.responseSerializer.acceptableStatusCodes;
                self.responseSerializer = responseSerializer;
            }
            
            self.serverProfile = serverProfile;

            [self configureRequestRedirectionHandling];
        }
        return self;
    }
    return nil;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    JSRESTBase *newRestClient = [super copyWithZone:zone];
    newRestClient.serverProfile = [self.serverProfile copyWithZone:zone];
    [newRestClient configureRequestRedirectionHandling];
    
    // FIX: AFHTTPResponseSerializer implements NSCopying protocol incorrerrectly
    newRestClient.responseSerializer.acceptableStatusCodes = self.responseSerializer.acceptableStatusCodes;
    newRestClient.responseSerializer.acceptableContentTypes = self.responseSerializer.acceptableContentTypes;

    return newRestClient;
}

#pragma mark -
#pragma mark Private methods

// Initializes result with helping properties: http status code,
// returned header fields and MIMEType
- (JSOperationResult *)operationResultForRequest:(JSRequest *)request withResponce:(NSHTTPURLResponse *)response responseObject:(id)responseObject error:(NSError *)error{
    JSOperationResult *result = [[JSOperationResult alloc] initWithStatusCode:response.statusCode
                                                              allHeaderFields:response.allHeaderFields
                                                                     MIMEType:response.MIMEType];

    result.request = request;

    if ([self isAuthenticationRequest:result.request]) {
        BOOL isTokenFetchedSuccessful = NO;
        switch (response.statusCode) {
            case 401: // Unauthorized
            case 403: { // Forbidden
                isTokenFetchedSuccessful = NO;
                break;
            }
            case 302: { // redirect
                NSString *redirectURL = [response.allHeaderFields objectForKey:@"Location"];
                NSString *redirectUrlRegex;
                if ([self.serverProfile isKindOfClass:[JSPAProfile class]]) {
                    redirectUrlRegex = [NSString stringWithFormat:@"(.*?)/login.html(.*?)"];
                } else {
                    redirectUrlRegex = [NSString stringWithFormat:@"(.*?)/login.html(;?)((jsessionid=.+)?)\\?error=1"];
                }
                NSPredicate *redirectUrlValidator = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", redirectUrlRegex];
                isTokenFetchedSuccessful = ![redirectUrlValidator evaluateWithObject:redirectURL];
                break;
            }
            case 200: {
                if(responseObject && ![responseObject isEqualToData:[NSData dataWithBytes:" " length:1]]) {
                    if ([response.MIMEType isEqualToString:@"text/html"]) {
                        NSString *htmlString = [[NSString alloc] initWithData:responseObject encoding:NSUTF8StringEncoding];
                        if ([htmlString rangeOfString:@"window.location=\"home.html\""].location != NSNotFound) {
                            NSURL *homePageURL = [NSURL URLWithString:@"home.html" relativeToURL:self.baseURL];
                            NSURLRequest *homePageRequest = [NSURLRequest requestWithURL:homePageURL];
                            
                            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                            
                            __block JSOperationResult *homePageResult;
                            
                            __weak typeof(self) weakSelf = self;
                            NSURLSessionDataTask *dataTask = [self dataTaskWithRequest:homePageRequest completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
                                __strong typeof(self) strongSelf = weakSelf;
                                homePageResult = [strongSelf operationResultForRequest:request
                                                                          withResponce:(NSHTTPURLResponse *)response
                                                                        responseObject:responseObject
                                                                                 error:error];
                                dispatch_semaphore_signal(semaphore);
                            }];

                            JSCallBack *callback = [self callBackForRequest:request];
                            callback.dataTask = dataTask;
                            [dataTask resume];
                            
                            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                            return homePageResult;
                        }
                    } else if ([response.MIMEType isEqualToString:@"application/json"]){
                        result.body = responseObject;

                        NSError *serializationError = nil;
                        NSDictionary *responseObjectRepresentation = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:&serializationError];
                        if (!serializationError && responseObjectRepresentation) {
                            isTokenFetchedSuccessful = [[responseObjectRepresentation valueForKey:@"success"] boolValue];
                        }
                    }
                }
                break;
            }
            default: {
                isTokenFetchedSuccessful = !error;
            }
        }
        if (!isTokenFetchedSuccessful) {
            result.error = [JSErrorBuilder errorWithCode:JSInvalidCredentialsErrorCode];
        } else if (error && [error.domain isEqualToString:NSURLErrorDomain]) {
            result.error = error;
        }
    } else {
        // Error handling
        if (![result isSuccessful] || error) {
            if (response.statusCode == 401) {
                result.error = [JSErrorBuilder httpErrorWithCode:JSSessionExpiredErrorCode
                                                        HTTPCode:response.statusCode];
            } else if (response.statusCode == 403) {
                result.error = [JSErrorBuilder errorWithCode:JSAccessDeniedErrorCode];
            } else if (response.statusCode && !error) {
                result.error = [JSErrorBuilder httpErrorWithCode:JSHTTPErrorCode
                                                        HTTPCode:response.statusCode];
            } else if ([error.domain isEqualToString:NSURLErrorDomain]) {
                switch (error.code) {
                    case NSURLErrorUserCancelledAuthentication:
                    case NSURLErrorUserAuthenticationRequired: {
                        result.error = [JSErrorBuilder errorWithCode:JSSessionExpiredErrorCode];
                        break;
                    }
                    case NSURLErrorCannotFindHost:
                    case NSURLErrorCannotConnectToHost:
                    case NSURLErrorResourceUnavailable:{
                        result.error = [JSErrorBuilder errorWithCode:JSServerNotReachableErrorCode];
                        break;
                    }
                    case NSURLErrorTimedOut: {
                        result.error = [JSErrorBuilder errorWithCode:JSRequestTimeOutErrorCode];
                        break;
                    }
                    default: {
                        result.error = [JSErrorBuilder errorWithCode:JSHTTPErrorCode message:error.localizedDescription];
                    }
                }
            } else if ([error.domain isEqualToString:AFURLResponseSerializationErrorDomain]) {
                // There are cases when afnetworking doesn't handle wrong json deserializing,
                // so we have 'NSCocoaErrorDomain' with code 3840
                result.body = [error.userInfo objectForKey:AFNetworkingOperationFailingURLResponseDataErrorKey];

                if ([result.MIMEType isEqualToString:[JSUtils usedMimeType]]) {
                    result.error = [JSErrorBuilder errorWithCode:JSDataMappingErrorCode];
                } else {
                    result.error = [JSErrorBuilder errorWithCode:JSUnsupportedAcceptTypeErrorCode];
                }
            } else {
                result.error = [JSErrorBuilder errorWithCode:JSOtherErrorCode
                                                     message:error.userInfo[NSLocalizedDescriptionKey]];
            }
        }

        // Save file if needed
        if (!result.request.responseAsObjects && [responseObject isKindOfClass:[NSURL class]]) {
            NSString *destinationFilePath = result.request.downloadDestinationPath;
            NSString *sourceFilePath = [(NSURL *)responseObject absoluteString];

            if (!result.error && sourceFilePath && destinationFilePath && [[NSFileManager defaultManager] fileExistsAtPath:sourceFilePath]) {
                NSError *fileSavingError = nil;
                [[NSFileManager defaultManager] moveItemAtPath:sourceFilePath toPath:destinationFilePath error:&fileSavingError];
                if (fileSavingError) {
                    result.error = [JSErrorBuilder errorWithCode:JSFileSavingErrorCode
                                                         message:fileSavingError.userInfo[NSLocalizedDescriptionKey]];
                }
            } else {
                result.error = [JSErrorBuilder errorWithCode:JSFileSavingErrorCode];
            }
            if (sourceFilePath && [[NSFileManager defaultManager] fileExistsAtPath:sourceFilePath]) {
                [[NSFileManager defaultManager] removeItemAtPath:sourceFilePath error:nil];
            }
        } else if(responseObject && ![responseObject isEqualToData:[NSData dataWithBytes:" " length:1]]) { // Response object maping. Workaround for behavior of Rails to return a single space for `head :ok` (a workaround for a bug in Safari), which is not interpreted as valid input by NSJSONSerialization. See https://github.com/rails/rails/issues/1742
            
            result.body = responseObject;

            NSString *contentTypeRegex = [NSString stringWithFormat:@"application/([a-zA-Z.]+[+])?json(;.+)?"];
            NSPredicate *jsonContentTypeValidator = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", contentTypeRegex];
            
            if (result.request.responseAsObjects && [jsonContentTypeValidator evaluateWithObject:response.MIMEType]) {
                NSError *serializationError = nil;
                id responseObjectRepresentation = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:&serializationError];
                
                if (![result isSuccessful]) {
                    JSMapping *mapping = [JSMapping mappingWithObjectMapping:[[JSErrorDescriptor class] objectMappingForServerProfile:self.serverProfile] keyPath:nil];
                    result.objects = [self objectFromExternalRepresentation:responseObjectRepresentation
                                                                withMapping:mapping];
                    
                    NSString *message = @"";
                    for (JSErrorDescriptor *errDescriptor in result.objects) {
                        if ([errDescriptor isKindOfClass:[errDescriptor class]]) {
                            NSString *formatString = message.length ? @",\n%@" : @"%@";
                            message = [message stringByAppendingFormat:formatString, errDescriptor.message];
                        }
                    }
                    if (message.length) {
                        result.error = [JSErrorBuilder errorWithCode:JSClientErrorCode message:message];
                    }
                } else {
                    result.objects = [self objectFromExternalRepresentation:responseObjectRepresentation
                                                                withMapping:request.objectMapping];
                }
            }
        }
    }

    if (result.error.code == JSSessionExpiredErrorCode) {
        [self deleteCookies];
    }

    return result;
}

- (void) sendCallBackForRequest:(JSRequest *)request withOperationResult:(JSOperationResult *)result {
    JSCallBack *callBack = [self callBackForRequest:request];
    if (callBack) {
        [self.requestCallBacks removeObject:callBack];
#ifndef __RELEASE__
        NSLog(_requestFinishedTemplateMessage, [callBack.dataTask.originalRequest.URL absoluteString], [result bodyAsString]);
#endif
    }

    if (request.shouldResendRequestAfterSessionExpiration && result.error && result.error.code == JSSessionExpiredErrorCode && self.serverProfile.keepSession) {
        __weak typeof(self)weakSelf = self;
        [self verifyIsSessionAuthorizedWithCompletion:^(JSOperationResult * _Nullable result) {
            __strong typeof(self)strongSelf = weakSelf;
            if (!result.error) {
                request.shouldResendRequestAfterSessionExpiration = NO;
                [strongSelf sendRequest:request];
            } else {
                if (request.completionBlock) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        request.completionBlock(result);
                    });
                }
            }
        }];
    } else {
        if (request.completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                request.completionBlock(result);
            });
        }
    }
}

- (JSCallBack *)callBackForDataTask:(NSURLSessionTask *)dataTask {
    for (JSCallBack *callBack in self.requestCallBacks) {
        if (callBack.dataTask == dataTask) {
            return callBack;
        }
    }
    return nil;
}

- (JSCallBack *)callBackForRequest:(JSRequest *)request {
    for (JSCallBack *callBack in self.requestCallBacks) {
        if (callBack.request == request) {
            return callBack;
        }
    }
    return nil;
}

- (NSArray *)objectFromExternalRepresentation:(id)responceObject withMapping:(JSMapping *)mapping {
    id nestedRepresentation = nil;
    if ([mapping.keyPath length]) {
        nestedRepresentation = [responceObject valueForKeyPath:mapping.keyPath];
    } else {
        nestedRepresentation = responceObject;
    }

    if (nestedRepresentation && nestedRepresentation != [NSNull null]) {
        // Found something to map
        if ([nestedRepresentation isKindOfClass:[NSArray class]]) {
            id mappingResult = [EKMapper arrayOfObjectsFromExternalRepresentation:nestedRepresentation withMapping:mapping.objectMapping];
            if (mappingResult) {
                return mappingResult;
            }
        } else {
            id mappingResult = [EKMapper objectFromExternalRepresentation:nestedRepresentation withMapping:mapping.objectMapping];
            if (mappingResult) {
                return @[mappingResult];
            }
        }
    } else { // Handle value not found case
#ifndef __RELEASE__
        NSLog(@"Value cann't be mapped for mapping: %@", mapping);
#endif
    }
    return nil;
}

- (JSOperationResult *) operationResultForSerializationError:(NSError *)serializationError {
    JSOperationResult *result = [JSOperationResult new];
    result.error = [NSError errorWithDomain:JSErrorDomain code:JSOtherErrorCode userInfo:serializationError.userInfo];
    return result;
}

- (BOOL)isAuthenticationRequest:(JSRequest *)request {
    return ([request.uri isEqualToString:kJS_REST_AUTHENTICATION_URI] || ([self.serverProfile isKindOfClass:[JSPAProfile class]] && request.uri.length == 0));
}

@end
