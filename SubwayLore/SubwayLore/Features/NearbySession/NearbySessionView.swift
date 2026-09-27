import SwiftUI

struct NearbySessionView: View {
    @ObservedObject var model: NearbySessionViewModel

    var body: some View {
        ZStack {
            Color.loreInk.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.loreGreen.opacity(0.14))
                                .frame(width: 44, height: 44)

                            Image(systemName: "person.2.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.loreGreen)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Car chat")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text(riderCountText)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.48))
                        }

                        Spacer()

                        Circle()
                            .fill(Color.loreGreen)
                            .frame(width: 8, height: 8)
                            .shadow(color: Color.loreGreen.opacity(0.7), radius: 5)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .background(Color.white.opacity(0.05))

                    Divider()
                        .overlay(Color.white.opacity(0.07))

                    VStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.loreBlue)

                        Text("Chats will be available soon")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Soon you'll be able to talk with nearby riders in this car.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.48))
                            .frame(maxWidth: 260)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 390)
                    .padding(.vertical, 36)
                    .padding(.horizontal, 20)
                }
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                }
                .padding(20)
            }
        }
        .navigationTitle("This car")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var riderCountText: String {
        let count = model.snapshot.peers.count + 1
        return "\(count) \(count == 1 ? "rider" : "riders") in this car"
    }
}
