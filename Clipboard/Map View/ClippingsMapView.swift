//
//  HistoryMapView.swift
//  Clipboard
//
//  Created by Riley Testut on 3/20/24.
//  Copyright © 2024 Riley Testut. All rights reserved.
//

import MapKit
import UIKit
import SwiftUI

import ClipboardKit

@available(iOS 17, *)
class ClippingsMapViewController: UIHostingController<AnyView>
{
    @MainActor 
    required dynamic init?(coder aDecoder: NSCoder) {
        let view = AnyView(erasing: ClippingsMapView().environment(\.managedObjectContext, DatabaseManager.shared.persistentContainer.viewContext))
        super.init(coder: aDecoder, rootView: view)
        
        self.tabBarItem.image = UIImage(systemName: "map")
        self.tabBarItem.selectedImage = UIImage(systemName: "map.fill")
    }
}

@MainActor @available(iOS 17, *)
struct ClippingsMapView: View
{
    @FetchRequest(fetchRequest: PasteboardItem.historyFetchRequest())
    private var pasteboardItems: FetchedResults<PasteboardItem>

    @State
    private var selectedItem: PasteboardItem?

    @ScaledMetric(relativeTo: .body)
    private var markerSize = 36.0

    var body: some View {
        let locatedItems = self.pasteboardItems.filter { $0.location != nil }

        Map(selection: $selectedItem) {
            // Must use \.self as keypath for selection to work
            ForEach(locatedItems, id: \.self) { pasteboardItem in
                if let location = pasteboardItem.location
                {
                    let kind = ClippingKind(pasteboardItem)

                    Annotation(kind.title, coordinate: location.coordinate, anchor: .bottom) {
                        ClippingTile(kind: kind)
                            .frame(width: self.markerSize, height: self.markerSize)
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: self.markerSize * 0.36, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            .scaleEffect(self.selectedItem == pasteboardItem ? 1.2 : 1)
                            .animation(.snappy, value: self.selectedItem)
                            .accessibilityLabel(pasteboardItem.accessibilityDescription(kind: kind, title: pasteboardItem.contentText))
                    }
                    .tag(pasteboardItem)
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .overlay {
            if locatedItems.isEmpty
            {
                ContentUnavailableView {
                    Label("No Locations", systemImage: "map")
                } description: {
                    Text("Clippings you copy with Always location access appear here, at the place you copied them.")
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(32)
            }
        }
        .sensoryFeedback(.selection, trigger: self.selectedItem)
        .sheet(item: $selectedItem) { pasteboardItem in
            ClippingSheet(pasteboardItem: pasteboardItem)
        }
    }
}
