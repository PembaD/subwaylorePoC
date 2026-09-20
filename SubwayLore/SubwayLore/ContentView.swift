//
//  ContentView.swift
//  SubwayLore
//
//  Created by Pemba Dorji on 9/4/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                background

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        header
                        nearbyNetwork
                        activityCards
                        enterButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Color.loreInk
            RadialGradient(
                colors: [Color.loreGreen.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 360
            )
            RadialGradient(
                colors: [Color.lorePurple.opacity(0.13), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("OFFLINE READY", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Color.loreGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.loreGreen.opacity(0.12), in: Capsule())

                Spacer()

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.white.opacity(0.75))
                    }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("SUBWAY LORE")
                    .font(.system(size: 35, weight: .black, design: .rounded))
                    .tracking(-1)
                    .foregroundStyle(.white)

                Text("Your train car has a story.")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var nearbyNetwork: some View {
        HStack(spacing: 14) {
            HStack(spacing: -10) {
                compactAvatar("MK", color: .lorePurple)
                compactAvatar("J", color: .loreBlue)
                compactAvatar("AR", color: .loreOrange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("8 riders nearby")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("This car is active")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
            }

            Spacer(minLength: 8)

            Circle()
                .fill(Color.loreGreen)
                .frame(width: 8, height: 8)
                .shadow(color: Color.loreGreen.opacity(0.8), radius: 5)
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func compactAvatar(_ initials: String, color: Color) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 36, height: 36)
            .overlay {
                Text(initials)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle()
                    .stroke(Color.loreInk, lineWidth: 2)
            }
    }

    private var activityCards: some View {
        HStack(spacing: 12) {
            ActivityCard(
                eyebrow: "CAR CHAT",
                title: "3 new posts",
                detail: "Join the conversation",
                symbol: "bubble.left.and.bubble.right.fill",
                color: .loreBlue
            )

            ActivityCard(
                eyebrow: "TRIVIA",
                title: "Starts in 0:42",
                detail: "5 riders joined",
                symbol: "bolt.fill",
                color: .loreOrange
            )
        }
    }

    private var enterButton: some View {
        VStack(spacing: 13) {
            NavigationLink(destination: NearbySessionView()) {
                HStack {
                    Text("Enter this car")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.loreInk)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Label("Nearby connections work without internet", systemImage: "wifi.slash")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
        }
    }
}

private struct ActivityCard: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.4))

                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .loreCard(padding: 16)
    }
}

private extension View {
    func loreCard(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
    }
}

extension Color {
    static let loreInk = Color(red: 0.025, green: 0.039, blue: 0.055)
    static let loreGreen = Color(red: 0.0, green: 0.68, blue: 0.39)
    static let loreBlue = Color(red: 0.15, green: 0.55, blue: 1.0)
    static let lorePurple = Color(red: 0.54, green: 0.35, blue: 0.96)
    static let loreOrange = Color(red: 1.0, green: 0.49, blue: 0.18)
}

#Preview {
    ContentView()
}
