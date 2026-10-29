//
//  ContentView.swift
//  SubwayLore
//
//  Created by Pemba Dorji on 9/4/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appModel = AppViewModel()
    @State private var showsProfile = false
    @State private var hasCheckedProfile = false
    @State private var isProfileSetup = false
    @State private var isCreatingChat = false
    @State private var showsHistory = false
    @State private var actionError: String?
    @State private var isJoining = false
    @State private var showsGamePicker = false
    @State private var showsLeaderboard = false
    @State private var isJoiningGame = false

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
            .navigationDestination(item: $appModel.presentedChat) { chat in
                NearbySessionView(model: appModel, chat: chat)
            }
            .navigationDestination(item: $appModel.presentedGame) { game in
                switch game.kind {
                case .timeIt: TimeItGameView(model: appModel, lobby: game)
                case .subwayTrivia: TriviaGameView(model: appModel, lobby: game)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            appModel.start()
            guard !hasCheckedProfile else { return }
            hasCheckedProfile = true
            let identity = appModel.identity
            if (identity.firstName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (identity.lastName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isProfileSetup = true
                showsProfile = true
            }
        }
        .sheet(isPresented: $showsHistory) {
            ChatHistoryView(model: appModel)
        }
        .sheet(isPresented: $showsLeaderboard) {
            LeaderboardView(model: appModel)
        }
        .sheet(isPresented: $showsGamePicker) {
            GamePickerView(model: appModel)
                .presentationDetents([.height(440), .large])
                .presentationBackground(Color.loreInk)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
        .alert("Unable to open activity", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .sheet(isPresented: $showsProfile) {
            ProfileView(model: appModel, isInitialSetup: isProfileSetup)
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
            identity: appModel.identity,
            snapshot: appModel.snapshot,
            onRefresh: appModel.restart
        )
    }

    private var activityCards: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
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

                    if appModel.liveChats.isEmpty {
                        Text("No live chats nearby")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        ForEach(appModel.liveChats.prefix(3)) { chat in
                            Button {
                                guard !isJoining else { return }
                                isJoining = true
                                Task {
                                    defer { isJoining = false }
                                    do { try await appModel.joinChat(chat) }
                                    catch { actionError = "Chat could not be opened. Please try again." }
                                }
                            } label: {
                                LiveActivityRow(title: chat.title,
                                    detail: "\(chat.advertisingPeerIDs.count) nearby", color: .loreBlue)
                            }
                            .buttonStyle(LiveActivityButtonStyle())
                            .disabled(isJoining)
                            .accessibilityLabel("Join chat: \(chat.title)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
                .loreCard(padding: 14)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Live Games", systemImage: "bolt.fill")
                        Spacer(minLength: 0)
                        Button { showsLeaderboard = true } label: {
                            Image(systemName: "trophy.fill")
                        }
                        .accessibilityLabel("Game leaderboards")
                        .accessibilityIdentifier("gameLeaderboards")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.loreOrange)
                    if appModel.liveGames.isEmpty {
                        Text("No live games nearby")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        ForEach(appModel.liveGames.prefix(3)) { game in
                            Button {
                                guard !isJoiningGame else { return }
                                isJoiningGame = true
                                Task {
                                    defer { isJoiningGame = false }
                                    do { try await appModel.joinGame(game) }
                                    catch { actionError = "This game is full or already playing. Try between rounds." }
                                }
                            } label: {
                                LiveActivityRow(title: game.lobby.kind.title,
                                    detail: "\(game.playerCount)/8 · \(game.lobby.hostDisplayName)",
                                    color: .loreOrange, isJoinable: game.isJoinable && game.playerCount < 8)
                            }
                            .buttonStyle(LiveActivityButtonStyle())
                            .disabled(isJoiningGame || !game.isJoinable || game.playerCount >= 8)
                            .accessibilityLabel("\(game.isJoinable && game.playerCount < 8 ? "Join" : "Unavailable") game: \(game.lobby.kind.title), \(game.lobby.hostDisplayName)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
                .loreCard(padding: 14)
            }

            HStack(spacing: 12) {
                Button {
                    guard !isCreatingChat else { return }
                    isCreatingChat = true
                    Task {
                        defer { isCreatingChat = false }
                        do { try await appModel.createChat() }
                        catch { actionError = "Chat could not be created. Please try again." }
                    }
                } label: {
                    ActivityCard(title: "New Chat", detail: isCreatingChat ? "Opening…" : "Start a conversation",
                                 symbol: "plus.bubble.fill", color: .loreBlue)
                }
                .buttonStyle(.plain)
                .disabled(isCreatingChat)
                .accessibilityIdentifier("newChat")
                Button { showsGamePicker = true } label: {
                    ActivityCard(title: "New Game", detail: "Play with nearby riders", symbol: "bolt.fill", color: .loreOrange)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newGame")
            }
            if let error = appModel.chatSnapshot.error {
                Text(error).font(.caption).foregroundStyle(Color.loreOrange)
            }
        }
    }
}

private struct LiveActivityRow: View {
    let title: String
    let detail: String
    let color: Color
    var isJoinable = true

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(isJoinable ? 1 : 0.6))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Image(systemName: isJoinable ? "arrow.right" : "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(isJoinable ? "Join" : "Busy")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .foregroundStyle(isJoinable ? color : .white.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(isJoinable ? color.opacity(0.14) : .white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isJoinable ? color.opacity(0.4) : .white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct LiveActivityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
