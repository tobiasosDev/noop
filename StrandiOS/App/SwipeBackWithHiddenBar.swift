#if os(iOS)
import UIKit

/// v2 screens draw their own header and hide the system navigation bar, and UIKit disables the edge
/// swipe-back gesture whenever the bar is hidden. Re-enable it for every navigation stack: the gesture may
/// begin whenever there is a screen to go back to, which is exactly when the system bar would have shown a
/// back button.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        return viewControllers.count > 1
    }
}
#endif
