import UIKit

#if canImport(PDFKit)
import PDFKit
#endif

final class ReaderViewFactory {
    static func makeView(for content: ChapterContent, config: ReaderConfig) -> UIView {
        switch content {
        case .text(let string):
            let view = CoreTextReaderView()
            view.render(text: string, config: config)
            return view

        case .html(let html):
            let view = CoreTextReaderView()
            view.render(text: html.strippedHTML, config: config)
            return view

        case .image(let url):
            let view = ComicReaderView()
            view.loadImage(from: url)
            return view

        case .pdfPage(let page):
            let view = PDFPageView()
            view.render(page)
            return view
        }
    }
}

final class CoreTextReaderView: UIView {
    private let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(text: String, config: ReaderConfig) {
        textView.font = .systemFont(ofSize: config.fontSize)
        textView.text = text
    }
}

final class ComicReaderView: UIImageView {
    func loadImage(from url: URL) {
        contentMode = .scaleAspectFit
        clipsToBounds = true
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            guard let image = UIImage(data: data) else { return }
            await MainActor.run {
                self.image = image
            }
        }
    }
}

final class PDFPageView: UIView {
#if canImport(PDFKit)
    private let pdfView = PDFView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ page: UniversalPDFPage) {
        let document = PDFDocument()
        document.insert(page, at: 0)
        pdfView.document = document
        pdfView.displayMode = .singlePage
        pdfView.autoScales = true
    }
#else
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override init(frame: CGRect) { super.init(frame: frame) }
    func render(_ page: UniversalPDFPage) { _ = page }
#endif
}
