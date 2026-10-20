//
//  UNNotification+Keys.swift
//  ClipboardKit
//
//  Created by Riley Testut on 3/20/24.
//  Copyright © 2024 Riley Testut. All rights reserved.
//

import UserNotifications

public extension UNNotification
{
    static let latitudeUserInfoKey: String = "CLPLatitude"
    static let longitudeUserInfoKey: String = "CLPLongitude"
    
    static let errorMessageUserInfoKey: String = "CLPErrorMessage"
}

public extension UNNotificationCategory
{
    static let clipboardReaderIdentifier = "ClipboardReader"
}
