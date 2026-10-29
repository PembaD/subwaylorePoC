import SwiftUI

struct LeaderboardView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGame = GameKind.timeIt

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Game", selection: $selectedGame) {
                        ForEach(GameKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                    }.pickerStyle(.segmented)
                    StandingsCard(rounds: model.completedRounds, kind: selectedGame, gameID: nil,
                                  localPlayerID: model.identity.id, title: "Leaderboard")
                    Text("Results from rounds played on this device. Wins include shared first places. Head-to-head compares your finish with each opponent, including in multiplayer rounds.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    if let error = model.leaderboardError {
                        Text(error).font(.caption).foregroundStyle(Color.loreOrange)
                        Button("Retry") { Task { await model.refreshLeaderboard() } }
                    }
                }.padding(20)
            }
            .background(Color.loreInk.ignoresSafeArea())
            .navigationTitle("Leaderboards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .tint(.loreOrange).preferredColorScheme(.dark)
        .task { await model.refreshLeaderboard() }
    }
}

struct StandingsCard: View {
    let rounds: [CompletedRound]
    let kind: GameKind
    let gameID: UUID?
    let localPlayerID: UUID
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: "trophy.fill")
                .font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Color.loreOrange)
            let entries = GameStandings.leaderboard(rounds, kind: kind, gameID: gameID)
            if entries.isEmpty {
                Text("Play a round to start your leaderboard.").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            } else {
                HStack {
                    Text("RIDER")
                    Spacer()
                    Text("WINS").frame(width: 42)
                    Text("PLAYED").frame(width: 52)
                }.font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.id == localPlayerID ? "\(entry.displayName) (You)" : entry.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(entry.wins)").foregroundStyle(Color.loreOrange).frame(width: 42)
                        Text("\(entry.played)").foregroundStyle(.white.opacity(0.6)).frame(width: 52)
                    }.font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                let records = GameStandings.headToHead(rounds, kind: kind, playerID: localPlayerID, gameID: gameID)
                if !records.isEmpty {
                    Divider().overlay(.white.opacity(0.1))
                    Text("YOUR HEAD-TO-HEAD")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.loreOrange)
                    ForEach(records) { record in
                        HStack {
                            Text("vs \(record.displayName)").lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(record.wins)W · \(record.draws)D · \(record.losses)L")
                                .foregroundStyle(.white.opacity(0.65)).monospacedDigit()
                        }.font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }
}
