import SwiftUI

/// Explains the one permission Mezcla needs and offers the shortest way to grant it.
struct PermissionNotice: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("To change each app’s volume, Mezcla needs permission to record system audio. Your audio never leaves this Mac.")
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
            }

            Group {
                if model.permission == .denied {
                    Button("Open System Settings", action: model.openPrivacySettings)
                } else {
                    Button("Allow Access", action: model.requestPermission)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
