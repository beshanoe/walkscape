// SceneParameter: one setting a scene (or the host) exposes. The settings panel and backdrop-test
// build their controls from these, so a new scene setting is one descriptor plus the code that
// reads it. Values are doubles: slider values, a choice's index, 0/1 for a toggle, a seed.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SceneParameterKind) {
  SceneParameterKindSlider,
  SceneParameterKindChoice,  // value = index into `choices`
  SceneParameterKindToggle,  // 0 or 1
  SceneParameterKindSeed,    // a "New …" button that picks another layout
};

NS_SWIFT_SENDABLE
@interface SceneParameter : NSObject

+ (instancetype)sliderWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section
                      minimum:(double)minimum maximum:(double)maximum step:(double)step
                        value:(double)value format:(NSString *)format;
+ (instancetype)choiceWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section
                      choices:(NSArray<NSString *> *)choices value:(NSInteger)value;
+ (instancetype)toggleWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section value:(BOOL)value;
+ (instancetype)seedWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section value:(uint32_t)value;

/// Marks the parameter as changing the layout (where things are placed): the scene re-places its
/// instances when it changes. Returns self.
- (instancetype)relayout;

@property(nonatomic, readonly) NSString *key;      // "density"
@property(nonatomic, readonly) NSString *title;    // "Tree density"
@property(nonatomic, readonly) NSString *section;  // "Trees": the panel groups by section, in order
@property(nonatomic, readonly) SceneParameterKind kind;
@property(nonatomic, readonly) double minimum, maximum, step, defaultValue;
@property(nonatomic, readonly) NSString *format;  // printf style, sliders only
@property(nonatomic, readonly) NSArray<NSString *> *choices;
@property(nonatomic, readonly) BOOL changesLayout;

/// `value` limited to the range (sliders), a valid index (choices) or 0/1 (toggles).
- (double)clamp:(double)value;
/// Parses "0.8", or a choice's title (case-insensitive), "on"/"off" for toggles.
- (BOOL)parse:(NSString *)text value:(double *)value;
/// The value as the panel shows it ("3.5 km/h", "Autumn").
- (NSString *)describe:(double)value;

@end

NS_ASSUME_NONNULL_END
