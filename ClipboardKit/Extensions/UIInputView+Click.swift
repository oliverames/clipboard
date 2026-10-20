//
//  UIInputView+Click.swift
//  ClipboardKit
//
//  Created by Riley Testut on 6/9/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import UIKit

extension UIInputView: UIInputViewAudioFeedback
{
    public var enableInputClicksWhenVisible: Bool {
        return true
    }
    
    func playInputClick()
    {
        UIDevice.current.playInputClick()
    }
}
