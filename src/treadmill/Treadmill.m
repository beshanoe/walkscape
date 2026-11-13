// DirCon client and browser (see Treadmill.h). Wahoo never published DirCon; the layout follows QZ
// (github.com/cagnulein/qdomyos-zwift, src/devices/dircon/dirconpacket.cpp) and a DirCon server
// that serves it:
//   header  [0] version 1  [1] message id  [2] sequence  [3] response code  [4..5] length, BIG endian
//   ids     01 discover services (→ N × UUID), 02 discover characteristics (service UUID → service
//           UUID + N × (UUID + properties)), 03 read, 04 write (never sent here), 05 enable
//           notifications (UUID + 1/0), 06 notification (UUID + value, from the server)
//   UUIDs   16 bytes, Bluetooth base 0000xxxx-0000-1000-8000-00805f9b34fb, 16-bit id in bytes 2–3
// A response echoes the request's id and sequence. Values inside keep FTMS's little endian.

#import "Treadmill.h"

#import <Network/Network.h>
#import <os/log.h>

NSString *const TreadmillServiceType = @"_wahoo-fitness-tnp._tcp";
const uint16_t TreadmillDefaultPort = 36866;

static os_log_t Log(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("dev.walkscape.app", "treadmill");
  });
  return log;
}

enum {
  kMsgDiscoverServices = 0x01,
  kMsgDiscoverCharacteristics = 0x02,
  kMsgEnableNotifications = 0x05,
  kMsgNotification = 0x06,
};
enum {
  kFTMS = 0x1826,
  kTreadmillData = 0x2ACD,
  kMachineStatus = 0x2ADA,
};
enum { kPropNotify = 0x04, kPropIndicate = 0x08 };

static const uint8_t kBaseUUID[16] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                      0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB};

static void AppendUUID(NSMutableData *d, uint16_t uuid) {
  uint8_t b[16];
  memcpy(b, kBaseUUID, 16);
  b[2] = uuid >> 8;
  b[3] = uuid & 0xFF;
  [d appendBytes:b length:16];
}

/// The 16-bit UUID in 16 bytes, or 0 if it isn't on the Bluetooth base UUID.
static uint16_t ShortUUID(const uint8_t *b) {
  if (b[0] || b[1] || memcmp(b + 4, kBaseUUID + 4, 12)) return 0;
  return (uint16_t)(b[2] << 8 | b[3]);
}

static NSString *ErrorText(nw_error_t error) {
  if (!error) return @"no error";
  CFErrorRef e = nw_error_copy_cf_error(error);
  NSString *text = ((__bridge NSError *)e).localizedDescription;
  if (e) CFRelease(e);
  return text ?: @"error";
}

// MARK: - FTMS Treadmill Data

BOOL TreadmillParseData(const uint8_t *bytes, size_t length, TreadmillReading *out) {
  TreadmillReading r = {NO, 0, NAN, NAN, -1, -1};
  size_t i = 0;
  // Little-endian readers; each fails (returns NO) past the end.
#define NEED(n) if (i + (n) > length) return NO
#define U8() (bytes[i++])
#define U16() (i += 2, (uint16_t)(bytes[i - 2] | bytes[i - 1] << 8))
  NEED(2);
  uint16_t flags = U16();
  BOOL (^has)(int) = ^BOOL(int bit) { return (flags >> bit) & 1; };
  if (!has(0)) { NEED(2); r.hasSpeed = YES; r.speedKmh = U16() / 100.0; }  // bit 0 = More Data (inverted)
  if (has(1)) { NEED(2); i += 2; }                                         // average speed
  if (has(2)) { NEED(3); r.distanceMetres = bytes[i] | bytes[i + 1] << 8 | bytes[i + 2] << 16; i += 3; }
  if (has(3)) { NEED(4); r.inclinePercent = (int16_t)U16() / 10.0; i += 2; }  // incline, ramp angle
  if (has(4)) { NEED(4); i += 4; }                                         // elevation gain +/−
  if (has(5)) { NEED(1); i += 1; }                                         // instantaneous pace
  if (has(6)) { NEED(1); i += 1; }                                         // average pace
  if (has(7)) { NEED(5); i += 5; }                                         // energy: total, per hour, per minute
  if (has(8)) { NEED(1); r.heartRate = U8(); }
  if (has(9)) { NEED(1); i += 1; }                                         // metabolic equivalent
  if (has(10)) { NEED(2); r.elapsedSeconds = U16(); }
#undef NEED
#undef U8
#undef U16
  if (out) *out = r;
  return YES;
}

