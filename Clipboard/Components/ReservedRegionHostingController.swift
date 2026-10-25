//
//  ReservedRegionHostingController.swift
//  Clipboard
//

import SwiftUI

/// A hosting controller whose SwiftUI content stays clear of the regions the system reserves along a side,
/// such as the status bar and toolbar column on iPhone Duo's outer display. SwiftUI doesn't read those regions
/// itself, so they arrive as extra safe area.
class ReservedRegionHostingController<Content: View>: UIHostingController<Content>
{
    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()

        let reserved = self.view.reservedRegionInsets()

        // The safe area may already cover part of a reserved column, so only add what it doesn't.
        let baseLeft = self.view.safeAreaInsets.left - self.additionalSafeAreaInsets.left
        let baseRight = self.view.safeAreaInsets.right - self.additionalSafeAreaInsets.right

        let insets = UIEdgeInsets(top: 0, left: max(0, reserved.left - baseLeft), bottom: 0, right: max(0, reserved.right - baseRight))
        if self.additionalSafeAreaInsets != insets
        {
            self.additionalSafeAreaInsets = insets
        }
    }
}
