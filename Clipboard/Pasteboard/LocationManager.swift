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

    /// A geofence around the last known location. Region monitoring is the one Core
    /// Location mechanism Apple's engineers say relaunches an app after the user
    /// force-quits it, and it also relaunches after a reboot once the device is first
    /// unlocked. It is kept deliberately separate from the significant-change and
    /// continuous-update session above so that, if it ever fails, the proven path is
    /// untouched. Whether it actually relaunches on iOS 27.2 after a force-quit is
    /// unverified and must be confirmed on device (see the capture research doc).
    private var regionMonitorTask: Task<Void, Never>?
    private static let regionMonitorName = "com.oliverames.clipboard.capture"
    private static let geofenceIdentifier = "capture.recenter"
    /// Small radius so leaving it (and thus a relaunch opportunity) happens on a short move.
    private static let geofenceRadius: CLLocationDistance = 100

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

        self.startRegionMonitoring()
    }

    func stop()
    {
        self.locationManager.stopUpdatingLocation()
        self.locationManager.stopMonitoringSignificantLocationChanges()
        self.regionMonitorTask?.cancel()
        self.regionMonitorTask = nil
        self.status = nil
    }

    /// Starts (or, after a relaunch, resumes) region monitoring. Recreating a
    /// `CLMonitor` with the same name restores its conditions, so a geofence added in
    /// a previous launch is still being watched; iterating its events here keeps the
    /// app able to re-center the fence as the device moves. All of this is isolated in
    /// its own task and its failures are swallowed, so it can never disturb the
    /// significant-change / continuous-update path.
    private func startRegionMonitoring()
    {
        guard self.regionMonitorTask == nil else { return }

        self.regionMonitorTask = Task { [weak self] in
            let monitor = await CLMonitor(LocationManager.regionMonitorName)

            // If a relaunch restored no condition yet, seed one at the current location.
            if await monitor.identifiers.isEmpty, let coordinate = self?.locationManager.location?.coordinate
            {
                let condition = CLMonitor.CircularGeographicCondition(center: coordinate, radius: LocationManager.geofenceRadius)
                await monitor.add(condition, identifier: LocationManager.geofenceIdentifier, assuming: .satisfied)
            }

            do
            {
                for try await event in await monitor.events
                {
                    guard !Task.isCancelled else { break }

                    // Leaving the fence is the relaunch-worthy move; re-center so the
                    // next move out also fires (and relaunches us if we were killed).
                    if event.state == .unsatisfied, let coordinate = self?.locationManager.location?.coordinate
                    {
                        let condition = CLMonitor.CircularGeographicCondition(center: coordinate, radius: LocationManager.geofenceRadius)
                        await monitor.add(condition, identifier: LocationManager.geofenceIdentifier, assuming: .satisfied)
                    }
                }
            }
            catch
            {
                // Region monitoring is best-effort; never let it break the proven path.
            }
        }
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