// MARK: - Endpoint

@interface TreadmillEndpoint ()
- (nw_endpoint_t)nwEndpoint;
@end

@implementation TreadmillEndpoint {
  NSString *_host;     // host:port endpoint
  uint16_t _port;
  NSString *_service;  // Bonjour endpoint
}

- (instancetype)initWithIdentifier:(NSString *)identifier name:(NSString *)name {
  if ((self = [super init])) {
    _identifier = identifier;
    _name = name;
  }
  return self;
}

+ (TreadmillEndpoint *)thisMac {
  TreadmillEndpoint *e = [[self alloc] initWithIdentifier:@"this-mac" name:@"Treadmill app on this Mac"];
  e->_host = @"127.0.0.1";
  e->_port = TreadmillDefaultPort;
  return e;
}

+ (instancetype)bonjourService:(NSString *)name {
  TreadmillEndpoint *e = [[self alloc] initWithIdentifier:[@"bonjour:" stringByAppendingString:name] name:name];
  e->_service = name;
  return e;
}

+ (instancetype)host:(NSString *)host port:(uint16_t)port {
  NSString *name = [NSString stringWithFormat:@"%@:%u", host, port];
  TreadmillEndpoint *e = [[self alloc] initWithIdentifier:[@"host:" stringByAppendingString:name] name:name];
  e->_host = host;
  e->_port = port;
  return e;
}

+ (instancetype)endpointWithIdentifier:(NSString *)identifier {
  if ([identifier isEqualToString:@"this-mac"]) return self.thisMac;
  if ([identifier hasPrefix:@"bonjour:"] && identifier.length > 8) return [self bonjourService:[identifier substringFromIndex:8]];
  if ([identifier hasPrefix:@"host:"]) {
    NSString *rest = [identifier substringFromIndex:5];
    NSRange colon = [rest rangeOfString:@":" options:NSBackwardsSearch];
    int port = colon.location == NSNotFound ? 0 : [rest substringFromIndex:colon.location + 1].intValue;
    if (port > 0 && port < 65536) return [self host:[rest substringToIndex:colon.location] port:(uint16_t)port];
  }
  return nil;
}

- (nw_endpoint_t)nwEndpoint {
  if (_service) return nw_endpoint_create_bonjour_service(_service.UTF8String, TreadmillServiceType.UTF8String, "local.");
  return nw_endpoint_create_host(_host.UTF8String, [NSString stringWithFormat:@"%u", _port].UTF8String);
}

- (BOOL)isEqual:(id)other {
  return [other isKindOfClass:[TreadmillEndpoint class]] && [((TreadmillEndpoint *)other).identifier isEqualToString:_identifier];
}

- (NSUInteger)hash {
  return _identifier.hash;
}
@end

// MARK: - Link

@implementation TreadmillLink {
  dispatch_queue_t _queue;
  nw_connection_t _connection;  // _queue
  NSMutableData *_buffer;
  uint8_t _sequence;
  BOOL _running, _subscribed, _retryScheduled, _quiet;
  CFAbsoluteTime _lastReading;
  dispatch_source_t _watchdog;
  NSString *_problem;           // last reported, to report changes only
  BOOL _reportedConnected, _reportedOnce;
}

- (instancetype)initWithEndpoint:(TreadmillEndpoint *)endpoint {
  if ((self = [super init])) {
    _endpoint = endpoint;
    _queue = dispatch_queue_create("treadmill.link", DISPATCH_QUEUE_SERIAL);
    _buffer = [NSMutableData data];
  }
  return self;
}

- (void)dealloc {
  if (_watchdog) dispatch_source_cancel(_watchdog);
  if (_connection) nw_connection_cancel(_connection);
}

- (void)start {
  dispatch_async(_queue, ^{
    if (self->_running) return;
    self->_running = YES;
    [self startWatchdog];
    [self connect];
  });
}

- (void)stop {
  dispatch_async(_queue, ^{
    self->_running = NO;
    if (self->_watchdog) dispatch_source_cancel(self->_watchdog);
    self->_watchdog = nil;
    [self disconnect];
  });
}

- (void)log:(NSString *)line {
  os_log(Log(), "%{public}@: %{public}@", self->_endpoint.name, line);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.logHandler) self.logHandler(line);
  });
}

