//
//  ContentView.swift
//  SubwayLore
//
//  Created by Pemba Dorji on 9/4/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var nearbyModel = NearbySessionViewModel()
    @State private var showsProfile = false
    @State private var hasCheckedProfile = false
    @State private var isProfileSetup = false
    @State private var isCreatingChat = false
    @State private var showsHistory = false
    @State private var actionError: String?
    @State private var isJoining = false

    var body: some View {
        NavigationStack {
            ZStack {
                background

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        header
                        nearbyNetwork
                        activityCards
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $nearbyModel.presentedChat) { chat in
                NearbySessionView(model: nearbyModel, chat: chat)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            nearbyModel.start()
            guard !hasCheckedProfile else { return }
            hasCheckedProfile = true
            let identity = nearbyModel.identity
            if (identity.firstName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (identity.lastName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isProfileSetup = true
                showsProfile = true
            }
        }
        .sheet(isPresented: $showsHistory) {
            ChatHistoryView(model: nearbyModel)
        }
        .alert("Unable to open chat", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .sheet(isPresented: $showsProfile) {
            ProfileView(model: nearbyModel, isInitialSetup: isProfileSetup)
                .presentationDetents([.height(570), .large])
                .presentationBackground(Color.loreInk)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
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

                Button {
                    isProfileSetup = false
                    showsProfile = true
                } label: {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.white.opacity(0.75))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit profile")
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
        NearbyNetworkCard(
            identity: nearbyModel.identity,
            snapshot: nearbyModel.snapshot,
            onRefresh: nearbyModel.restart
        )
    }

    private var activityCards: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Live Chats", systemImage: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(Color.loreBlue)
                        Spacer(minLength: 0)
                        Button { showsHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .accessibilityLabel("Chat history")
                        .accessibilityIdentifier("chatHistory")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))

                    if nearbyModel.liveChats.isEmpty {
                        Text("No live chats nearby")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    } else {
                        ForEach(nearbyModel.liveChats.prefix(3)) { chat in
                            Button {
                                guard !isJoining else { return }
                                isJoining = true
                                Task {
                                    defer { isJoining = false }
                                    do { try await nearbyModel.joinChat(chat) }
                                    catch { actionError = "Chat could not be opened. Please try again." }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chat.title).foregroundStyle(.white).lineLimit(1)
                                    Text("\(chat.advertisingPeerIDs.count) nearby")
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(isJoining)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
                .loreCard(padding: 14)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Live Games", systemImage: "bolt.fill")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.loreOrange)
                    Text("Games coming soon")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
                .loreCard(padding: 14)
            }

            HStack(spacing: 12) {
                Button {
                    guard !isCreatingChat else { return }
                    isCreatingChat = true
                    Task {
                        defer { isCreatingChat = false }
                        do { try await nearbyModel.createChat() }
                        catch { actionError = "Chat could not be created. Please try again." }
                    }
                } label: {
                    ActivityCard(title: "New Chat", detail: isCreatingChat ? "Opening…" : "Start a conversation",
                                 symbol: "plus.bubble.fill", color: .loreBlue)
                }
                .buttonStyle(.plain)
                .disabled(isCreatingChat)
                .accessibilityIdentifier("newChat")
                ActivityCard(title: "New Game", detail: "Games coming soon", symbol: "bolt.fill", color: .loreOrange)
            }
            if let error = nearbyModel.chatSnapshot.error {
                Text(error).font(.caption).foregroundStyle(Color.loreOrange)
            }
        }
    }
}

private struct ActivityCard: View {
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
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(2, reservesSpace: true)
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
