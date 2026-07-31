import SwiftUI
import TableCore
import UIKit

/// The share sheet's entry point (DESIGN §4).
///
/// Everything it does is copy the shared items into the app group container and append queue
/// rows; the app hashes and uploads them. Nothing here touches the network.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let intake = SharedItemsIntake(items: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        let confirmation = UIHostingController(
            rootView: ShareConfirmationView(intake: intake) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )
        addChild(confirmation)
        confirmation.view.frame = view.bounds
        confirmation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(confirmation.view)
        confirmation.didMove(toParent: self)
    }
}