/// _queue. Tells the main queue when connected or the problem changed.
- (void)reportConnected:(BOOL)connected problem:(nullable NSString *)problem {
  if (_reportedOnce && connected == _reportedConnected && (problem == _problem || [problem isEqualToString:_problem])) return;
  _reportedOnce = YES;
  _reportedConnected = connected;
  _problem = problem;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.stateHandler) self.stateHandler(connected, problem);
  });
}

- (void)reportReading:(TreadmillReading)reading {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.readingHandler) self.readingHandler(reading);
  });
}

- (void)connect {
  if (!_running || _connection) return;
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) {
    nw_tcp_options_set_no_delay(tcp, true);
    // Notices a source that vanished from the network (loopback never does) in about 10 s.
    nw_tcp_options_set_enable_keepalive(tcp, true);
    nw_tcp_options_set_keepalive_idle_time(tcp, 5);
    nw_tcp_options_set_keepalive_interval(tcp, 2);
    nw_tcp_options_set_keepalive_count(tcp, 3);
  });
  nw_connection_t connection = nw_connection_create([_endpoint nwEndpoint], parameters);
  _connection = connection;
  _buffer.length = 0;
  _subscribed = NO;
  nw_connection_set_queue(connection, _queue);
  __weak TreadmillLink *weakSelf = self;
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
    TreadmillLink *link = weakSelf;
    if (!link || link->_connection != connection) return;
    switch (state) {
    case nw_connection_state_ready:
      [link log:@"connected; discovering services"];
      [link send:kMsgDiscoverServices payload:nil];
      [link receive];
      break;
    case nw_connection_state_waiting:   // e.g. connection refused: nothing listens yet
    case nw_connection_state_failed:
      [link reportConnected:NO problem:[NSString stringWithFormat:@"Waiting for %@", link->_endpoint.name]];
      [link log:[NSString stringWithFormat:@"not reachable (%@), retrying", ErrorText(error)]];
      [link disconnect];
      [link retryLater];
      break;
    default:
      break;
    }
  });
  nw_connection_start(connection);
}

- (void)disconnect {
  if (!_connection) return;
  nw_connection_cancel(_connection);
  _connection = nil;
  _subscribed = NO;
}

- (void)retryLater {
  if (_retryScheduled || !_running) return;
  _retryScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _queue, ^{
    self->_retryScheduled = NO;
    [self connect];
  });
}

/// Once a second: a source that stops sending readings means the belt is no longer moving for
/// us (its app lost the treadmill, or it went quiet): report speed 0 after 3 s.
- (void)startWatchdog {
  _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_watchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
  __weak TreadmillLink *weakSelf = self;
  dispatch_source_set_event_handler(_watchdog, ^{
    TreadmillLink *link = weakSelf;
    if (!link || !link->_subscribed || link->_quiet) return;
    if (CFAbsoluteTimeGetCurrent() - link->_lastReading > 3) {
      link->_quiet = YES;
      [link log:@"no readings for 3 s"];
      [link reportConnected:YES problem:[NSString stringWithFormat:@"No readings from %@", link->_endpoint.name]];
      TreadmillReading stopped = {YES, 0, NAN, NAN, -1, -1};
      [link reportReading:stopped];
    }
  });
  dispatch_resume(_watchdog);
}

- (void)send:(uint8_t)message payload:(nullable NSData *)payload {
  if (!_connection) return;
  NSUInteger n = payload.length;
  uint8_t header[6] = {0x01, message, ++_sequence, 0x00, (uint8_t)(n >> 8), (uint8_t)(n & 0xFF)};
  NSMutableData *d = [NSMutableData dataWithBytes:header length:6];
  if (payload) [d appendData:payload];
  dispatch_data_t content = dispatch_data_create(d.bytes, d.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  nw_connection_send(_connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {});
}

- (void)receive {
  nw_connection_t connection = _connection;
  if (!connection) return;
  __weak TreadmillLink *weakSelf = self;
  nw_connection_receive(connection, 1, 4096, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
    TreadmillLink *link = weakSelf;
    if (!link || link->_connection != connection) return;
    if (content) {
      dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        [link->_buffer appendBytes:buffer length:size];
        return true;
      });
      [link drainBuffer];
    }
    BOOL closed = error || (complete && (!context || nw_content_context_get_is_final(context)));
    if (closed) {
      [link log:error ? [NSString stringWithFormat:@"connection lost (%@)", ErrorText(error)] : @"closed by the source"];
      [link reportConnected:NO problem:[NSString stringWithFormat:@"Waiting for %@", link->_endpoint.name]];
      [link disconnect];
      [link retryLater];
    } else if (link->_connection == connection) {
      [link receive];
    }
  });
}

