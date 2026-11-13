#import "SceneParameter.h"

@implementation SceneParameter

- (instancetype)initWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section kind:(SceneParameterKind)kind {
  if ((self = [super init])) {
    _key = [key copy];
    _title = [title copy];
    _section = [section copy];
    _kind = kind;
    _format = @"%.2f";
    _choices = @[];
    _step = 1;
  }
  return self;
}

+ (instancetype)sliderWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section minimum:(double)minimum
                      maximum:(double)maximum step:(double)step value:(double)value format:(NSString *)format {
  SceneParameter *p = [[self alloc] initWithKey:key title:title section:section kind:SceneParameterKindSlider];
  p->_minimum = minimum;
  p->_maximum = maximum;
  p->_step = step;
  p->_defaultValue = value;
  p->_format = [format copy];
  return p;
}

+ (instancetype)choiceWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section choices:(NSArray<NSString *> *)choices
                        value:(NSInteger)value {
  SceneParameter *p = [[self alloc] initWithKey:key title:title section:section kind:SceneParameterKindChoice];
  p->_choices = [choices copy];
  p->_maximum = MAX((double)choices.count - 1, 0);
  p->_defaultValue = value;
  return p;
}

+ (instancetype)toggleWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section value:(BOOL)value {
  SceneParameter *p = [[self alloc] initWithKey:key title:title section:section kind:SceneParameterKindToggle];
  p->_maximum = 1;
  p->_defaultValue = value ? 1 : 0;
  return p;
}

+ (instancetype)seedWithKey:(NSString *)key title:(NSString *)title section:(NSString *)section value:(uint32_t)value {
  SceneParameter *p = [[self alloc] initWithKey:key title:title section:section kind:SceneParameterKindSeed];
  p->_maximum = UINT32_MAX;
  p->_defaultValue = value;
  p->_changesLayout = YES;
  return p;
}

- (instancetype)relayout {
  _changesLayout = YES;
  return self;
}

- (double)clamp:(double)value {
  if (isnan(value)) return _defaultValue;
  switch (_kind) {
    case SceneParameterKindSlider: return fmin(fmax(value, _minimum), _maximum);
    case SceneParameterKindChoice: return fmin(fmax(round(value), 0), _maximum);
    case SceneParameterKindToggle: return value != 0 ? 1 : 0;
    case SceneParameterKindSeed: return fmin(fmax(round(value), 0), UINT32_MAX);
  }
  return value;
}

- (BOOL)parse:(NSString *)text value:(double *)value {
  NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (_kind == SceneParameterKindChoice) {
    for (NSUInteger i = 0; i < _choices.count; i++) {
      if ([_choices[i] caseInsensitiveCompare:t] == NSOrderedSame) {
        *value = i;
        return YES;
      }
    }
  }
  if (_kind == SceneParameterKindToggle) {
    BOOL on = [@[ @"on", @"yes", @"true" ] containsObject:t.lowercaseString];
    if (on || [@[ @"off", @"no", @"false" ] containsObject:t.lowercaseString]) {
      *value = on ? 1 : 0;
      return YES;
    }
  }
  NSScanner *scanner = [NSScanner scannerWithString:t];
  double v = 0;
  if (![scanner scanDouble:&v] || !scanner.isAtEnd) return NO;
  *value = [self clamp:v];
  return YES;
}

- (NSString *)describe:(double)value {
  switch (_kind) {
    case SceneParameterKindSlider: return [NSString stringWithFormat:_format, fabs(value) < _step * 1e-3 ? 0.0 : value];  // no "-0.0"
    case SceneParameterKindChoice: {
      NSInteger i = (NSInteger)[self clamp:value];
      return i < (NSInteger)_choices.count ? _choices[i] : @"";
    }
    case SceneParameterKindToggle: return value != 0 ? @"on" : @"off";
    case SceneParameterKindSeed: return [NSString stringWithFormat:@"%.0f", value];
  }
  return @"";
}

@end
