//
//  OnboardingViewController.swift
//  Clipboard
//
//  The setup steps capture depends on. This screen only explains them and links to Settings;
//  the permission prompts themselves come from the capture code.
//

import UIKit
import SwiftUI

class OnboardingViewController: ReservedRegionHostingController<AnyView>
{
    var onFinish: (() -> Void)?

    init()
    {
        super.init(rootView: AnyView(EmptyView()))

        self.rootView = AnyView(OnboardingView(onFinish: { [weak self] in
            self?.onFinish?()
        }))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct OnboardingStep: Identifiable
{
    var id: Int
    var symbolName: String
    var tint: Color
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var opensSettings: Bool
    var isOptional = false
}

struct OnboardingView: View
{
    var onFinish: () -> Void

    @ScaledMetric(relativeTo: .largeTitle)
    private var heroSize = 88.0

    @ScaledMetric(relativeTo: .headline)
    private var stepIconSize = 40.0

    private let steps = [
        OnboardingStep(id: 1, symbolName: "hand.raised.fill", tint: .blue,
                       title: "Allow paste access",
                       detail: "In Settings, go to Privacy & Security, then Paste from Other Apps, then Clipboard, and choose Allow. The option appears after Clipboard reads the clipboard once.",
                       opensSettings: true),
        OnboardingStep(id: 2, symbolName: "location.fill", tint: .green,
                       title: "Keep watching in the background",
                       detail: "In Settings, go to Clipboard, then Location, and choose Always. This keeps Clipboard watching while it's closed.",
                       opensSettings: true),
        OnboardingStep(id: 3, symbolName: "square.grid.2x2.fill", tint: .orange,
                       title: "Add the Clipboard widget",
                       detail: "iOS only lets a widget read the clipboard while the app is closed. Touch and hold your Home Screen, tap Edit, then Add Widget, and choose Clipboard.",
                       opensSettings: false),
        OnboardingStep(id: 4, symbolName: "square.2.layers.3d.fill", tint: .indigo,
                       title: "Let Shortcuts read clippings",
                       detail: "In Clipboard's settings, turn on Allow Shortcuts Access. A locked iPhone never returns clipboard history.",
                       opensSettings: false, isOptional: true)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: self.heroSize * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: self.heroSize, height: self.heroSize)
                        .background(
                            LinearGradient(colors: [Color(red: 0.99, green: 0.72, blue: 0.26), Color(red: 0.93, green: 0.42, blue: 0.13)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: self.heroSize * 0.26, style: .continuous)
                        )
                        .accessibilityHidden(true)

                    Text("Welcome to Clipboard")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Clipboard keeps a history of what you copy, so nothing you copied is lost. It all stays on this iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.steps) { step in
                        self.stepView(step)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Button(action: self.onFinish) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 480)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background {
                // Steps scroll under the button, so fade them out behind it.
                LinearGradient(stops: [.init(color: Color(uiColor: .systemGroupedBackground).opacity(0), location: 0), .init(color: Color(uiColor: .systemGroupedBackground), location: 0.4)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }

    private func stepView(_ step: OnboardingStep) -> some View
    {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbolName)
                .font(.system(size: self.stepIconSize * 0.45, weight: .semibold))
                .foregroundStyle(step.tint)
                .frame(width: self.stepIconSize, height: self.stepIconSize)
                .background(step.tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(step.title)
                        .font(.headline)

                    if step.isOptional
                    {
                        Text("Optional")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                }

                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if step.opensSettings
                {
                    Button("Open Settings") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Step \(step.id)"))
    }
}