- (void)drainBuffer {
  while (_buffer.length >= 6 && _connection) {
    const uint8_t *b = _buffer.bytes;
    NSUInteger length = (NSUInteger)(b[4] << 8 | b[5]);
    if (_buffer.length < 6 + length) return;
    NSData *payload = [_buffer subdataWithRange:NSMakeRange(6, length)];
    uint8_t message = b[1], code = b[3];
    [_buffer replaceBytesInRange:NSMakeRange(0, 6 + length) withBytes:NULL length:0];
    [self handle:message code:code payload:payload];
  }
}

- (void)handle:(uint8_t)message code:(uint8_t)code payload:(NSData *)payload {
  const uint8_t *p = payload.bytes;
  NSUInteger n = payload.length;
  if (message != kMsgNotification && code != 0) {
    [self log:[NSString stringWithFormat:@"request %02x refused (code %u)", message, code]];
    if ((message == kMsgEnableNotifications && !_subscribed) || message == kMsgDiscoverCharacteristics) {
      [self reportConnected:NO problem:[NSString stringWithFormat:@"%@ doesn't share treadmill data", _endpoint.name]];
    }
    return;
  }
  switch (message) {
  case kMsgDiscoverServices: {
    BOOL ftms = NO;
    for (NSUInteger i = 0; i + 16 <= n; i += 16) ftms |= ShortUUID(p + i) == kFTMS;
    if (!ftms) {
      [self log:@"no FTMS service"];
      [self reportConnected:NO problem:[NSString stringWithFormat:@"%@ isn't a treadmill (no FTMS)", _endpoint.name]];
      return;
    }
    [self log:@"FTMS found; discovering characteristics"];
    NSMutableData *d = [NSMutableData data];
    AppendUUID(d, kFTMS);
    [self send:kMsgDiscoverCharacteristics payload:d];
    break;
  }
  case kMsgDiscoverCharacteristics: {
    BOOL data = NO, status = NO;
    for (NSUInteger i = 16; i + 17 <= n; i += 17) {
      uint16_t uuid = ShortUUID(p + i);
      BOOL notifies = (p[i + 16] & (kPropNotify | kPropIndicate)) != 0;
      data |= uuid == kTreadmillData && notifies;
      status |= uuid == kMachineStatus && notifies;
    }
    if (!data) {
      [self log:@"no Treadmill Data characteristic"];
      [self reportConnected:NO problem:[NSString stringWithFormat:@"%@ isn't a treadmill (no Treadmill Data)", _endpoint.name]];
      return;
    }
    for (int i = 0; i < (status ? 2 : 1); i++) {
      NSMutableData *d = [NSMutableData data];
      AppendUUID(d, i == 0 ? kTreadmillData : kMachineStatus);
      uint8_t on = 1;
      [d appendBytes:&on length:1];
      [self send:kMsgEnableNotifications payload:d];
    }
    [self log:status ? @"subscribing to treadmill data and machine status" : @"subscribing to treadmill data"];
    break;
  }
  case kMsgEnableNotifications:
    if (n >= 16 && ShortUUID(p) == kTreadmillData) {
      _subscribed = YES;
      _quiet = NO;
      _lastReading = CFAbsoluteTimeGetCurrent();
      [self log:@"subscribed"];
      [self reportConnected:YES problem:nil];
    }
    break;
  case kMsgNotification: {
    if (n < 16) return;
    uint16_t uuid = ShortUUID(p);
    if (uuid == kTreadmillData) {
      TreadmillReading r;
      if (!TreadmillParseData(p + 16, n - 16, &r)) {
        [self log:@"truncated treadmill data"];
        return;
      }
      if (!r.hasSpeed) return;
      _lastReading = CFAbsoluteTimeGetCurrent();
      if (_quiet) {
        _quiet = NO;
        [self reportConnected:YES problem:nil];
      }
      [self reportReading:r];
    } else if (uuid == kMachineStatus && n > 16) {
      uint8_t op = p[16];
      [self log:op == 0x04 ? @"belt started" : op == 0x02 || op == 0x03 ? @"belt stopped" : [NSString stringWithFormat:@"machine status %02x", op]];
    }
    break;
  }
  default:
    break;
  }
}
@end

// MARK: - Browser

