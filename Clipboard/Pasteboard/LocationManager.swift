//
//  LocationManager.swift
//  Clipboard
//
//  Created by Riley Testut on 11/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import CoreLocation
import Combine
import UIKit

extension LocationManager
{
    typealias Status = Result<Void, Swift.Error>
    
    enum Error: LocalizedError, RecoverableError
    {
        case requiresAlwaysAuthorization
        
        var failureReason: String? {
            switch self
            {
            case .requiresAlwaysAuthorization: return NSLocalizedString("Clipboard requires “Always” location permission.", comment: "")
            }
        }
        
        var recoverySuggestion: String? {
            switch self
            {
            case .requiresAlwaysAuthorization: return NSLocalizedString("Please grant Clipboard “Always” location permission in Settings so it can run in the background indefinitely.", comment: "")
            }
        }
        
        var recoveryOptions: [String] {
            switch self
            {
            case .requiresAlwaysAuthorization: return [NSLocalizedString("Open Settings", comment: "")]
            }
        }
        
        func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool
        {
            return false
        }
        
        func attemptRecovery(optionIndex recoveryOptionIndex: Int, resultHandler handler: @escaping (Bool) -> Void)
        {
            switch self
            {
            case .requiresAlwaysAuthorization:
                let openURL = URL(string: UIApplication.openSettingsURLString)!
                UIApplication.shared.open(openURL, options: [:], completionHandler: handler)
            }
        }
    }
}

class LocationManager: NSObject, ObservableObject
{
    @PublishedPipeline({ removeDuplicatesPipeline($0) })
    var status: Status? = nil
    
    var location: CLLocation? {
        return self.locationManager.location
    }

    private let locationManager: CLLocationManager

    override init()
    {
        self.locationManager = CLLocationManager()
        // A distance filter of CLLocationDistanceMax stops updates almost entirely, which lets
        // iOS suspend the app. Continuous updates keep the location session (and the app) alive.
        self.locationManager.distanceFilter = kCLDistanceFilterNone
        self.locationManager.pausesLocationUpdatesAutomatically = false
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.showsBackgroundLocationIndicator = false
        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        
        super.init()
        
        self.locationManager.delegate = self
    }
    
    func start()
    {
        switch self.status
        {
        case .success: return
        case .failure, nil: break
        }
        
        if CLLocationManager.authorizationStatus() == .notDetermined || CLLocationManager.authorizationStatus() == .authorizedWhenInUse
        {
            self.locationManager.requestAlwaysAuthorization()
            return
        }
        
        self.locationManager.startUpdatingLocation()

        // Significant-change monitoring lets iOS relaunch the app after it has been terminated,
        // so background monitoring doesn't depend on the app still being in memory.
        self.locationManager.startMonitoringSignificantLocationChanges()

        // NOTE: region monitoring (CLMonitor / a geofence) is the one mechanism Apple's
        // engineers say also relaunches after a user force-quit, and it is the natural
        // next step for surviving that case. It is intentionally NOT wired up here: on
        // iOS 27.2 `CLMonitor.init` raises an uncatchable Objective-C assertion in this
        // context and aborts the app at launch, and its force-quit benefit is unverified
        // on iOS 27 anyway. It must be prototyped and confirmed on a device (with no
        // debugger attached) before it ships. See docs/ios-pasteboard-background-access.md
        // and GitHub issue #1.
    }

    func stop()
    {
        self.locationManager.stopUpdatingLocation()
        self.locationManager.stopMonitoringSignificantLocationChanges()
        self.status = nil
    }
}

private extension LocationManager
{
    static func removeDuplicatesPipeline<T: Publisher>(_ publisher: T) -> AnyPublisher<Status?, Never>
    where T.Output == Status?, T.Failure == Never
    {
        return publisher
            .removeDuplicates { (a, b) in
                switch (a, b)
                {
                case (nil, nil), (.success(()), .success(())): return true
                case (.failure(let errorA as NSError), .failure(let errorB as NSError)): return errorA.domain == errorB.domain && errorA.code == errorB.code
                case (nil, _), (.success, _), (.failure, _): return false
                }
            }
            .eraseToAnyPublisher()
    }
}

extension LocationManager: CLLocationManagerDelegate
{
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus)
    {
        switch status
        {
        case .notDetermined: break
        case .restricted, .denied, .authorizedWhenInUse: self.status = .failure(Error.requiresAlwaysAuthorization)
        case .authorizedAlways: self.start()
        @unknown default: break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    {
        self.status = .success(())
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Swift.Error)
    {
        if let error = error as? CLError
        {
            guard error.code != .denied else {
                self.status = .failure(Error.requiresAlwaysAuthorization)
                return
            }
        }
        
        self.status = .failure(error)
    }
}
