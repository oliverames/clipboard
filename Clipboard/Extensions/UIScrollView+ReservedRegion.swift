//
//  UIScrollView+ReservedRegion.swift
//  Clipboard
//

import UIKit

extension UIScrollView
{
    /// Keeps a scroll view's content and indicators clear of the occlusion regions along its sides, such as the
    /// status bar and toolbar column on iPhone Duo's outer display.
    ///
    /// Call this from `viewDidLayoutSubviews()` (or `layoutSubviews()`) so the result follows every change to the
    /// regions. The insets are read from this scroll view's own coordinate space and are never stored.
    ///
    /// - Parameter adjustingContent: Pass `false` for a scroll view whose content is pinned to its frame layout
    ///   guide, because a content inset doesn't narrow that content. Apply the returned insets to its constraints.
    /// - Returns: The width, per physical edge, that content must stay clear of (zero where nothing is reserved).
    @discardableResult
    func applyReservedRegionInsets(adjustingContent: Bool = true) -> (left: CGFloat, right: CGFloat)
    {
        let insets = self.reservedRegionInsets()

        if adjustingContent
        {
            if self.contentInset.left != insets.left || self.contentInset.right != insets.right
            {
                self.contentInset.left = insets.left
                self.contentInset.right = insets.right
            }
        }

        if self.verticalScrollIndicatorInsets.left != insets.left || self.verticalScrollIndicatorInsets.right != insets.right
        {
            self.verticalScrollIndicatorInsets.left = insets.left
            self.verticalScrollIndicatorInsets.right = insets.right
        }

        return insets
    }

    /// For a scroll view whose content is pinned to its frame layout guide, which ignores both the safe area and
    /// content insets. Returns, per physical edge, how far that content must stay from the scroll view's edge: the
    /// larger of the safe area inset (a bar along a side arrives as one) and the reserved region. Also keeps the
    /// scroll indicators clear of reserved regions. Add the result to the content's side margins at layout time.
    func sideClearanceForFrameGuideContent() -> (left: CGFloat, right: CGFloat)
    {
        let reservedInsets = self.applyReservedRegionInsets(adjustingContent: false)
        return (max(self.safeAreaInsets.left, reservedInsets.left), max(self.safeAreaInsets.right, reservedInsets.right))
    }

    /// The space the system reserves along each physical side of this view, plus a small gap.
    ///
    /// Controls stay with the hardware, so the side column can sit on either edge (a left-hand Split View app puts it
    /// on the left), and `UIEdgeInsets` is physical to match. A region that spans the full width isn't a side column.
    func reservedRegionInsets(spacing: CGFloat = 8) -> (left: CGFloat, right: CGFloat)
    {
        var left: CGFloat = 0
        var right: CGFloat = 0

        for region in self.reservedRegions(kind: .occlusion, options: []) where region.isActive
        {
            let touchesLeft = region.frame.minX <= self.bounds.minX + 1
            let touchesRight = region.frame.maxX >= self.bounds.maxX - 1

            if touchesRight && !touchesLeft
            {
                right = max(right, self.bounds.maxX - region.frame.minX)
            }
            else if touchesLeft && !touchesRight
            {
                left = max(left, region.frame.maxX - self.bounds.minX)
            }
        }

        return (left > 0 ? left + spacing : 0, right > 0 ? right + spacing : 0)
    }
}