/// The TXT record's `ble-service-uuids` lists 1826 (FTMS); a source without the record is kept.
static BOOL OffersFTMS(nw_txt_record_t txt) {
  if (!txt) return YES;
  __block BOOL offers = NO, listed = NO;
  nw_txt_record_access_key(txt, "ble-service-uuids", ^bool(const char *key, nw_txt_record_find_key_t found, const uint8_t *value, size_t length) {
    if (found == nw_txt_record_find_key_non_empty_value && value) {
      listed = YES;
      NSString *list = [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding].lowercaseString;
      offers = [list containsString:@"1826"];
    }
    return true;
  });
  return offers || !listed;
}


@implementation TreadmillBrowser {
  dispatch_queue_t _queue;
  nw_browser_t _browser;                                    // _queue
  NSMutableDictionary<NSString *, TreadmillEndpoint *> *_found;  // _queue, by name
  NSString *_ownName;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("treadmill.browser", DISPATCH_QUEUE_SERIAL);
    _found = [NSMutableDictionary dictionary];
    _endpoints = @[];
    // A Direct Connect treadmill app on this Mac that also serves the local network advertises
    // itself as "Run500 (<computer name>)"; thisMac already covers it, so it's left out.
    _ownName = [NSString stringWithFormat:@"Run500 (%@)", NSHost.currentHost.localizedName ?: @"Mac"];
  }
  return self;
}

- (void)dealloc {
  if (_browser) nw_browser_cancel(_browser);
}

- (void)start {
  dispatch_async(_queue, ^{
    if (self->_browser) return;
    nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_bonjour_service(TreadmillServiceType.UTF8String, "local.");
    nw_browse_descriptor_set_include_txt_record(descriptor, true);
    nw_browser_t browser = nw_browser_create(descriptor, nw_parameters_create());
    self->_browser = browser;
    nw_browser_set_queue(browser, self->_queue);
    __weak TreadmillBrowser *weakSelf = self;
    nw_browser_set_state_changed_handler(browser, ^(nw_browser_state_t state, nw_error_t error) {
      TreadmillBrowser *b = weakSelf;
      if (!b) return;
      NSString *problem = nil;
      if ((state == nw_browser_state_waiting || state == nw_browser_state_failed) && error) {
        BOOL denied = nw_error_get_error_domain(error) == nw_error_domain_dns && nw_error_get_error_code(error) == -65570;  // kDNSServiceErr_PolicyDenied
        problem = denied ? @"Local network access is off for WalkScape (System Settings › Privacy & Security › Local Network)"
                         : [NSString stringWithFormat:@"Can't search the network: %@", ErrorText(error)];
      }
      [b publishProblem:problem];
    });
    nw_browser_set_browse_results_changed_handler(browser, ^(nw_browse_result_t old, nw_browse_result_t new, bool complete) {
      TreadmillBrowser *b = weakSelf;
      if (!b) return;
      if (old) {
        nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(old);
        const char *name = nw_endpoint_get_bonjour_service_name(endpoint);
        if (name) [b->_found removeObjectForKey:@(name)];
      }
      if (new) {
        nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(new);
        const char *cname = nw_endpoint_get_bonjour_service_name(endpoint);
        NSString *name = cname ? @(cname) : nil;
        if (name && ![name isEqualToString:b->_ownName] && OffersFTMS(nw_browse_result_copy_txt_record_object(new))) {
          b->_found[name] = [TreadmillEndpoint bonjourService:name];
        }
      }
      if (complete) [b publishEndpoints];
    });
    nw_browser_start(browser);
  });
}

- (void)publishEndpoints {
  NSArray *endpoints = [_found.allValues sortedArrayUsingComparator:^NSComparisonResult(TreadmillEndpoint *a, TreadmillEndpoint *b) {
    return [a.name localizedCaseInsensitiveCompare:b.name];
  }];
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_endpoints = endpoints;
    if (self.changeHandler) self.changeHandler();
  });
}

- (void)publishProblem:(nullable NSString *)problem {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (problem == self->_problem || [problem isEqualToString:self->_problem]) return;
    self->_problem = problem;
    if (problem) os_log(Log(), "browse: %{public}@", problem);
    if (self.changeHandler) self.changeHandler();
  });
}

- (void)stop {
  dispatch_async(_queue, ^{
    if (self->_browser) nw_browser_cancel(self->_browser);
    self->_browser = nil;
    [self->_found removeAllObjects];
    [self publishEndpoints];
  });
}
@end
