import SwiftUI

/// past conversations, searchable — mirrors pi's /resume: keyword across
/// every session's history, newest first, tap to relaunch in its live space.
struct SearchSheet: View {
    @ObservedObject var model: CaptureModel
    /// hands back the channel to peel into after a relaunch
    var onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SlappClient.SearchHit] = []
    @State private var searching = false
    @State private var opening: String?
    @State private var note: String?
    private let client = SlappClient(bridgeHost: BridgeConfig().host)

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.90).ignoresSafeArea()   // the paper
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.black.opacity(0.45))
                        TextField("search past conversations", text: $query)
                            .font(.system(size: 17))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { Task { await search() } }
                        if searching { ProgressView().tint(.white) }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if let note {
                                Text(note)
                                    .font(.system(size: 13, design: .serif))
                                    .foregroundStyle(.red)
                                    .padding(.top, 24)
                            }
                            ForEach(hits) { hit in
                                Button {
                                    Task { await relaunch(hit) }
                                } label: {
                                    row(hit)
                                }
                                .buttonStyle(.plain)
                                .disabled(opening != nil)
                            }
                            if hits.isEmpty && !searching && query.count > 1 {
                                Text("nothing found — try another word")
                                    .font(.system(size: 13, design: .serif))
                                    .foregroundStyle(Color.black.opacity(0.4))
                                    .padding(.top, 40)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    }
                }
            }
            .navigationTitle("past conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("back") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
        .task { await search() }   // recent conversations right away
    }

    private func row(_ hit: SlappClient.SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(hit.title.isEmpty ? "(untitled)" : hit.title)
                    .font(.system(size: 15.5, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .lineLimit(1)
                Spacer()
                Text(hit.age)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.45))
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(hit.session)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.6))
                Text("· \(hit.turns) turns")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.45))
                if opening == hit.file {
                    Spacer()
                    ProgressView().tint(.white)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
    }

    private func search() async {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 || query.isEmpty else { return }
        searching = true; note = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits2 = await client.search(q)
        withAnimation { hits = hits2 }
        searching = false
    }

    private func relaunch(_ hit: SlappClient.SearchHit) async {
        opening = hit.file; note = nil
        let ok = await client.openSession(hit.slug, file: hit.file)
        opening = nil
        if ok {
            // peel into that session's channel
            if let ch = model.channels.first(where: { isSessionWebhook($0.webhook, slug: hit.slug) }) {
                dismiss()
                onOpen(ch.id)
            } else {
                dismiss(); note = nil
            }
        } else {
            note = "couldn't relaunch that one — try again"
        }
    }
}
