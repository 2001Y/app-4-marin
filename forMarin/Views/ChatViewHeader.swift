import SwiftUI

extension ChatView {
    
    // MARK: - Header Views
    @ViewBuilder 
    func headerView() -> some View {
        HStack {
            // Left: back button
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)

            Spacer()

            // Center: avatar + name & countdown
            HStack(spacing: 12) {
                avatarView()
                Button { showProfileSheet = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(partnerName.isEmpty ? remoteUserID : partnerName)
                            .foregroundColor(.primary)
                            .font(.headline)
                        Text("あと\(daysUntilAnniversary)日")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            // Right buttons
            HStack(spacing: 12) {
                FaceTimeAudioButton(callee: remoteUserID)
                FaceTimeButton(callee: remoteUserID)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder 
    func avatarView() -> some View {
        if let avatar = partnerAvatar {
            Image(uiImage: avatar)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
        } else {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                )
        }
    }
} 