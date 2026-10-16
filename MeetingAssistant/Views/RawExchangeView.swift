import SwiftUI
import UIKit

/// Muestra literalmente la petición HTTP enviada al LLM (y su respuesta).
struct RawExchangeView: View {
    let exchange: LLMExchange
    @Environment(\.dismiss) private var dismiss

    enum Part: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"
        var id: Self { self }
    }

    @State private var part: Part = .request
    @State private var copied = false

    private var text: String {
        switch part {
        case .request: return exchange.request
        case .response: return exchange.response ?? "(sin respuesta todavía)"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Parte", selection: $part) {
                    ForEach(Part.allCases) { part in
                        Text(part.rawValue).tag(part)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                Text("\(exchange.model) · \(exchange.date.formatted(date: .abbreviated, time: .standard)) · \(text.count) caracteres")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                Divider()
                SelectableTextView(text: text)
            }
            .navigationTitle("Request raw al LLM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copiar")
                    ShareLink(item: text)
                }
            }
            .onChange(of: part) { _, _ in
                copied = false
            }
        }
    }
}

/// `UITextView` de solo lectura: maneja bien textos muy largos y permite seleccionar.
struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 24, right: 10)
        view.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
    }
}
