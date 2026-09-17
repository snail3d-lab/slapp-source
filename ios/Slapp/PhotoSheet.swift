import SwiftUI
import PhotosUI

/// How a channel opens when you come in through a leaf.
enum StartAction: Equatable {
    case none
    case keyboard
    case choose        // the three-way photo picker
    case camera
    case library
    case note
}

/// UIImagePickerController camera — the sim has no lens, the phone does.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onImage(img.jpegData(compressionQuality: 0.85) ?? Data())
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// The photo leaf's flow: choose → camera / library / write a note.
struct ChannelPhotoFlow: View {
    let channelID: String
    @ObservedObject var model: CaptureModel
    let start: StartAction

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showNote = false
    @State private var showChoose = false
    @State private var note = ""
    @State private var libraryItem: PhotosPickerItem?
    @State private var busy = false

    var body: some View {
        Group {}
            .confirmationDialog("add to this channel", isPresented: $showChoose, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take a photo") { showCamera = true }
                }
                Button("Choose from camera roll") { showLibrary = true }
                Button("Write a note") { showNote = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("it lands in this channel's play-by-play")
            }
            .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in send(data) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showNote) {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        TextEditor(text: $note)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.white)
                            .padding(14)
                    }
                    .navigationTitle("note")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showNote = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") {
                                let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
                                showNote = false
                                if !t.isEmpty { Task { await model.sendText(t, channel: channelID) } }
                            }
                            .disabled(note.isEmpty)
                        }
                    }
                }
                .preferredColorScheme(.dark)
            }
            .onChange(of: libraryItem) { item in
                guard let item else { return }
                libraryItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        send(data)
                    }
                }
            }
            .onAppear {
                switch start {
                case .choose: showChoose = true
                case .camera: showCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
                case .library: showLibrary = true
                case .note: showNote = true
                default: break
                }
            }
    }

    private func send(_ data: Data) {
        busy = true
        Task {
            await model.sendPhoto(data, channel: channelID)
            busy = false
        }
    }
}
