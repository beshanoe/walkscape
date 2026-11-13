// Walking speed from a treadmill app, over DirCon (Wahoo Direct Connect): Bluetooth's Fitness
// Machine Service (FTMS) carried over TCP. A DirCon server on this Mac serves it on 127.0.0.1:36866
// (no Local Network permission needed); QZ, Wahoo treadmills and DirCon servers on the network
// advertise `_wahoo-fitness-tnp._tcp` over Bonjour.
//   - TreadmillLink connects to one source, subscribes to Treadmill Data (0x2ACD) and reports each
//     reading. Read-only: it only sends discovery and "notify me" requests; there's no write in it.
//   - TreadmillBrowser lists the sources on the local network.
// Wire format (6-byte header, big-endian length, 16-byte UUIDs): docs in Treadmill.m.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TreadmillServiceType;  // "_wahoo-fitness-tnp._tcp"
extern const uint16_t TreadmillDefaultPort;   // 36866

/// One FTMS Treadmill Data value. Fields the treadmill didn't send are NAN / -1.
typedef struct {
  BOOL hasSpeed;            // NO for a "More Data" packet (the speed comes in another one)
  double speedKmh;
  double inclinePercent;
  double distanceMetres;
  int elapsedSeconds;
  int heartRate;
} TreadmillReading;

/// Parses an FTMS Treadmill Data value (characteristic 0x2ACD, little endian). NO if truncated.
BOOL TreadmillParseData(const uint8_t *bytes, size_t length, TreadmillReading *out);

/// Where to read from: a DirCon server on this Mac, a Bonjour service, or host:port (backdrop-test).
@interface TreadmillEndpoint : NSObject
/// 127.0.0.1:36866.
@property(class, readonly) TreadmillEndpoint *thisMac;
+ (instancetype)bonjourService:(NSString *)name;
+ (instancetype)host:(NSString *)host port:(uint16_t)port;
/// From `identifier` (saved settings); nil if it isn't one.
+ (nullable instancetype)endpointWithIdentifier:(NSString *)identifier;
/// "this-mac", "bonjour:<name>" or "host:<host>:<port>".
@property(nonatomic, readonly) NSString *identifier;
/// For the UI: "Treadmill app on this Mac", the Bonjour name, or host:port.
@property(nonatomic, readonly) NSString *name;
@end

/// Connects to `endpoint` and keeps the connection up (retries every 2 s while it's missing).
/// Handlers are called on the main queue; set them before `start`.
@interface TreadmillLink : NSObject
- (instancetype)initWithEndpoint:(TreadmillEndpoint *)endpoint NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) TreadmillEndpoint *endpoint;
- (void)start;
- (void)stop;
/// connected: subscribed and readings arrive. problem: why not (nil while connecting).
@property(nonatomic, copy, nullable) void (^stateHandler)(BOOL connected, NSString *_Nullable problem);
/// Each reading with a speed. After 3 s without one, a reading with speed 0 (the treadmill went quiet).
@property(nonatomic, copy, nullable) void (^readingHandler)(TreadmillReading reading);
/// Each protocol step, for backdrop-test (also in the log, category "treadmill").
@property(nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@end

/// Lists DirCon services on the local network that offer FTMS (Bonjour; the first browse asks for
/// Local Network permission). Leaves out this Mac's own DirCon server (TreadmillEndpoint.thisMac covers it).
@interface TreadmillBrowser : NSObject
- (void)start;
- (void)stop;
@property(nonatomic, readonly) NSArray<TreadmillEndpoint *> *endpoints;
/// Why browsing doesn't work (e.g. Local Network access denied), or nil.
@property(nonatomic, readonly, nullable) NSString *problem;
/// Called on the main queue when `endpoints` or `problem` change.
@property(nonatomic, copy, nullable) void (^changeHandler)(void);
@end

NS_ASSUME_NONNULL_END
