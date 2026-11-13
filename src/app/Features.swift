// Features that are built but not shown yet. Each is off unless turned on for this Mac, then the
// app relaunched:
//   defaults write dev.walkscape.app featureTreadmill -bool true
//   defaults write dev.walkscape.app featureCutoutSwitch -bool true

import Foundation

enum Features {
  /// The Treadmill section: the walk's speed from a treadmill app over Direct Connect instead of
  /// the slider. Off: the slider always sets the speed.
  static let treadmill = UserDefaults.standard.bool(forKey: "featureTreadmill")
  /// The Cutout switch (Video Effects or Vision). Off: Apple's Video Effects engine, with Vision
  /// still taking over by itself when it is missing or keeps failing.
  static let cutoutSwitch = UserDefaults.standard.bool(forKey: "featureCutoutSwitch")
}
